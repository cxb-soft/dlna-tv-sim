/// 把引擎 `/api/state` 的 JSON 映射成界面用的模型。
/// 字段名以 Go 侧 `StateJSON` 的 json tag 为准，缺字段一律给安全默认值，
/// 这样引擎升级多/少字段时界面不会因为解析失败白屏。
library;

double _asDouble(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? 0;
  return 0;
}

int _asInt(Object? v) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

String _asString(Object? v) => v is String ? v : (v == null ? '' : '$v');

bool _asBool(Object? v) => v == true || v == 'true' || v == 1;

List<String> _asStrings(Object? v) {
  if (v is List) {
    return v.whereType<Object>().map(_asString).where((s) => s.isNotEmpty).toList();
  }
  return const [];
}

class TrackInfo {
  const TrackInfo({
    this.id = 0,
    this.type = '',
    this.title = '',
    this.lang = '',
    this.codec = '',
    this.selected = false,
  });

  final int id;
  final String type;
  final String title;
  final String lang;
  final String codec;
  final bool selected;

  factory TrackInfo.fromJson(Map<String, dynamic> j) => TrackInfo(
        id: _asInt(j['id']),
        type: _asString(j['type']),
        title: _asString(j['title']),
        lang: _asString(j['lang']),
        codec: _asString(j['codec']),
        selected: _asBool(j['selected']),
      );
}

class PlayerStats {
  const PlayerStats({this.bitrateKbps = 0, this.fps = 0});

  final double bitrateKbps;
  final double fps;

  factory PlayerStats.fromJson(Map<String, dynamic> j) => PlayerStats(
        bitrateKbps: _asDouble(j['bitrate_kbps']),
        fps: _asDouble(j['fps']),
      );
}

class ProbeInfo {
  const ProbeInfo({this.status = '', this.detail = '', this.contentType = ''});

  final String status;
  final String detail;
  final String contentType;

  factory ProbeInfo.fromJson(Map<String, dynamic> j) => ProbeInfo(
        status: _asString(j['status']),
        detail: _asString(j['detail']),
        contentType: _asString(j['content_type']),
      );
}

class EngineState {
  const EngineState({
    this.friendlyName = '',
    this.uuid = '',
    this.modelName = '',
    this.state = '',
    this.status = '',
    this.uri = '',
    this.title = '',
    this.meta = '',
    this.nextUri = '',
    this.duration = 0,
    this.position = 0,
    this.volume = 0,
    this.mute = false,
    this.playMode = '',
    this.subscribers = 0,
    this.msearch = 0,
    this.soapCalls = 0,
    this.probe = const ProbeInfo(),
    this.addresses = const [],
    this.port = 0,
    this.uptimeSeconds = 0,
    this.player = '',
    this.version = '',
    this.speed = 1,
    this.loop = false,
    this.aspect = '',
    this.tracks = const [],
    this.capabilities = const [],
    this.stats = const PlayerStats(),
  });

  final String friendlyName;
  final String uuid;
  final String modelName;
  final String state;
  final String status;
  final String uri;
  final String title;
  final String meta;
  final String nextUri;
  final double duration;
  final double position;
  final int volume;
  final bool mute;
  final String playMode;
  final int subscribers;
  final int msearch;
  final int soapCalls;
  final ProbeInfo probe;
  final List<String> addresses;
  final int port;
  final int uptimeSeconds;
  final String player;
  final String version;
  final double speed;
  final bool loop;
  final String aspect;
  final List<TrackInfo> tracks;
  final List<String> capabilities;
  final PlayerStats stats;

  bool get playing => state == 'PLAYING';
  bool get paused => state == 'PAUSED_PLAYBACK';
  bool get transitioning => state == 'TRANSITIONING';
  bool get hasMedia => uri.isNotEmpty;

  /// 「待机」和「已停止」在界面上要分开：前者是没投过东西，后者是投过但停了。
  String get stateLabel {
    switch (state) {
      case 'PLAYING':
        return '正在播放';
      case 'PAUSED_PLAYBACK':
        return '已暂停';
      case 'TRANSITIONING':
        return '准备中';
      case 'STOPPED':
        return hasMedia ? '已停止' : '待机';
      default:
        return hasMedia ? '就绪' : '待机';
    }
  }

