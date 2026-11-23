import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../models/update_info.dart';
import 'proxy_resolver.dart';

class UpdateCheckException implements Exception {
  UpdateCheckException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 更新服务：检查 GitHub Release、下载安装包、校验并交给系统完成替换。
///
/// UI 只依赖这个类（`check()` → `UpdateInfo?`，`install()` → `InstallOutcome`），
/// 不关心 GitHub 响应结构或各平台的安装细节，以后换更新源只要改这里。
class UpdateService {
  UpdateService({
    required this.currentVersion,
    this.repo = 'cxb-soft/dlna-tv-sim',
    this.assetNameOverride,
    this.appBundlePathOverride,
  });

  static const String _apiRoot = 'https://api.github.com/repos';
  static const String _checksumsName = 'SHA256SUMS.txt';

  /// 测试用：设置 DLNA_TV_SIM_UPDATE_API 可把更新接口指到本地模拟服务。
  static String get _apiRootResolved =>
      Platform.environment['DLNA_TV_SIM_UPDATE_API']?.trim().isNotEmpty == true
          ? Platform.environment['DLNA_TV_SIM_UPDATE_API']!.trim()
          : _apiRoot;

  final String currentVersion;
  final String repo;
  final String? assetNameOverride;

  /// 测试用：指定要替换的 .app 路径，避免 e2e 动到真正安装的 App。
  final String? appBundlePathOverride;

  /// 当前平台对应的安装包名，用于在 release 资产里挑下载地址。
  /// macOS 是可替换安装的 .app 压缩包；Windows 是带引擎和 mpv 的绿色包。
  String get platformAssetName {
    if (assetNameOverride != null && assetNameOverride!.isNotEmpty) {
      return assetNameOverride!;
    }
    if (Platform.isMacOS) return 'dlna-tv-sim-macos-app.zip';
    if (Platform.isWindows) return 'dlna-tv-sim-windows-app.zip';
    return 'dlna-tv-sim-linux.zip';
  }

  String get releasePageUrl => 'https://github.com/$repo/releases/latest';

  /// 有可用的新版本就返回它，否则（已是最新/接口异常）返回 null 或抛
  /// [UpdateCheckException]。UI 用它决定是否显示横幅。
  Future<UpdateInfo?> check({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final proxy = await ProxyResolver.resolve();
    final client =
        HttpClient()
          ..connectionTimeout = const Duration(seconds: 6)
          ..findProxy = ((uri) => ProxyResolver.forUri(uri, proxy));

    try {
      final req = await client
          .getUrl(Uri.parse('$_apiRootResolved/$repo/releases/latest'))
          .timeout(timeout);
      req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      req.headers.set(
        HttpHeaders.userAgentHeader,
        'DLNA-TV-Sim/$currentVersion',
      );
      final resp = await req.close().timeout(timeout);
      final body = await resp.transform(utf8.decoder).join().timeout(timeout);

      if (resp.statusCode == 404) {
        throw UpdateCheckException('仓库还没有发布 Release');
      }
      if (resp.statusCode == 403) {
        throw UpdateCheckException('GitHub 接口被限流了，过一会儿再试');
      }
      if (resp.statusCode != 200) {
        throw UpdateCheckException('更新检查失败（HTTP ${resp.statusCode}）');
      }

      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        throw UpdateCheckException('更新信息格式不对');
      }
      final json = Map<String, dynamic>.from(decoded);

      final tag = (json['tag_name'] as String? ?? '').trim();
      if (tag.isEmpty) return null;
      final version = tag.replaceFirst(RegExp(r'^[vV]'), '');
      if (!isNewer(version, currentVersion)) return null;

      String assetName = '';
      String assetUrl = '';
      String checksumsUrl = '';
      final assets = json['assets'];
      if (assets is List) {
        for (final item in assets) {
          if (item is! Map) continue;
          final name = item['name'] as String? ?? '';
          final url = item['browser_download_url'] as String? ?? '';
          if (name == platformAssetName) {
            assetName = name;
            assetUrl = url;
          } else if (name == _checksumsName) {
            checksumsUrl = url;
          }
        }
      }

      return UpdateInfo(
        version: version,
        tagName: tag,
        name: json['name'] as String? ?? '',
        notes: json['body'] as String? ?? '',
        releaseUrl: json['html_url'] as String? ?? releasePageUrl,
        assetName: assetName,
        assetUrl: assetUrl,
        checksumsUrl: checksumsUrl,
        publishedAt: DateTime.tryParse(json['published_at'] as String? ?? ''),
        prerelease: json['prerelease'] == true,
      );
    } on TimeoutException {
      throw UpdateCheckException('更新检查超时，网络可能不通');
    } on SocketException catch (e) {
      throw UpdateCheckException('连不上 GitHub：${e.message}');
    } on FormatException {
      throw UpdateCheckException('更新信息解析失败');
    } finally {
      client.close(force: true);
    }
  }

