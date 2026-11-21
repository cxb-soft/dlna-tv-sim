import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 引擎返回 4xx/5xx 时抛出，message 用引擎给的中文描述，直接显示给用户。
class EngineApiException implements Exception {
  EngineApiException(this.message, {this.statusCode, this.code});

  final String message;
  final int? statusCode;
  final int? code;

  @override
  String toString() => message;
}

/// 本机引擎的 HTTP 客户端。只连 127.0.0.1，不经过任何代理设置。
class EngineClient {
  EngineClient(this.port);

  final int port;
  HttpClient? _http;

  HttpClient get _client => _http ??= HttpClient()
    ..connectionTimeout = const Duration(milliseconds: 1500)
    ..idleTimeout = const Duration(seconds: 6)
    ..findProxy = ((_) => 'DIRECT');

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.http('127.0.0.1:$port', path, query);

  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, String>? query,
    Duration timeout = const Duration(seconds: 4),
  }) =>
      _send('GET', path, query: query, timeout: timeout);

  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body, {
    Duration timeout = const Duration(seconds: 6),
  }) =>
      _send('POST', path, body: body, timeout: timeout);

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
    required Duration timeout,
  }) async {
    final HttpClientRequest req;
    try {
      req = await _client
          .openUrl(method, _uri(path, query))
          .timeout(const Duration(seconds: 2));
    } on TimeoutException {
      throw EngineApiException('引擎没有响应（连接超时）');
    } on SocketException catch (e) {
      throw EngineApiException('连不上引擎：${e.osError?.message ?? e.message}');
    }

    req.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    if (body != null) {
      final bytes = utf8.encode(jsonEncode(body));
      req.headers.contentType = ContentType.json;
      req.headers.contentLength = bytes.length;
      req.add(bytes);
    }

    final HttpClientResponse resp;
    try {
      resp = await req.close().timeout(timeout);
    } on TimeoutException {
      throw EngineApiException('引擎处理超时');
    }
    final text = await resp.transform(utf8.decoder).join().timeout(timeout);

    if (resp.statusCode >= 400) {
      var msg = 'HTTP ${resp.statusCode}';
      int? code;
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map) {
          final err = decoded['error'];
          if (err is String && err.trim().isNotEmpty) msg = err.trim();
          final c = decoded['code'];
          if (c is int) code = c;
        }
      } catch (_) {
        final trimmed = text.trim();
        if (trimmed.isNotEmpty && trimmed.length < 200) msg = trimmed;
      }
      throw EngineApiException(msg, statusCode: resp.statusCode, code: code);
    }

    if (text.trim().isEmpty) return const <String, dynamic>{};
    final decoded = jsonDecode(text);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    return <String, dynamic>{'value': decoded};
  }

  /// 轻量探活：只关心能不能拿到一份 state。
  Future<bool> ping({Duration timeout = const Duration(milliseconds: 900)}) async {
    try {
      await getJson('/api/state', timeout: timeout);
      return true;
    } catch (_) {
      return false;
    }
  }

  void close() {
    _http?.close(force: true);
    _http = null;
  }
}