  String get displayTitle {
    if (title.trim().isNotEmpty) return title.trim();
    if (uri.trim().isEmpty) return '';
    final parsed = Uri.tryParse(uri);
    if (parsed == null) return uri;
    final seg = parsed.pathSegments.where((s) => s.isNotEmpty).toList();
    if (seg.isNotEmpty) return Uri.decodeComponent(seg.last);
    return parsed.host.isNotEmpty ? parsed.host : uri;
  }

  /// 投屏来源（手机名/主机名）：优先用 DIDL-Lite 里的元数据。
  String get sourceLabel {
    final m = RegExp(r'<dc:creator>([^<]+)</dc:creator>').firstMatch(meta);
    if (m != null) return m.group(1) ?? '';
    final p = Uri.tryParse(uri);
    return p?.host ?? '';
  }

  bool supports(String capability) => capabilities.contains(capability);

  factory EngineState.fromJson(Map<String, dynamic> j) => EngineState(
        friendlyName: _asString(j['friendly_name']),
        uuid: _asString(j['uuid']),
        modelName: _asString(j['model_name']),
        state: _asString(j['state']),
        status: _asString(j['status']),
        uri: _asString(j['uri']),
        title: _asString(j['title']),
        meta: _asString(j['meta']),
        nextUri: _asString(j['next_uri']),
        duration: _asDouble(j['duration']),
        position: _asDouble(j['position']),
        volume: _asInt(j['volume']),
        mute: _asBool(j['mute']),
        playMode: _asString(j['play_mode']),
        subscribers: _asInt(j['subscribers']),
        msearch: _asInt(j['msearch']),
        soapCalls: _asInt(j['soap_calls']),
        probe: j['probe'] is Map
            ? ProbeInfo.fromJson(Map<String, dynamic>.from(j['probe'] as Map))
            : const ProbeInfo(),
        addresses: _asStrings(j['addresses']),
        port: _asInt(j['port']),
        uptimeSeconds: _asInt(j['uptime']),
        player: _asString(j['player']),
        version: _asString(j['version']),
        speed: _asDouble(j['speed']) == 0 ? 1 : _asDouble(j['speed']),
        loop: _asBool(j['loop']),
        aspect: _asString(j['aspect']),
        tracks: (j['tracks'] is List)
            ? (j['tracks'] as List)
                .whereType<Map>()
                .map((e) => TrackInfo.fromJson(Map<String, dynamic>.from(e)))
                .toList()
            : const [],
        capabilities: _asStrings(j['capabilities']),
        stats: j['stats'] is Map
            ? PlayerStats.fromJson(Map<String, dynamic>.from(j['stats'] as Map))
            : const PlayerStats(),
      );
}

class LogEntry {
  const LogEntry({this.id = 0, this.at = '', this.kind = '', this.text = ''});

  final int id;
  final String at;
  final String kind;
  final String text;

  factory LogEntry.fromJson(Map<String, dynamic> j) => LogEntry(
        id: _asInt(j['id']),
        at: _asString(j['at']),
        kind: _asString(j['kind']),
        text: _asString(j['text']),
      );
}

class DiagResult {
  const DiagResult({
    this.port = 0,
    this.addresses = const [],
    this.multicastOk = false,
    this.multicastErr = '',
    this.broadcastAddr = '',
    this.broadcastOk = false,
    this.broadcastErr = '',
    this.msearchCount = 0,
    this.subscribers = 0,
    this.hints = const [],
    this.checkedAt = '',
  });

  final int port;
  final List<String> addresses;
  final bool multicastOk;
  final String multicastErr;
  final String broadcastAddr;
  final bool broadcastOk;
  final String broadcastErr;
  final int msearchCount;
  final int subscribers;
  final List<String> hints;
  final String checkedAt;

  factory DiagResult.fromJson(Map<String, dynamic> j) => DiagResult(
        port: _asInt(j['port']),
        addresses: _asStrings(j['addresses']),
        multicastOk: _asBool(j['multicast_ok']),
        multicastErr: _asString(j['multicast_err']),
        broadcastAddr: _asString(j['broadcast_addr']),
        broadcastOk: _asBool(j['broadcast_ok']),
        broadcastErr: _asString(j['broadcast_err']),
        msearchCount: _asInt(j['msearch_count']),
        subscribers: _asInt(j['subscribers']),
        hints: _asStrings(j['hints']),
        checkedAt: _asString(j['checked_at']),
      );
}
