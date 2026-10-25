/// 代理配置 —— 让「联网源」在需要代理的网络里也能用。
///
/// 三种模式：
/// - [ProxyMode.direct]：直连（默认，符合「零环境依赖」：没代理的机器开箱即用）；
/// - [ProxyMode.auto]：读环境变量（`HTTPS_PROXY` / `HTTP_PROXY` / `ALL_PROXY`），
///   桌面用户点一下就能跟着系统/终端里已有的代理走；
/// - [ProxyMode.manual]：手填 `主机:端口`，界面里可测连通性。
///
/// 说明（别指望它做更多）：
/// 1. `dart:io` 的 `HttpClient.findProxy` **只支持 HTTP 代理**（`PROXY host:port`），
///    不支持 SOCKS5；手填 `socks5://` 会明确拒绝并给出提示，而不是悄悄直连。
/// 2. 安卓上没有「应用内读系统代理」的公开途径，`auto` 在安卓等价于直连；
///    安卓侧建议用系统代理/VPN（那是网络层的，应用无需感知）。
/// 3. 代理只影响本应用的 HTTP 客户端，不改系统设置。
library;

import 'dart:io';

/// 代理模式。
enum ProxyMode { direct, auto, manual }

/// 一次解析出来的代理地址。
class ProxyEndpoint {
  const ProxyEndpoint(this.host, this.port);

  final String host;
  final int port;

  /// `HttpClient.findProxy` 要的写法。
  String get spec => 'PROXY $host:$port';

  String get label => '$host:$port';

  @override
  String toString() => label;
}

/// 全局代理配置（纯 Dart，可离线单测）。
abstract final class NetworkProxy {
  static ProxyMode _mode = ProxyMode.direct;
  static ProxyEndpoint? _manual;
  static ProxyEndpoint? _auto;
  static String _lastError = '';

  static ProxyMode get mode => _mode;
  static String get lastError => _lastError;

  /// 当前真正生效的代理（无代理返回 null）。
  static ProxyEndpoint? get effective {
    switch (_mode) {
      case ProxyMode.direct:
        return null;
      case ProxyMode.auto:
        return _auto;
      case ProxyMode.manual:
        return _manual;
    }
  }

  /// 配置；[error] 非空表示填的内容不能用（此时退回直连，并把原因留给界面显示）。
  static void configure(
    ProxyMode mode, {
    String host = '',
    String port = '',
    Map<String, String>? env,
  }) {
    _lastError = '';
    _auto = parseEnv(env ?? Platform.environment);
    if (mode == ProxyMode.manual) {
      final ProxyEndpoint? ep = parseSpec('$host:$port');
      if (ep == null) {
        _lastError = '代理地址要写成「主机:端口」，例如 127.0.0.1:7890';
        _manual = null;
        _mode = ProxyMode.direct;
        return;
      }
      _manual = ep;
    }
    _mode = mode;
  }

  /// 给 `HttpClient.findProxy` 用：返回 `PROXY h:p` 或 `DIRECT`。
  static String findProxy(Uri uri) => effective?.spec ?? 'DIRECT';

  /// 从环境变量里找代理（大小写都认，`ALL_PROXY` 兜底）。
  static ProxyEndpoint? parseEnv(Map<String, String> env) {
    for (final String key in <String>[
      'HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy', 'ALL_PROXY', 'all_proxy',
    ]) {
      final String? v = env[key];
      if (v == null || v.trim().isEmpty) continue;
      final ProxyEndpoint? ep = parseSpec(v);
      if (ep != null) return ep;
    }
    return null;
  }

  /// 解析 `host:port` / `http://host:port` / `user:pass@host:port`。
  ///
  /// 返回 null 表示不能用（含 socks 协议、缺端口、端口越界）。
  static ProxyEndpoint? parseSpec(String? spec) {
    if (spec == null) return null;
    String s = spec.trim();
    if (s.isEmpty) return null;
    final String lower = s.toLowerCase();
    if (lower.startsWith('socks')) {
      _lastError = '不支持 SOCKS 代理，请填 HTTP 代理地址';
      return null;
    }
    if (lower.startsWith('http://')) {
      s = s.substring(7);
    } else if (lower.startsWith('https://')) {
      s = s.substring(8);
    }
    final int slash = s.indexOf('/');
    if (slash >= 0) s = s.substring(0, slash);
    final int at = s.lastIndexOf('@');
    if (at >= 0) s = s.substring(at + 1); // 去掉账号密码：dart:io 不支持带认证的代理
    final int colon = s.lastIndexOf(':');
    if (colon <= 0 || colon == s.length - 1) return null;
    final String host = s.substring(0, colon).trim();
    final int? port = int.tryParse(s.substring(colon + 1).trim());
    if (host.isEmpty || port == null || port <= 0 || port > 65535) return null;
    return ProxyEndpoint(host, port);
  }

  /// 一句话描述当前状态（设置页显示）。
  static String describe() {
    switch (_mode) {
      case ProxyMode.direct:
        return '直连';
      case ProxyMode.auto:
        return _auto == null ? '自动（未发现代理，按直连）' : '自动：${_auto!.label}';
      case ProxyMode.manual:
        return _manual == null ? '手动（地址无效）' : '手动：${_manual!.label}';
    }
  }

  /// 测试用：重置。
  static void reset() {
    _mode = ProxyMode.direct;
    _manual = null;
    _auto = null;
    _lastError = '';
  }
}
