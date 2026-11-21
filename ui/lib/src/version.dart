import 'dart:io';

/// 应用版本：与 Go 引擎的 `version` 变量、pubspec 的 version 保持一致。
/// GitHub Release 的 tag 用 `v0.3.0` 这种形式，更新检查只比较数字部分。
const String kAppVersion = '0.4.1';

/// 允许用环境变量覆盖版本号，发布前演练更新提示时用（例如假装自己是 0.2.0）。
String resolveAppVersion() {
  final raw = Platform.environment['DLNA_TV_SIM_APP_VERSION'];
  if (raw != null && raw.trim().isNotEmpty) return raw.trim();
  return kAppVersion;
}

/// 默认引擎 HTTP 端口。8090 是正式实例的端口，测试时可用环境变量临时改写：
/// `DLNA_TV_SIM_PORT=8091`
int resolveEnginePort() {
  const compiled = int.fromEnvironment('DLNA_TV_SIM_PORT');
  if (compiled > 0 && compiled < 65536) return compiled;
  final raw = Platform.environment['DLNA_TV_SIM_PORT'];
  final port = int.tryParse((raw ?? '').trim());
  if (port != null && port > 0 && port < 65536) return port;
  return 8090;
}
