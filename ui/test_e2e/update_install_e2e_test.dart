// 端到端验证 app 内更新：真实走一遍
//   下载 → SHA256 校验 → 写一次性 LaunchAgent → App 退出 → launchd 替换 .app → 重启
//
// 只在 macOS 上、手动运行，不纳入默认 `flutter test`：
//   flutter test test_e2e/update_install_e2e_test.dart
//
// 它替换的是 /tmp 下的假 App，不会动到 /Applications 里真正安装的包。
// 测试进程本身会退出，正好扮演“App 退出后由 launchd 接手”的角色；
// 替换结果的校验在脚本末尾用 shell 完成（见 test_e2e/README.md）。
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dlna_tv_sim/src/models/update_info.dart';
import 'package:dlna_tv_sim/src/services/update_service.dart';

void main() {
  test('app 内更新经 launchd 完成替换', () async {
    if (!Platform.isMacOS) {
      return;
    }

    final stamp = DateTime.now().millisecondsSinceEpoch;
    final root = Directory('/tmp/dlna-update-e2e-$stamp');
    await root.create(recursive: true);

    String appPath(String dir, String name) => '$dir/$name.app';

    // 旧 App：版本 0.5.2，被启动时留下 old-launched.txt。
    final oldApp = appPath('${root.path}/target', 'DLNA 电视');
    // 新 App：版本 0.5.3，被启动时留下 launched.txt。
    final newApp = appPath('${root.path}/new', 'DLNA 电视');

    void writeApp(String app, String version, String marker) {
      Directory('$app/Contents/MacOS').createSync(recursive: true);
      File('$app/Contents/Info.plist').writeAsStringSync(
        '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>launcher</string>
<key>CFBundleIdentifier</key><string>com.cxbsoft.dlnatvsim.e2e</string>
<key>CFBundleName</key><string>DLNA 电视</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
</dict></plist>
''',
      );
      final launcher = File('$app/Contents/MacOS/launcher')..writeAsStringSync(
        '#!/bin/sh\necho "launched" >> "${root.path}/$marker"\nsleep 60\n',
      );
      Process.runSync('/bin/chmod', ['755', launcher.path]);
    }

    writeApp(oldApp, '0.5.2', 'old-launched.txt');
    writeApp(newApp, '0.5.3', 'launched.txt');

    // 打成更新资产，并算出 SHA256。
    final zipPath = '${root.path}/dlna-tv-sim-macos-app.zip';
    final zipResult = await Process.run('/usr/bin/ditto', [
      '-c',
      '-k',
      '--sequesterRsrc',
      '--keepParent',
      newApp,
      zipPath,
    ]);
    expect(zipResult.exitCode, 0, reason: '打包假 App 失败：${zipResult.stderr}');

    final assetBytes = await File(zipPath).readAsBytes();
    final digest = sha256.convert(assetBytes).toString();

    // 本地更新源：资产 + SHA256SUMS.txt。
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final res = req.response;
      if (req.uri.path == '/asset.zip') {
        res.headers.contentType = ContentType.binary;
        res.add(assetBytes);
      } else if (req.uri.path == '/SHA256SUMS.txt') {
        res.headers.contentType = ContentType.text;
        res.write('$digest  dlna-tv-sim-macos-app.zip\n');
      } else {
        res.statusCode = 404;
      }
      await res.close();
    });
    final base = 'http://127.0.0.1:${server.port}';

    final service = UpdateService(
      currentVersion: '0.5.2',
      assetNameOverride: 'dlna-tv-sim-macos-app.zip',
      appBundlePathOverride: oldApp,
    );

    final outcome = await service.install(
      UpdateInfo(
        version: '0.5.3',
        tagName: 'v0.5.3',
        assetName: 'dlna-tv-sim-macos-app.zip',
        assetUrl: '$base/asset.zip',
        checksumsUrl: '$base/SHA256SUMS.txt',
      ),
    );

    expect(outcome.ok, isTrue, reason: outcome.message);
    // 脚本和日志落在用户的更新目录里，方便排查。
    expect(outcome.message, contains('系统安装器'));

    // 这份输出给外面的 shell 用：等测试进程退出后核对替换结果。
    // ignore: avoid_print
    print('E2E_ROOT=${root.path}');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
