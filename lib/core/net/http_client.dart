/// 极简 HTTP GET 工具 —— 移植自旧 net/Http.java（改用 dart:io HttpClient）。
///
/// - keep-alive 连接池：dart:io HttpClient 自带连接复用，全程复用同一个实例；
/// - 失败熔断：同一主机连续失败 [HostBreaker.failThreshold] 次后冷却，冷却期内
///   请求立刻失败返回，不再让每一首都干等满超时；
/// - 连接超时与读取超时分开：连接 3.5s，读取用调用方给的预算（国内源 5s / 海外源 8s）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'net_tuning.dart';

/// 主机熔断状态（可单独测试）。
class HostBreaker {
  /// 连续失败多少次后进入冷却。
  static const int failThreshold = 2;

  /// 冷却时长。
  static const int cooldownMs = 45000;

  /// 被限流（429/403/405）时冷却更久。
  static const int rateLimitCooldownMs = 90000;

  final Map<String, _HostState> _hosts = <String, _HostState>{};

  _HostState _state(String host) =>
      _hosts.putIfAbsent(host, () => _HostState());

  bool isCoolingDown(String host) =>
      _state(host).cooldownUntil > DateTime.now().millisecondsSinceEpoch;

  /// 冷却剩余秒数；未冷却返回 0。
  int cooldownSecondsLeft(String host) {
    final int left =
        _state(host).cooldownUntil - DateTime.now().millisecondsSinceEpoch;
    return left <= 0 ? 0 : (left ~/ 1000 + 1);
  }

  void noteOk(String host) {
    final _HostState s = _state(host);
    s.fails = 0;
    s.cooldownUntil = 0;
    s.reason = '';
  }

  void noteFail(String host, String reason, {int cooldown = cooldownMs}) {
    final _HostState s = _state(host);
    s.reason = reason;
    s.fails++;
    if (s.fails >= failThreshold) {
      s.cooldownUntil = DateTime.now().millisecondsSinceEpoch + cooldown;
      s.fails = 0;
    }
  }
}

class _HostState {
  int fails = 0;
  int cooldownUntil = 0;
  String reason = '';
}

/// 极简 HTTP GET（纯 Dart）。
abstract final class Http {
  static const String userAgent = 'MusicOrganizerFlutter/2.5 (local utility)';

  /// 连接（握手）超时：卡住就尽快判定这个源不可用。
  static const int connectTimeoutMs = 3500;

  static const int textMaxBytes = 4 * 1024 * 1024;

  /// 全局熔断器。
  static final HostBreaker breaker = HostBreaker();

  static HttpClient? _client;

  static HttpClient client() {
    _client ??= HttpClient()
      ..connectionTimeout =
          Duration(milliseconds: NetTuning.scale(connectTimeoutMs))
      ..maxConnectionsPerHost = 8;
    return _client!;
  }

  /// 带查询参数的 GET，返回 JSON（Object / List / 其它）或 null。
  static Future<Object?> getJson(String url, Map<String, String>? params,
      Map<String, String>? headers, int timeoutMs) async {
    final String? text = await getText(url, params, headers, timeoutMs);
    if (text == null) return null;
    try {
      return jsonDecode(text);
    } catch (_) {
      return null;
    }
  }

  /// GET 并返回原始文本。
  static Future<String?> getText(String url, Map<String, String>? params,
      Map<String, String>? headers, int timeoutMs) async {
    final Uint8List? body =
        await getBytes(url, params, headers, timeoutMs, textMaxBytes);
    if (body == null) return null;
    final String text = utf8.decode(body, allowMalformed: false).trim();
    if (text.isEmpty) return null;
    return text;
  }

  /// GET 并返回原始字节（封面图片这类二进制用）。失败返回 null。
  static Future<Uint8List?> getBytes(String url, Map<String, String>? params,
      Map<String, String>? headers, int timeoutMs, int maxBytes) async {
    final String host = _hostOf(url);
    if (breaker.isCoolingDown(host)) return null;
    try {
      final String full = buildUrl(url, params);
      final Uri uri = Uri.parse(full);
      final HttpClientRequest req = await client()
          .getUrl(uri)
          .timeout(Duration(milliseconds: NetTuning.scale(connectTimeoutMs)));
      req.headers.set('Connection', 'keep-alive');
      req.headers.set('User-Agent', userAgent);
      req.headers.set('Accept', 'application/json, text/plain, */*');
      if (headers != null) {
        headers.forEach((String k, String v) => req.headers.set(k, v));
      }
      final HttpClientResponse resp = await req.close().timeout(
          Duration(milliseconds: NetTuning.scale(timeoutMs)));
      final int code = resp.statusCode;
      if (code >= 400) {
        if (code == 429 || code == 403 || code == 405) {
          breaker.noteFail(host, 'HTTP $code 限流',
              cooldown: HostBreaker.rateLimitCooldownMs);
        } else if (code >= 500) {
          breaker.noteFail(host, 'HTTP $code');
        }
        await resp.drain<void>();
        return null;
      }
      final Uint8List body = await _readAll(resp, maxBytes).timeout(
          Duration(milliseconds: NetTuning.scale(timeoutMs)));
      breaker.noteOk(host);
      if (body.isEmpty) return null;
      return body;
    } catch (e) {
      breaker.noteFail(host, e.runtimeType.toString());
      return null;
    }
  }

  /// 拼接查询串（编码后）。
  static String buildUrl(String url, Map<String, String>? params) {
    if (params == null || params.isEmpty) return url;
    final StringBuffer sb = StringBuffer(url);
    sb.write(url.contains('?') ? '&' : '?');
    bool first = true;
    for (final MapEntry<String, String> e in params.entries) {
      if (!first) sb.write('&');
      first = false;
      sb.write(Uri.encodeQueryComponent(e.key));
      sb.write('=');
      sb.write(Uri.encodeQueryComponent(e.value));
    }
    return sb.toString();
  }

  static String _hostOf(String url) {
    try {
      final String? h = Uri.tryParse(url)?.host;
      return h == null || h.isEmpty ? url : h;
    } catch (_) {
      return url;
    }
  }

  static Future<Uint8List> _readAll(
      HttpClientResponse resp, int maxBytes) async {
    final BytesBuilder builder = BytesBuilder();
    await for (final List<int> chunk in resp) {
      builder.add(chunk);
      if (maxBytes > 0 && builder.length > maxBytes) {
        throw const FormatException('响应超过上限');
      }
    }
    return builder.takeBytes();
  }
}
