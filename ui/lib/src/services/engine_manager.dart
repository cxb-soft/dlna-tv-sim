import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'app_paths.dart';

class EngineBootException implements Exception {
  EngineBootException(this.message, {this.detail});

  final String message;

  /// 给「详细信息」区域看的排查线索（日志尾部、搜过的路径等）。
  final String? detail;

  @override
  String toString() => detail == null || detail!.isEmpty ? message : '$message\n$detail';
}

class EngineHandle {
  const EngineHandle({
    required this.port,
    required this.adopted,
    this.binaryPath,
    this.logPath,
  });

  final int port;

  /// true 表示复用了已经在跑的引擎（不是本 App 拉起来的），退出时不该杀。
  final bool adopted;
  final String? binaryPath;
  final String? logPath;
}

/// 找引擎、起引擎、收引擎。全程 Process.start，不经过 shell，不会弹终端。
class EngineManager {
  EngineManager({required this.port});

  final int port;

  /// 把引擎 PID 交给 macOS 原生层：Dart 的退出回调不一定来得及跑完，
  /// 由 AppKit 在 applicationWillTerminate 里发 SIGTERM 兜底。
  static const MethodChannel _nativeChannel =
      MethodChannel('com.cxbsoft.dlna-tv-sim/engine');

  Process? _child;
  int? _exitCode;
  String _logPath = '';
  final StringBuffer _tail = StringBuffer();

  bool get ownsEngine => _child != null;
  int? get exitCode => _exitCode;

  String get logPath => _logPath;

  String get logTail => _tail.toString();

  Future<EngineHandle> ensureRunning({void Function(String)? onProgress}) async {
    onProgress?.call('正在检查 $port 端口…');
    if (await _probe()) {
      return EngineHandle(port: port, adopted: true);
    }

    onProgress?.call('正在寻找引擎文件…');
    final binary = EngineLocator.find();
    if (binary == null) {
      throw EngineBootException(
        '找不到引擎可执行文件',
        detail: '找过这些位置：\n${EngineLocator.describeSearched()}',
      );
    }

    onProgress?.call('正在启动引擎…');
    await _spawn(binary);

    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(deadline)) {
      if (await _probe()) {
        return EngineHandle(
          port: port,
          adopted: false,
          binaryPath: binary,
          logPath: _logPath,
        );
      }
      final code = _exitCode;
      if (code != null) {
        throw EngineBootException(
          '引擎启动后立刻退出了（退出码 $code）',
          detail: _detailWithTail(),
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }

    throw EngineBootException(
      '引擎 15 秒内没有响应 $port 端口',
      detail: _detailWithTail(),
    );
  }

  Future<bool> _probe() async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 500)
      ..findProxy = ((_) => 'DIRECT');
    try {
      final req = await client
          .getUrl(Uri.parse('http://127.0.0.1:$port/api/state'))
          .timeout(const Duration(milliseconds: 700));
      final resp = await req.close().timeout(const Duration(milliseconds: 1200));
      final body = await resp
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(milliseconds: 1200));
      return resp.statusCode == 200 && body.contains('friendly_name');
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _spawn(String binary) async {
    final dir = await AppPaths.logDir().create(recursive: true);
    _logPath = '${dir.path}/engine.log';
    final logFile = File(_logPath);
    if (await logFile.exists() && await logFile.length() > 2 * 1024 * 1024) {
      try {
        await logFile.writeAsString('');
      } catch (_) {}
    }

    final IOSink sink;
    try {
      sink = logFile.openWrite(mode: FileMode.append);
    } catch (_) {
      throw EngineBootException('写不了引擎日志：$_logPath');
    }

    final Process proc;
    try {
      proc = await Process.start(
        binary,
        ['-no-open', '-http-port', '$port'],
        runInShell: false,
        workingDirectory: File(binary).parent.path,
        includeParentEnvironment: true,
      );
    } on ProcessException catch (e) {
      sink.writeln('启动失败: ${e.message}（${e.errorCode}）');
      await sink.flush();
      await sink.close();
      throw EngineBootException(
        '启动引擎失败：${e.message}',
        detail: '引擎路径：$binary\n${e.errorCode == 13 ? '文件没有执行权限。' : ''}',
      );
    }
    _child = proc;
    _exitCode = null;
    await _registerPid(proc.pid);

    sink.writeln('');
    sink.writeln('=== ${DateTime.now().toIso8601String()} 启动 $binary (端口 $port) ===');

    void pipe(Stream<List<int>> stream) {
      stream.transform(utf8.decoder).listen((chunk) {
        sink.write(chunk);
        _remember(chunk);
      }, onError: (Object _) {});
    }

    pipe(proc.stdout);
    pipe(proc.stderr);
    unawaited(proc.exitCode.then((code) {
      _exitCode = code;
      sink.writeln('=== ${DateTime.now().toIso8601String()} 引擎退出，退出码 $code ===');
      unawaited(sink.flush().then((_) => sink.close()).catchError((_) {}));
    }));
  }

