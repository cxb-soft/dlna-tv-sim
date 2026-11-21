import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/engine_state.dart';
import '../models/update_info.dart';
import '../services/engine_client.dart';
import '../services/engine_manager.dart';
import '../services/recent_store.dart';
import '../services/local_network.dart';
import '../services/update_service.dart';
import '../version.dart';

enum EnginePhase { booting, ready, failed }

/// 界面唯一的状态源：引擎生命周期、轮询、指令、投屏、自检、更新检查。
class AppController extends ChangeNotifier {
  AppController({int? port, String? version})
    : port = port ?? resolveEnginePort(),
      version = version ?? resolveAppVersion() {
    client = EngineClient(this.port);
    engine = EngineManager(port: this.port);
    updates = UpdateService(currentVersion: this.version);
  }

  final int port;
  final String version;

  late EngineClient client;
  late final EngineManager engine;
  late final UpdateService updates;
  final RecentCastStore recentStore = RecentCastStore();

  // ---- 引擎 ----
  EnginePhase _phase = EnginePhase.booting;
  String _bootMessage = '正在准备…';
  String? _fatalError;
  String? _fatalDetail;
  EngineState? _state;
  EngineHandle? _handle;
  DateTime? _connectedAt;

  // ---- 轮询 ----
  Timer? _stateTimer;
  Timer? _logTimer;
  bool _stateBusy = false;
  bool _logBusy = false;
  int _pollFailures = 0;
  final List<LogEntry> _logs = [];
  int _lastLogId = 0;

  // ---- 指令 ----
  bool _commandBusy = false;
  String? _commandError;
  Timer? _commandErrorTimer;

  // ---- 投屏 ----
  bool _castBusy = false;
  String? _castError;
  List<String> _recents = const [];

  // ---- 改名 ----
  String? _renameError;

  // ---- 自检 ----
  bool _diagBusy = false;
  DiagResult? _diag;
  String? _diagError;

  // ---- 更新 ----
  UpdateInfo? _update;
  bool _updateChecking = false;
  String? _updateError;
  bool _updateDismissed = false;
  bool _installing = false;
  double _installProgress = 0;
  String? _installMessage;

  bool _disposed = false;
  bool _shuttingDown = false;

  EnginePhase get phase => _phase;
  String get bootMessage => _bootMessage;
  String? get fatalError => _fatalError;
  String? get fatalDetail => _fatalDetail;
  EngineState? get state => _state;
  EngineHandle? get handle => _handle;
  bool get adoptedEngine => _handle?.adopted ?? false;
  DateTime? get connectedAt => _connectedAt;

  List<LogEntry> get logs => List.unmodifiable(_logs);
  bool get commandBusy => _commandBusy;
  String? get commandError => _commandError;

  bool get castBusy => _castBusy;
  String? get castError => _castError;
  List<String> get recents => _recents;

  String? get renameError => _renameError;

  bool get diagBusy => _diagBusy;
  DiagResult? get diag => _diag;
  String? get diagError => _diagError;

  UpdateInfo? get update => _update;
  bool get hasUpdate => _update != null;
  bool get updateChecking => _updateChecking;
  String? get updateError => _updateError;
  bool get updateDismissed => _updateDismissed;
  bool get installing => _installing;
  double get installProgress => _installProgress;
  String? get installMessage => _installMessage;

  String get engineLogPath => engine.logPath;

  /// 启动：探活 → 复用或拉起引擎 → 首次拉状态 → 开轮询。
  Future<void> bootstrap() async {
    _stateTimer?.cancel();
    _logTimer?.cancel();
    _stateTimer = null;
    _logTimer = null;

    _phase = EnginePhase.booting;
    _bootMessage = '正在连接引擎…';
    _fatalError = null;
    _fatalDetail = null;
    _pollFailures = 0;
    _emit();

    unawaited(
      recentStore.load().then((_) {
        _recents = recentStore.items;
        _emit();
      }),
    );

    // 先在 App 身份下触发一次本地网络访问：macOS 才会为这个 App 弹授权，
    // 引擎子进程的 SSDP 组播才能发出去（否则静默 no route to host）。
    await warmUpLocalNetwork();

    try {
      final handle = await engine.ensureRunning(
        onProgress: (message) {
          _bootMessage = message;
          _emit();
        },
      );
      _handle = handle;

      // 换成指向新实例的客户端（复用旧连接时也重置一次，避免半开连接）。
      client.close();
      client = EngineClient(port);

      final json = await client.getJson('/api/state');
      _state = EngineState.fromJson(json);
      _phase = EnginePhase.ready;
      _bootMessage = '';
      _connectedAt = DateTime.now();
      _pollFailures = 0;
      _startTimers();
      _emit();

      unawaited(_pollLogs());
      unawaited(checkForUpdates());
    } on EngineBootException catch (e) {
      _fail(e.message, e.detail);
    } on EngineApiException catch (e) {
      _fail('引擎起来了，但状态接口读不出来', e.message);
    } catch (e) {
      _fail('连接引擎失败', '$e');
    }
  }

