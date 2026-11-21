/// 界面里反复用到的小格式化工具。
library;

String fmtClock(double seconds) {
  var total = seconds.isFinite && seconds > 0 ? seconds.round() : 0;
  final h = total ~/ 3600;
  total %= 3600;
  final m = total ~/ 60;
  final s = total % 60;
  if (h > 0) {
    return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

String fmtUptime(int seconds) {
  if (seconds <= 0) return '刚刚';
  if (seconds < 60) return '$seconds 秒';
  final minutes = seconds ~/ 60;
  if (minutes < 60) return '$minutes 分钟';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  if (hours < 24) return rest == 0 ? '$hours 小时' : '$hours 小时 $rest 分';
  final days = hours ~/ 24;
  return '$days 天 ${hours % 24} 小时';
}

String fmtBitrate(double kbps) {
  if (!kbps.isFinite || kbps <= 0) return '';
  if (kbps >= 1000) return '${(kbps / 1000).toStringAsFixed(1)} Mbps';
  return '${kbps.round()} Kbps';
}

String fmtFps(double fps) {
  if (!fps.isFinite || fps <= 0) return '';
  return '${fps.round()} fps';
}

/// 从 URL 里取一个适合列表显示的名字：优先最后一段路径。
String urlLabel(String url) {
  final parsed = Uri.tryParse(url);
  if (parsed == null) return url;
  final segments = parsed.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.isNotEmpty) {
    final last = Uri.decodeComponent(segments.last);
    if (last.length <= 42) return last;
    return '${last.substring(0, 39)}…';
  }
  return parsed.host.isNotEmpty ? parsed.host : url;
}

String urlHost(String url) {
  final parsed = Uri.tryParse(url);
  return parsed?.host ?? '';
}

/// 更新说明：去掉 Markdown 的标题、加粗和裸链接，取前几行适合放在横幅里。
String summarizeNotes(String notes, {int maxLines = 2, int maxChars = 180}) {
  final lines = notes
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty && !line.startsWith('---'))
      .where((line) => !line.toLowerCase().startsWith('**full changelog'))
      .where((line) => !line.toLowerCase().startsWith('full changelog'))
      .map((line) => line.replaceFirst(RegExp(r'^#{1,6}\s*'), '').trim())
      .map((line) => line.replaceAll(RegExp(r'https?://\S+'), '').trim())
      .map((line) => line.replaceAll('**', '').replaceAll('`', '').trim())
      .map((line) => line.replaceFirst(RegExp(r'^[-*]\s+'), '· '))
      .where((line) => line.isNotEmpty)
      .toList();
  final text = lines.take(maxLines).join('　');
  if (text.length <= maxChars) return text;
  return '${text.substring(0, maxChars)}…';
}
