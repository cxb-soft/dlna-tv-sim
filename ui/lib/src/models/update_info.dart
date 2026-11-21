/// 更新检查用的模型。App 只依赖 [UpdateService]，这一层不含安装逻辑。
library;

class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.tagName,
    this.name = '',
    this.notes = '',
    this.releaseUrl = '',
    this.assetName = '',
    this.assetUrl = '',
    this.checksumsUrl = '',
    this.publishedAt,
    this.prerelease = false,
  });

  /// 去掉前缀 v 的版本号，例如 0.4.0
  final String version;

  /// 原始 tag，例如 v0.4.0
  final String tagName;
  final String name;

  /// Release 正文（Markdown），展示时截断。
  final String notes;
  final String releaseUrl;

  /// 当前平台对应的资产名与下载地址；没有匹配资产时为空。
  final String assetName;
  final String assetUrl;

  /// SHA256SUMS.txt 的下载地址，用于安装前校验。
  final String checksumsUrl;
  final DateTime? publishedAt;
  final bool prerelease;

  String get title => name.trim().isNotEmpty ? name.trim() : 'v$version';
}

class InstallOutcome {
  const InstallOutcome({required this.ok, required this.message});

  final bool ok;
  final String message;
}
