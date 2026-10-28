/// 封面字节的进程内缓存：有界 + 自动过期。
///
/// 目录封面 / 同名 sidecar 封面都是「一张图几 MB、查一次要列一次目录」，不缓存
/// 曲库列表会卡；但无限缓存会把内存吃穿（一张 4MB 的图 × 几千个目录）。
/// 所以这里给两个天花板：**条目数** 与 **估算字节**，先到的先走（FIFO）。
///
/// 另外给一个存活时间（默认 5 分钟）：目录里的 cover.jpg 被替换后，就算没人
/// 调 invalidate()，缓存也会自己过期 —— 这就是「自动失效」。
/// 空结果（这个目录确实没有封面）也缓存，所以必须能区分「缓存了 null」和
/// 「没查过」，`contains` 就是为此存在的。
library;

import 'dart:collection';
import 'dart:typed_data';

/// 一张封面的缓存条目。
class CoverCacheEntry {
  CoverCacheEntry(this.bytes, this.at);

  /// 封面字节；null 表示「查过了，确实没有」。
  final Uint8List? bytes;

  /// 写入时刻（毫秒）。
  final int at;

  int sizeOf() => (bytes?.lengthInBytes ?? 0) + 64;
}

/// 有界 + 带 TTL 的封面缓存（不是线程安全的，只在 UI 主线程里用）。
class CoverMemCache {
  CoverMemCache({
    this.maxEntries = defaultMaxEntries,
    this.maxBytes = defaultMaxBytes,
    this.ttlMs = defaultTtlMs,
  });

  final int maxEntries;
  final int maxBytes;
  final int ttlMs;
  final LinkedHashMap<String, CoverCacheEntry> _map =
      LinkedHashMap<String, CoverCacheEntry>();
  int _bytes = 0;

  /// 默认上限：300 条 / 24MB（约 6 张 4MB 大图，或几百张缩略图）。
  static const int defaultMaxEntries = 300;
  static const int defaultMaxBytes = 24 * 1024 * 1024;

  /// 默认存活 5 分钟。
  static const int defaultTtlMs = 5 * 60 * 1000;

  int get length => _map.length;

  /// 当前估算占用字节数。
  int get bytes => _bytes;

  /// 有没有这条缓存（含「查过但没有封面」）；过期的算没有。
  bool contains(String key) {
    final CoverCacheEntry? e = _map[key];
    if (e == null) return false;
    if (_expired(e, _now())) {
      _remove(key, e);
      return false;
    }
    return true;
  }

  /// 取缓存；没有（或已过期）返回 null —— 注意与「缓存了 null」区分，
  /// 判断有没有查过请用 [contains]。
  Uint8List? get(String key) {
    final CoverCacheEntry? e = _map[key];
    if (e == null) return null;
    if (_expired(e, _now())) {
      _remove(key, e);
      return null;
    }
    return e.bytes;
  }

  void put(String key, Uint8List? bytes) {
    final CoverCacheEntry? old = _map.remove(key);
    if (old != null) _bytes -= old.sizeOf();
    final CoverCacheEntry e = CoverCacheEntry(bytes, _now());
    _map[key] = e;
    _bytes += e.sizeOf();
    _trim();
  }

  /// 丢掉过期条目（曲库刷新后调一次即可，不调也会在读写时惰性淘汰）。
  int dropExpired() {
    final int now = _now();
    final List<String> drop = <String>[];
    for (final MapEntry<String, CoverCacheEntry> e in _map.entries) {
      if (_expired(e.value, now)) drop.add(e.key);
    }
    for (final String k in drop) {
      _remove(k, _map[k]);
    }
    return drop.length;
  }

  void clear() {
    _map.clear();
    _bytes = 0;
  }

  bool _expired(CoverCacheEntry e, int now) =>
      ttlMs > 0 && now - e.at > ttlMs;

  void _remove(String key, CoverCacheEntry? e) {
    if (e == null) return;
    _bytes -= e.sizeOf();
    _map.remove(key);
    if (_bytes < 0) _bytes = 0;
  }

  void _trim() {
    while (_map.isNotEmpty &&
        (_map.length > maxEntries || _bytes > maxBytes)) {
      final MapEntry<String, CoverCacheEntry> first = _map.entries.first;
      _remove(first.key, first.value);
    }
    if (_bytes < 0) _bytes = 0;
  }

  static int _now() => DateTime.now().millisecondsSinceEpoch;
}
