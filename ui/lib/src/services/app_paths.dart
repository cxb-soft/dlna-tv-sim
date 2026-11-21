import 'dart:io';

/// 各平台的应用数据/日志目录。全部用 `/` 拼接，Dart 的 File API 在 Windows 上也认。
class AppPaths {
  static String get _home => Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      Directory.current.path;

  static Directory supportDir() {
    if (Platform.isMacOS) {
      return Directory('$_home/Library/Application Support/com.cxbsoft.dlna-tv-sim');
    }
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'] ?? _home;
      return Directory('$appData/DLNA TV');
    }
    final xdg = Platform.environment['XDG_CONFIG_HOME'] ?? '$_home/.config';
    return Directory('$xdg/dlna-tv-sim');
  }

  static Directory logDir() {
    if (Platform.isMacOS) {
      return Directory('$_home/Library/Logs/DLNA 电视');
    }
    if (Platform.isWindows) {
      final local = Platform.environment['LOCALAPPDATA'] ?? supportDir().path;
      return Directory('$local/DLNA TV/logs');
    }
    final state = Platform.environment['XDG_STATE_HOME'] ?? '$_home/.local/state';
    return Directory('$state/dlna-tv-sim');
  }
}