  void _remember(String chunk) {
    _tail.write(chunk);
    if (_tail.length > 6000) {
      final s = _tail.toString();
      _tail
        ..clear()
        ..write(s.substring(s.length - 6000));
    }
  }

  String _detailWithTail() {
    final tail = _tail.toString().trim();
    final lines = tail.split('\n');
    final last = lines.length > 14 ? lines.sublist(lines.length - 14) : lines;
    return [
      '引擎日志：$_logPath',
      if (last.isNotEmpty) ...last,
    ].join('\n');
  }

  /// 只结束自己拉起来的引擎；复用别人的实例时不动它。
  Future<void> stop() async {
    final proc = _child;
    if (proc == null) return;
    _child = null;
    try {
      proc.kill(ProcessSignal.sigterm);
      await proc.exitCode.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      try {
        proc.kill(ProcessSignal.sigkill);
      } catch (_) {}
    } catch (_) {
      try {
        proc.kill(ProcessSignal.sigkill);
      } catch (_) {}
    }
    await _registerPid(0);
  }

  Future<void> _registerPid(int pid) async {
    try {
      await _nativeChannel.invokeMethod<void>('setEnginePid', pid);
    } catch (_) {
      // Windows / Linux / 单元测试里没有这个 channel，忽略即可。
    }
  }
}

/// 按平台找引擎二进制：先看打包后的位置，再沿目录树往上找开发期的 dist/。
class EngineLocator {
  static const String _envKey = 'DLNA_TV_SIM_ENGINE';

  static bool get _isArm {
    final v = Platform.version.toLowerCase();
    return v.contains('arm64') || v.contains('aarch64');
  }

  static List<String> engineNames() {
    if (Platform.isMacOS) {
      return _isArm
          ? const ['dlna-tv-sim-macos-arm64', 'dlna-tv-sim-macos-amd64']
          : const ['dlna-tv-sim-macos-amd64', 'dlna-tv-sim-macos-arm64'];
    }
    if (Platform.isWindows) {
      return _isArm
          ? const ['dlna-tv-sim-windows-arm64.exe', 'dlna-tv-sim-windows-x64.exe']
          : const ['dlna-tv-sim-windows-x64.exe', 'dlna-tv-sim-windows-arm64.exe'];
    }
    return _isArm
        ? const ['dlna-tv-sim-linux-arm64', 'dlna-tv-sim-linux-amd64']
        : const ['dlna-tv-sim-linux-amd64', 'dlna-tv-sim-linux-arm64'];
  }

  /// 打包后引擎的相对位置（相对可执行文件所在目录）。
  static List<String> packagedRelativePaths() {
    if (Platform.isMacOS) {
      // .../DLNA 电视.app/Contents/MacOS/dlna_tv_sim → ../Resources/engine/
      return const ['../Resources/engine/dlna-tv-sim'];
    }
    if (Platform.isWindows) {
      return const ['engine/dlna-tv-sim.exe'];
    }
    return const ['engine/dlna-tv-sim'];
  }

  static List<String> candidates() {
    final out = <String>[];
    final env = Platform.environment[_envKey];
    if (env != null && env.trim().isNotEmpty) out.add(env.trim());

    final exeDir = File(Platform.resolvedExecutable).parent.path;
    for (final rel in packagedRelativePaths()) {
      out.add(_join(exeDir, rel));
    }

    // 开发期：从 .app 内部和当前目录分别往上找仓库根的 dist/。
    // 打包后的 debug 版埋在 ui/build/macos/Build/Products/Debug/App.app 里，
    // 到仓库根有十层左右，所以这里留够 14 层。
    final names = engineNames();
    for (final start in <String>[exeDir, Directory.current.path]) {
      var dir = Directory(start);
      for (var depth = 0; depth < 14; depth++) {
        for (final name in names) {
          out.add(_join(dir.path, 'dist/$name'));
        }
        final parent = dir.parent;
        if (parent.path == dir.path) break;
        dir = parent;
      }
    }

    final seen = <String>{};
    return [
      for (final path in out)
        if (seen.add(path)) path,
    ];
  }

  static String? find() {
    for (final path in candidates()) {
      final file = File(path);
      if (file.existsSync()) return path;
    }
    return null;
  }

  static String describeSearched() {
    final list = candidates();
    if (list.length <= 8) return list.join('\n');
    return [...list.take(8), '……共找过 ${list.length} 个位置'].join('\n');
  }

  static String _join(String base, String rel) {
    if (rel.startsWith('..')) {
      // 打包路径需要真正解析 ../，/ 在 Windows 上也成立。
      final segments = '$base/$rel'.split('/');
      final stack = <String>[];
      for (final seg in segments) {
        if (seg.isEmpty || seg == '.') continue;
        if (seg == '..') {
          if (stack.isNotEmpty) stack.removeLast();
        } else {
          stack.add(seg);
        }
      }
      final absolute = base.startsWith('/');
      return '${absolute ? '/' : ''}${stack.join('/')}';
    }
    return '$base/$rel';
  }
}