  /// 手动重启：先收掉自己启动的引擎，再走一遍启动流程。
  Future<void> restartEngine() async {
    _stateTimer?.cancel();
    _logTimer?.cancel();
    _stateTimer = null;
    _logTimer = null;
    _phase = EnginePhase.booting;
    _bootMessage = '正在重启引擎…';
    _emit();
    await engine.stop();
    client.close();
    await bootstrap();
  }

  void _fail(String message, String? detail) {
    _stateTimer?.cancel();
    _logTimer?.cancel();
    _stateTimer = null;
    _logTimer = null;
    _phase = EnginePhase.failed;
    _fatalError = message;
    _fatalDetail = detail;
    _emit();
  }

  void _startTimers() {
    _stateTimer = Timer.periodic(const Duration(milliseconds: 1000), (_) {
      unawaited(_tickState());
    });
    _logTimer = Timer.periodic(const Duration(milliseconds: 1300), (_) {
      unawaited(_pollLogs());
    });
  }

  Future<void> _tickState() async {
    if (_stateBusy || _phase != EnginePhase.ready) return;
    _stateBusy = true;
    try {
      final json = await client.getJson('/api/state');
      _state = EngineState.fromJson(json);
      _pollFailures = 0;
      _emit();
    } catch (_) {
      _pollFailures++;
      if (_pollFailures >= 3) {
        final code = engine.exitCode;
        _fail(
          code != null ? '引擎已经退出（退出码 $code）' : '和引擎的连接断了',
          engine.ownsEngine
              ? '引擎日志：${engine.logPath}\n${engine.logTail.trim()}'
              : '这个引擎不是本 App 启动的，可能在别处被关掉了。',
        );
        return;
      }
    } finally {
      _stateBusy = false;
    }
  }

  Future<void> _pollLogs() async {
    if (_logBusy || _phase != EnginePhase.ready) return;
    _logBusy = true;
    try {
      final json = await client.getJson(
        '/api/log',
        query: {'since': '$_lastLogId'},
        timeout: const Duration(seconds: 3),
      );
      final entries = json['entries'];
      if (entries is! List || entries.isEmpty) return;
      var added = false;
      for (final item in entries) {
        if (item is! Map) continue;
        final entry = LogEntry.fromJson(Map<String, dynamic>.from(item));
        if (entry.id <= _lastLogId) continue;
        _lastLogId = entry.id;
        _logs.add(entry);
        added = true;
      }
      if (!added) return;
      if (_logs.length > 600) {
        _logs.removeRange(0, _logs.length - 600);
      }
      _emit();
    } catch (_) {
      // 日志拉不到不影响主流程，下一轮再试。
    } finally {
      _logBusy = false;
    }
  }

  // ---- 播放控制 ----

  Future<void> control(String action, [num? value]) => _command(
    () => client.postJson('/api/control', {
      'action': action,
      if (value != null) 'value': value,
    }),
  );

  Future<void> playerAction(
    String action, {
    num? value,
    String? text,
    String? kind,
    int? id,
  }) => _command(
    () => client.postJson('/api/player', {
      'action': action,
      if (value != null) 'value': value,
      if (text != null) 'text': text,
      if (kind != null) 'kind': kind,
      if (id != null) 'id': id,
    }),
  );

  Future<void> _command(Future<Map<String, dynamic>> Function() send) async {
    if (_phase != EnginePhase.ready || _commandBusy) return;
    _commandBusy = true;
    _commandError = null;
    _emit();
    try {
      final result = await send();
      if (result.containsKey('friendly_name')) {
        _state = EngineState.fromJson(result);
      } else {
        _state = EngineState.fromJson(await client.getJson('/api/state'));
      }
    } on EngineApiException catch (e) {
      _showCommandError(e.message);
    } catch (e) {
      _showCommandError('操作失败：$e');
    } finally {
      _commandBusy = false;
      _emit();
    }
  }

  void _showCommandError(String message) {
    _commandError = message;
    _commandErrorTimer?.cancel();
    _commandErrorTimer = Timer(const Duration(seconds: 6), () {
      _commandError = null;
      _emit();
    });
  }

