import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/model/vfile.dart';
import '../core/tag/cover_art.dart';
import '../core/scan/scanner.dart';
import 'cover_thumb_cache.dart';
import 'repo.dart';

/// 封面内存缓存（列表滚动时不重复解压同一张图）。
///
/// 键带 size + lastModified：换封面 / 重打标签后自动失效，不用手动清。
/// 只缓存「有封面」的结果（缓存无封面会让用户补了目录封面后仍显示空白）。
///
/// **容量是「条数 + 字节」双上限**（0.2.61）：原来只有 400 条上限，而存的是
/// `Scanner.readCover()` 返回的**原始图**（单张最大 [CoverReader.maxBytes] = 12MB）。
/// 400 条 × 平均几百 KB 就是上百 MB，足够触发频繁 GC（在 Flutter 里表现为
/// 滚动一顿一顿），极端情况直接 OOM。现在同时限制字节数，并在入缓存前先
/// 缩到显示尺寸，让「条数」和「字节」两个维度都可控。
class CoverCache {
  CoverCache._();

  static final CoverCache instance = CoverCache._();

  /// 条目上限。
  ///
  /// 0.2.88：400 → 4000。原来的 400 条在 900 首的曲库上不够用：缩略图单张
  /// 只有 20–40KB，真正该卡住的是**字节**（24MB），条数却先到了上限，导致
  /// 滚过 400 首以后前面的被淘汰、回滚就要重读——用户感知就是「每次下翻到
  /// 新部分都要重新加载封面」。4000 条足够覆盖普通曲库，内存仍由字节上限管。
  static const int _limit = 4000;

  /// 字节上限：与 [CoverMemCache.defaultMaxBytes] 保持一致（24MB）。
  ///
  /// 入缓存前已经缩到 [CoverThumbCache.maxWidth] 宽，单张约 20–40KB，
  /// 400 条实际远小于这个预算；这个上限是给「缩图失败、退化成原图」
  /// 这种情况兜底的，保证最坏情况下也不会失控。
  static const int _maxBytes = 24 * 1024 * 1024;

  final Map<String, Uint8List> _bytes = <String, Uint8List>{};
  final Set<String> _miss = <String>{};
  final Set<String> _loading = <String>{};

  /// 当前已占用的估算字节数（与 [_bytes] 同步维护）。
  int _bytesUsed = 0;

  /// 当前占用字节数（测试与排查用）。
  @visibleForTesting
  int get bytesUsed => _bytesUsed;

  /// 当前缓存条数（测试与排查用）。
  @visibleForTesting
  int get entryCount => _bytes.length;

  /// 同时在读的封面数上限：一次滚动会瞬间冒出一屏新行，全放过去会把
  /// 平台通道和主 isolate 挤满，表现就是「快速下滑一顿一顿」。
  static const int maxConcurrent = 4;
  int _inFlight = 0;
  final List<Completer<void>> _waiters = <Completer<void>>[];