  /// 下载、校验并安装新版本。
  ///
  /// macOS：解压出新的 .app，写一个安装脚本，等当前进程退出后替换旧包并重新
  /// 打开；调用方在拿到 ok 之后应尽快退出 App。
  /// Windows：用 PowerShell 等进程退出后覆盖安装目录再拉起。
  Future<InstallOutcome> install(
    UpdateInfo info, {
    void Function(double progress)? onProgress,
    void Function(String status)? onStatus,
  }) async {
    if (info.assetUrl.isEmpty) {
      return const InstallOutcome(
        ok: false,
        message: '这个版本没有当前平台的安装包，请到 Release 页面手动下载。',
      );
    }
    if (!Platform.isMacOS && !Platform.isWindows) {
      return const InstallOutcome(
        ok: false,
        message: '当前平台暂不支持自动安装，请到 Release 页面手动下载。',
      );
    }

    try {
      final tmp = await Directory.systemTemp.createTemp('dlna-tv-update-');
      final zipPath = '${tmp.path}/${info.assetName}';

      onStatus?.call('正在下载 ${info.assetName}');
      await _download(info.assetUrl, zipPath, onProgress);

      if (info.checksumsUrl.isNotEmpty) {
        onStatus?.call('正在校验安装包');
        final sums = await _downloadText(info.checksumsUrl);
        final expected = _parseChecksum(sums, info.assetName);
        if (expected != null) {
          final actual = await _sha256OfFile(zipPath);
          if (actual != expected) {
            return const InstallOutcome(
              ok: false,
              message: '安装包校验失败，可能没下载完整，请重试。',
            );
          }
        }
      }

      onStatus?.call('正在安装');
      return Platform.isMacOS
          ? await _installMacOS(zipPath, tmp)
          : await _installWindows(zipPath, tmp);
    } on UpdateCheckException catch (e) {
      return InstallOutcome(ok: false, message: e.message);
    } catch (e) {
      return InstallOutcome(ok: false, message: '更新失败：$e');
    }
  }