  void clearCommandError() {
    _commandErrorTimer?.cancel();
    _commandError = null;
    _emit();
  }

  // ---- 投屏 ----

  Future<bool> cast(String rawUrl) async {
    final url = rawUrl.trim();
    if (url.isEmpty) {
      _castError = '先粘贴一个视频地址';
      _emit();
      return false;
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      _castError = '只支持 http / https 地址';
      _emit();
      return false;
    }
    if (_phase != EnginePhase.ready || _castBusy) return false;

    _castBusy = true;
    _castError = null;
    _emit();
    try {
      final result = await client.postJson('/api/cast', {
        'url': url,
      }, timeout: const Duration(seconds: 10));
      _state = EngineState.fromJson(result);
      _recents = await recentStore.add(url);
      return true;
    } on EngineApiException catch (e) {
      _castError = e.message;
      return false;
    } catch (e) {
      _castError = '投屏失败：$e';
      return false;
    } finally {
      _castBusy = false;
      _emit();
    }
  }

  Future<void> removeRecent(String url) async {
    _recents = await recentStore.remove(url);
    _emit();
  }

  void clearCastError() {
    if (_castError == null) return;
    _castError = null;
    _emit();
  }

  // ---- 改名 ----

  Future<bool> rename(String rawName) async {
    final name = rawName.trim();
    if (name.isEmpty) {
      _renameError = '设备名不能为空';
      _emit();
      return false;
    }
    if (name.runes.length > 64) {
      _renameError = '设备名最多 64 个字';
      _emit();
      return false;
    }
    if (_phase != EnginePhase.ready) return false;

    _renameError = null;
    _emit();
    try {
      final result = await client.postJson('/api/config', {
        'friendly_name': name,
      });
      _state = EngineState.fromJson(result);
      return true;
    } on EngineApiException catch (e) {
      _renameError = e.message;
      return false;
    } catch (e) {
      _renameError = '保存失败：$e';
      return false;
    } finally {
      _emit();
    }
  }

  // ---- 自检 ----

  Future<void> runDiag() async {
    if (_diagBusy || _phase != EnginePhase.ready) return;
    _diagBusy = true;
    _diagError = null;
    _emit();
    try {
      final json = await client.getJson(
        '/api/diag',
        timeout: const Duration(seconds: 10),
      );
      _diag = DiagResult.fromJson(json);
    } on EngineApiException catch (e) {
      _diagError = e.message;
    } catch (e) {
      _diagError = '自检失败：$e';
    } finally {
      _diagBusy = false;
      _emit();
    }
  }

  // ---- 更新 ----

  Future<UpdateInfo?> checkForUpdates({bool manual = false}) async {
    if (_updateChecking) return _update;
    _updateChecking = true;
    if (manual) _updateError = null;
    _emit();
    try {
      final info = await updates.check();
      _update = info;
      if (info != null) _updateDismissed = false;
      return info;
    } on UpdateCheckException catch (e) {
      _updateError = e.message;
      return null;
    } catch (e) {
      _updateError = '更新检查失败：$e';
      return null;
    } finally {
      _updateChecking = false;
      _emit();
    }
  }

  void dismissUpdate() {
    _updateDismissed = true;
    _emit();
  }

  /// 下载并安装新版本；成功后退出 App，安装脚本会替换旧包并重新打开。
  Future<void> installUpdate() async {
    final info = _update;
    if (info == null || _installing) return;
    _installing = true;
    _installProgress = 0;
    _installMessage = null;
    _emit();
    try {
      final outcome = await updates.install(
        info,
        onProgress: (p) {
          _installProgress = p;
          _emit();
        },
        onStatus: (m) {
          _installMessage = m;
          _emit();
        },
      );
      _installMessage = outcome.message;
      if (!outcome.ok) {
        _installing = false;
        _emit();
        return;
      }
      _emit();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      exit(0);
    } catch (e) {
      _installing = false;
      _installMessage = '更新失败：$e';
      _emit();
    }
  }

  Future<bool> openReleasePage() {
    final url = _update?.releaseUrl ?? updates.releasePageUrl;
    return openExternalUrl(url);
  }

  // ---- 生命周期 ----

  Future<void> shutdown() async {
    if (_shuttingDown) return;
    _shuttingDown = true;
    _stateTimer?.cancel();
    _logTimer?.cancel();
    _commandErrorTimer?.cancel();
    _stateTimer = null;
    _logTimer = null;
    await engine.stop();
    client.close();
  }

  void _emit() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stateTimer?.cancel();
    _logTimer?.cancel();
    _commandErrorTimer?.cancel();
    unawaited(engine.stop());
    client.close();
    super.dispose();
  }
}