  Future<void> _acquire() async {
    if (_inFlight < maxConcurrent) {
      _inFlight++;
      return;
    }
    final Completer<void> c = Completer<void>();
    _waiters.add(c);
    await c.future;
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      // 名额直接转交给排队者，_inFlight 不变
      _waiters.removeAt(0).complete();
      return;
    }
    _inFlight--;
  }

  static String keyOf(VFile f) => '${f.docId}|${f.size}|${f.lastModified}';

  /// 已缓存的字节（没有返回 null，不代表「一定没有封面」）。
  Uint8List? peek(VFile f) => _bytes[keyOf(f)];

  /// 已经确认没有封面（避免每次滚动都重读）。
  bool knownMiss(VFile f) => _miss.contains(keyOf(f));

  /// 读一次封面；并发调用同一首只发一次请求。
  ///
  /// 0.2.59 起的顺序：内存 → **磁盘缩略图** → 读文件头解析原图。
  /// 磁盘小图是上一次启动时缩好存下的（约 20–40KB），命中就不必再读
  /// 0.5–2MB 文件头，也不必解码大图。
  Future<Uint8List?> load(VFile f) async {
    final String key = keyOf(f);
    final Uint8List? hit = _bytes[key];
    if (hit != null) return hit;
    if (_miss.contains(key)) return null;
    if (_loading.contains(key)) return null;
    _loading.add(key);
    await _acquire();
    try {
      final store = Repo.instance.store;
      if (store == null) return null;
      // 磁盘缩略图：小图直接可用；读失败就当没有（不能因为缓存读错让列表空着）
      final Uint8List? thumb = await CoverThumbCache.instance.peek(f);
      if (thumb != null) {
        _put(key, thumb);
        return thumb;
      }
      final Uint8List? art = await Scanner.readCover(store, f);
      if (art == null || art.isEmpty) {
        _miss.add(key);
        return null;
      }
      // 不是 JPEG/PNG/WebP 的字节直接当「没有封面」：
      // 与其让 Image 解码时报错，不如显示音符占位
      if (!CoverArt.isImage(art)) {
        _miss.add(key);
        return null;
      }
      // 后台缩一张存盘：不 await，别让滚动等磁盘
      unawaited(CoverThumbCache.instance.save(f, art));
      // 入内存前先缩到显示尺寸。
      //
      // 原图常见 500–1000px、几百 KB 到几 MB；列表格子只有 46dp，存原图纯属
      // 白占内存。这里复用落盘用的同一个编码器（只有 Image.memory 的
      // cacheWidth 走不到「缩完再存」这一步，所以必须在入缓存前缩）。
      // 缩图失败（格式怪、解码不了）就退化成存原图，行为与旧版一致。
      Uint8List? small;
      try {
        small = await CoverThumbCache.instance.encodeSmall(art);
      } catch (_) {
        small = null;
      }
      _put(key, small ?? art);
      return small ?? art;
    } catch (_) {
      _miss.add(key);
      return null;
    } finally {
      _loading.remove(key);
      _release();
    }
  }

  /// 写入内存缓存（旁挂封面等外部来源也走这里，保证「一套内存缓存」）。
  ///
  /// 传进来的应当已经是缩过的小图；原图请先走
  /// [CoverThumbCache.encodeSmall]，否则 24MB 预算会被几张图吃满。
  void put(VFile f, Uint8List bytes) => _put(keyOf(f), bytes);

  /// 写入内存缓存并按「条数 + 字节」双上限淘汰。
  void _put(String key, Uint8List bytes) {
    final Uint8List? old = _bytes.remove(key);
    if (old != null) _bytesUsed -= old.lengthInBytes;
    _bytes[key] = bytes;
    _bytesUsed += bytes.lengthInBytes;
    if (_bytesUsed < 0) _bytesUsed = 0;
    _trim();
  }

  /// 单测用：直接往缓存里塞字节，绕开真实读盘与解码，专测容量账本与淘汰。
  @visibleForTesting
  void debugPut(String key, Uint8List bytes) => _put(key, bytes);

  /// 单测用：读回某条缓存（不触发加载）。
  @visibleForTesting
  Uint8List? debugGet(String key) => _bytes[key];

  /// 超条数或超字节时，按「最早插入」淘汰一批（约 1/4），避免整表清空后
  /// 快速回滚时全部重读造成卡顿。
  void _trim() {
    while (_bytes.isNotEmpty &&
        (_bytes.length > _limit || _bytesUsed > _maxBytes)) {
      final int dropCount = (_bytes.length ~/ 4).clamp(1, _bytes.length);
      final List<String> old = _bytes.keys.take(dropCount).toList(growable: false);
      for (final String k in old) {
        final Uint8List? v = _bytes.remove(k);
        if (v != null) _bytesUsed -= v.lengthInBytes;
      }
    }
    if (_bytesUsed < 0) _bytesUsed = 0;
  }

  void clear() {
    _bytes.clear();
    _miss.clear();
    _loading.clear();
    _bytesUsed = 0;
  }
}