  Future<void> _download(
    String url,
    String path,
    void Function(double progress)? onProgress,
  ) async {
    final proxy = await ProxyResolver.resolve();
    final client =
        HttpClient()
          ..connectionTimeout = const Duration(seconds: 10)
          ..findProxy = ((uri) => ProxyResolver.forUri(uri, proxy));
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(
        HttpHeaders.userAgentHeader,
        'DLNA-TV-Sim/$currentVersion',
      );
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw UpdateCheckException('下载失败（HTTP ${resp.statusCode}）');
      }
      final total = resp.contentLength;
      final sink = File(path).openWrite();
      var received = 0;
      try {
        await for (final chunk in resp) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) onProgress?.call(received / total);
        }
      } finally {
        await sink.close();
      }
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _downloadText(String url) async {
    final proxy = await ProxyResolver.resolve();
    final client =
        HttpClient()
          ..connectionTimeout = const Duration(seconds: 10)
          ..findProxy = ((uri) => ProxyResolver.forUri(uri, proxy));
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(
        HttpHeaders.userAgentHeader,
        'DLNA-TV-Sim/$currentVersion',
      );
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw UpdateCheckException('校验文件下载失败（HTTP ${resp.statusCode}）');
      }
      return await resp.transform(utf8.decoder).join();
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _sha256OfFile(String path) async {
    final digest = await sha256.bind(File(path).openRead()).first;
    return digest.toString();
  }

  /// 从 SHA256SUMS.txt 里取出指定文件的哈希；找不到返回 null（退化为不校验）。
  static String? _parseChecksum(String sums, String assetName) {
    for (final line in const LineSplitter().convert(sums)) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length >= 2 && parts.last == assetName) {
        return parts.first.toLowerCase();
      }
    }
    return null;
  }

  /// 当前 App 的 .app 路径，例如 /Applications/DLNA 电视.app
  String? _currentAppBundlePath() {
    if (appBundlePathOverride != null && appBundlePathOverride!.isNotEmpty) {
      return appBundlePathOverride;
    }
    final exe = Platform.resolvedExecutable;
    final index = exe.indexOf('/Contents/MacOS/');
    if (index < 0) return null;
    return exe.substring(0, index);
  }

  Future<InstallOutcome> _installMacOS(String zipPath, Directory tmp) async {
    final target = _currentAppBundlePath();
    if (target == null) {
      return const InstallOutcome(ok: false, message: '认不出当前 App 的位置，请手动下载安装。');
    }

    final extractDir = Directory('${tmp.path}/x');
    await extractDir.create(recursive: true);
    final unzip = await Process.run('/usr/bin/ditto', [
      '-x',
      '-k',
      zipPath,
      extractDir.path,
    ]);
    if (unzip.exitCode != 0) {
      return const InstallOutcome(ok: false, message: '解压安装包失败，请重试。');
    }

    final apps =
        extractDir
            .listSync()
            .whereType<Directory>()
            .where((d) => d.path.endsWith('.app'))
            .toList();
    if (apps.isEmpty) {
      return const InstallOutcome(
        ok: false,
        message: '安装包里没有 App，请到 Release 页面手动下载。',
      );
    }
    final newApp = apps.first.path;

    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      return const InstallOutcome(ok: false, message: '找不到用户目录，请手动下载安装。');
    }
    final workDir = Directory(
      '$home/Library/Application Support/DLNA 电视/update',
    );
    await workDir.create(recursive: true);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final script = File('${workDir.path}/install-$stamp.sh');
    final log = File('${workDir.path}/install-$stamp.log');
    final plist = File(
      '$home/Library/LaunchAgents/com.cxbsoft.dlna-tv-sim.update.plist',
    );

    final uidResult = await Process.run('/usr/bin/id', ['-u']);
    final uid = uidResult.stdout.toString().trim();
    if (uidResult.exitCode != 0 || uid.isEmpty) {
      return const InstallOutcome(ok: false, message: '找不到当前用户，请手动下载安装。');
    }

    // 安装器必须交给 launchd，不能作为 App 的子进程：App 退出后子进程会被
    // 一起收掉，表现就是“下载完 App 退出、没有后续”。
    await script.writeAsString(r'''#!/bin/sh
set -u
PID="$1"; TARGET="$2"; NEW="$3"; PLIST="$4"; LOG="$5"
exec >>"$LOG" 2>&1
echo "=== $(date) update start pid=$PID target=$TARGET"

i=0
while kill -0 "$PID" 2>/dev/null; do
  i=$((i+1))
  if [ "$i" -gt 900 ]; then
    echo "timeout waiting for app to exit"
    exit 1
  fi
  sleep 0.2
done

# 旧引擎/播放器可能还占着 App 包里的可执行文件/端口，先结束它们。
/usr/bin/pkill -f "$TARGET/Contents/MacOS" 2>/dev/null || true
/usr/bin/pkill -f "$TARGET/Contents/Resources/engine/dlna-tv-sim" 2>/dev/null || true
/usr/bin/pkill -f "$TARGET/Contents/Resources/engine/mpv" 2>/dev/null || true
sleep 0.5

PARENT=$(dirname "$TARGET")
if [ ! -w "$PARENT" ]; then
  echo "no write permission: $PARENT"
  exit 1
fi

BACKUP="$TARGET.bak-$(date +%s)"
if [ -e "$TARGET" ]; then
  mv "$TARGET" "$BACKUP" || { echo "backup failed"; exit 1; }
fi

if ! /usr/bin/ditto "$NEW" "$TARGET"; then
  echo "ditto failed; restoring old app"
  rm -rf "$TARGET"
  if [ -e "$BACKUP" ]; then mv "$BACKUP" "$TARGET"; fi
  /usr/bin/open "$TARGET" 2>/dev/null || true
  exit 1
fi

/usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
if ! /usr/bin/open "$TARGET"; then
  echo "open new app failed; restoring old app"
  rm -rf "$TARGET"
  if [ -e "$BACKUP" ]; then mv "$BACKUP" "$TARGET"; fi
  /usr/bin/open "$TARGET" 2>/dev/null || true
  exit 1
fi

rm -rf "$BACKUP"
rm -f "$PLIST"
echo "=== update done"
exit 0
''');

    final plistXml = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.cxbsoft.dlna-tv-sim.update</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>${_xmlEscape(script.path)}</string>
    <string>$pid</string>
    <string>${_xmlEscape(target)}</string>
    <string>${_xmlEscape(newApp)}</string>
    <string>${_xmlEscape(plist.path)}</string>
    <string>${_xmlEscape(log.path)}</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>${_xmlEscape(log.path)}</string>
  <key>StandardErrorPath</key><string>${_xmlEscape(log.path)}</string>
