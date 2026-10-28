/// 并发闸门与有界缓存（纯 Dart，不引第三方依赖）。
///
/// 为什么需要它：`Scanner.readTags` 之类的接口会被批量任务、封面预览、
/// 编辑器同时调用，调用方各按自己的并发跑，叠加起来就是几十个文件同时读，
/// 在手机上直接顶到内存峰值。闸门放在**被调用方**，任何入口都不会失控。
library;

import 'dart:async';
import 'dart:collection';

/// 并发闸门：最多同时执行 [limit] 个异步操作，其余排队。
class ConcurrencyGate {
  ConcurrencyGate(this.limit) : assert(limit > 0, 'limit 必须大于 0');

  /// 同时执行上限。
  final int limit;

  int _active = 0;
  final Queue<Completer<void>> _waiting = Queue<Completer<void>>();

  /// 当前正在执行的数量（仅用于诊断/测试）。
  int get active => _active;

  /// 排队等待的数量（仅用于诊断/测试）。
  int get waiting => _waiting.length;

  /// 在闸门内执行 [action]；无论成功失败都会释放名额。
  Future<T> run<T>(Future<T> Function() action) async {
    await _acquire();
    try {
      return await action();
    } finally {
      _release();
    }
  }

  Future<void> _acquire() {
    if (_active < limit) {
      _active++;
      return Future<void>.value();
    }
    final Completer<void> c = Completer<void>();
    _waiting.add(c);
    return c.future;
  }

  void _release() {
    if (_waiting.isNotEmpty) {
      // 名额直接转交给队首，不先自减再自增（否则会出现瞬时超限）
      _waiting.removeFirst().complete();
      return;
    }
    _active--;
  }
}

/// 估算一段标签文本占多少内存（UTF-16 + 少量对象开销）。
///
/// 只要相对量级对得上就够用 —— 目的是「别让歌词缓存悄悄吃掉几十 MB」，
/// 不需要精确到字节。
int estimateTagsBytes(Map<String, String> values) {
  int total = 0;
  for (final MapEntry<String, String> e in values.entries) {
    total += (e.key.length + e.value.length) * 2;
    total += 48; // 每个条目的对象头 / 指针开销
  }
  return total;
}

/// 有界缓存：按「条目数 + 估算字节数」双上限淘汰，淘汰顺序是插入顺序（FIFO）。
///
/// 刻意不做 LRU 重排：曲库扫描是顺序访问，重排的收益小于它的复杂度；
/// 真正要保的是**内存有天花板**。
class BoundedMap<K, V> {
  BoundedMap({
    required this.maxEntries,
    required this.maxBytes,
    required this.sizeOf,
  });

  final int maxEntries;
  final int maxBytes;
  final int Function(V value) sizeOf;

  final LinkedHashMap<K, V> _map = LinkedHashMap<K, V>();
  int _bytes = 0;

  int get length => _map.length;

  /// 当前估算占用字节数。
  int get bytes => _bytes;

  V? operator [](K key) => _map[key];

  void clear() {
    _map.clear();
    _bytes = 0;
  }

  /// 删除键满足条件的条目（写盘后按前缀失效缓存用）。
  void removeWhere(bool Function(K key, V value) test) {
    final List<K> drop = <K>[];
    for (final MapEntry<K, V> e in _map.entries) {
      if (test(e.key, e.value)) drop.add(e.key);
    }
    for (final K k in drop) {
      final V? v = _map.remove(k);
      if (v != null) _bytes -= sizeOf(v);
    }
    if (_bytes < 0) _bytes = 0;
  }

  void put(K key, V value) {
    final V? old = _map.remove(key);
    if (old != null) _bytes -= sizeOf(old);
    _map[key] = value;
    _bytes += sizeOf(value);
    _trim();
  }

  void _trim() {
    while (_map.isNotEmpty &&
        (_map.length > maxEntries || _bytes > maxBytes)) {
      final MapEntry<K, V> first = _map.entries.first;
      _bytes -= sizeOf(first.value);
      _map.remove(first.key);
    }
    if (_bytes < 0) _bytes = 0;
  }
}