</dict>
</plist>
''';

    await Process.run('/bin/launchctl', ['bootout', 'gui/$uid', plist.path]);
    await plist.parent.create(recursive: true);
    await plist.writeAsString(plistXml);
    final bootstrap = await Process.run('/bin/launchctl', [
      'bootstrap',
      'gui/$uid',
      plist.path,
    ]);
    if (bootstrap.exitCode != 0) {
      final err = bootstrap.stderr.toString().trim();
      return InstallOutcome(
        ok: false,
        message: '无法启动系统安装器${err.isEmpty ? '' : '：$err'}（日志：${log.path}）',
      );
    }

    return const InstallOutcome(
      ok: true,
      message: '更新已下载，App 会退出，由系统安装器替换并重启。',
    );
  }

  static String _xmlEscape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  Future<InstallOutcome> _installWindows(String zipPath, Directory tmp) async {
    final targetDir = File(Platform.resolvedExecutable).parent.path;
    final base = Platform.environment['LOCALAPPDATA'] ?? tmp.path;
    final workDir = Directory('$base/DLNA 电视/update');
    await workDir.create(recursive: true);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final script = File('${workDir.path}/install-$stamp.ps1');
    final log = File('${workDir.path}/install-$stamp.log');

    await script.writeAsString(r'''
param([int]$TargetPid, [string]$Target, [string]$Zip, [string]$Log)
Start-Transcript -Path $Log -Append
Write-Host "=== update start $(Get-Date) pid=$TargetPid target=$Target"
Wait-Process -Id $TargetPid -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 800

# 旧 engine、App 实例和它拉起的 mpv 都可能锁着目标目录里的 exe/DLL，按 target 路径结束它们。
Write-Host "stopping app/engine/mpv under $Target"
Get-CimInstance Win32_Process -Filter "Name = 'dlna_tv_sim.exe'" |
  Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($Target, [System.StringComparison]::OrdinalIgnoreCase) } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-CimInstance Win32_Process -Filter "Name = 'dlna-tv-sim.exe'" |
  Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($Target, [System.StringComparison]::OrdinalIgnoreCase) } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-CimInstance Win32_Process -Filter "Name = 'mpv.exe'" |
  Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($Target, [System.StringComparison]::OrdinalIgnoreCase) } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 800

$dir = Join-Path $env:TEMP ("dlna-tv-update-" + [guid]::NewGuid().ToString("N"))
Expand-Archive -Path $Zip -DestinationPath $dir -Force
$copied = $false
for ($i = 0; $i -lt 20; $i++) {
  try {
    Copy-Item -Path (Join-Path $dir "*") -Destination $Target -Recurse -Force -ErrorAction Stop
    $copied = $true
    break
  } catch {
    Write-Host "copy attempt $i failed: $_"
    Start-Sleep -Milliseconds 500
  }
}
if (-not $copied) {
  Write-Host "copy failed"
  Stop-Transcript
  exit 1
}
$exe = Get-ChildItem -Path $Target -Filter "dlna_tv_sim.exe" | Select-Object -First 1
if (-not $exe) { $exe = Get-ChildItem -Path $Target -Filter "*.exe" | Select-Object -First 1 }
if ($exe) { Start-Process -FilePath $exe.FullName }
Stop-Transcript
''');

    try {
      await Process.start('powershell', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script.path,
        '-TargetPid',
        pid.toString(),
        '-Target',
        targetDir,
        '-Zip',
        zipPath,
        '-Log',
        log.path,
      ], mode: ProcessStartMode.detached);
    } catch (e) {
      return InstallOutcome(
        ok: false,
        message: '无法启动 Windows 安装器：$e（日志：${log.path}）',
      );
    }
    return const InstallOutcome(
      ok: true,
      message: '更新已下载，App 会退出，由系统安装器替换并重启。',
    );
  }

  /// 语义化版本比较：忽略 v 前缀和预发布后缀，按数字段比较。
  static bool isNewer(String candidate, String current) {
    final a = _numbers(candidate);
    final b = _numbers(current);
    for (var i = 0; i < 3; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }

  static List<int> _numbers(String version) {
    final core = version.split('-').first.split('+').first;
    return core
        .split('.')
        .map(
          (part) => int.tryParse(part.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0,
        )
        .toList();
  }
}

/// 用系统默认方式打开链接。Windows 用 rundll32，不经过 cmd/shell。
Future<bool> openExternalUrl(String url) async {
  if (url.trim().isEmpty) return false;
  try {
    if (Platform.isMacOS) {
      final r = await Process.run('/usr/bin/open', [url]);
      return r.exitCode == 0;
    }
    if (Platform.isWindows) {
      final r = await Process.run('rundll32', [
        'url.dll,FileProtocolHandler',
        url,
      ]);
      return r.exitCode == 0;
    }
    final r = await Process.run('xdg-open', [url]);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}
