import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/model/vfile.dart';
import '../core/tag/cover_art.dart';
import '../core/scan/scanner.dart';
import 'cover_pack_store.dart';
import 'cover_thumb_cache.dart';
import '../core/log/log.dart';
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
  ///
  /// 0.2.93：内存没有时也查一下打包存储——那也是纯内存表，同步可返回，
  /// 列表行重建时能一帧出图（不需要 setState 等异步）。
  Uint8List? peek(VFile f) {
    final Uint8List? mem = _bytes[keyOf(f)];
    if (mem != null) return mem;
    final Uint8List? packed = CoverPackStore.instance.peekOf(f);
    if (packed != null) {
      _put(keyOf(f), packed);
      return packed;
    }
    return null;
  }

  /// 已经确认没有封面（避免每次滚动都重读）。
  bool knownMiss(VFile f) => _miss.contains(keyOf(f));

  /// 读一次封面；并发调用同一首只发一次请求。
  ///
  /// 0.2.59 起的顺序：内存 → **磁盘缩略图** → 读文件头解析原图。
  /// 磁盘小图是上一次启动时缩好存下的（约 20–40KB），命中就不必再读
  /// 0.5–2MB 文件头，也不必解码大图。
  ///
  /// [allowExpensive]（0.2.90）：**滚动中传 false**。快速滑动时一屏接一屏
  /// 冒出新行，如果每行都去读 256KB 文件头，4 个并发名额会全被「滑过就销毁」
  /// 的行占满，真正停下来看的行反而排队——表现就是快速滑动一片空白。
  /// 传 false 时只走便宜路径（内存 + 磁盘小图），磁盘没有就返回 null 保持
  /// 占位，滑停后再由调用方用 true 补。
  /// 诊断计数（0.2.95 探针）：看每次取封面到底走了哪条路。
  ///
  /// 真机排查用：pack 命中 = 打包存储生效；file = 现场读音频文件（慢）；
  /// miss = 压根没封面。每 50 次汇总记一条日志，不刷屏。
  int _diagPack = 0;
  int _diagThumb = 0;
  int _diagFile = 0;
  int _diagMiss = 0;
  int _diagTotal = 0;

  void _diag(String path) {
    _diagTotal++;
    switch (path) {
      case 'pack':
        _diagPack++;
      case 'thumb':
        _diagThumb++;
      case 'file':
        _diagFile++;
      default:
        _diagMiss++;
    }
    if (_diagTotal % 50 == 0) {
      Log.info('[CoverDiag] 累计 $_diagTotal 次：pack=$_diagPack '
          'thumb=$_diagThumb file=$_diagFile miss=$_diagMiss');
    }
  }

  Future<Uint8List?> load(VFile f, {bool allowExpensive = true}) async {
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
      // ① 打包存储（0.2.93）：**纯内存读取，零 IO**。
      //    所有缩略图启动时一次性读进内存，这里只是查表——这是「滚动不加载」
      //    的关键。旧版每张都要读一个文件，安卓上就是一次跨进程调用。
      final Uint8List? packed = CoverPackStore.instance.peekOf(f);
      if (packed != null) {
        _put(key, packed);
        _diag('pack');
        return packed;
      }
      // ② 旧的「一歌一文件」缓存：兼容升级前已生成的缩略图，不浪费。
      final Uint8List? thumb = await CoverThumbCache.instance.peek(f);
      if (thumb != null) {
        _put(key, thumb);
        // 顺手并入打包存储，下次启动就是纯内存命中
        CoverPackStore.instance.put(f, thumb);
        _diag('thumb');
        return thumb;
      }
      // 滚动中到此为止：不读文件头，避免把并发名额烧在滑动路过的行上
      if (!allowExpensive) return null;
      final Uint8List? art = await Scanner.readCover(store, f);
      if (art == null || art.isEmpty) {
        _miss.add(key);
        _diag('miss');
        return null;
      }
      // 不是 JPEG/PNG/WebP 的字节直接当「没有封面」：
      // 与其让 Image 解码时报错，不如显示音符占位
      if (!CoverArt.isImage(art)) {
        _miss.add(key);
        _diag('miss');
        return null;
      }
      _diag('file');
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
      // 0.2.95：**把刚读出来的原图也写进打包存储**。
      // 旧版只有「后台补图」那条路会写 pack，列表现读的结果只进了内存——
      // 于是每次重启打包文件几乎是空的，又得重新慢滑一遍。
      final Uint8List? packedSmall = small;
      if (packedSmall != null) {
        CoverPackStore.instance.put(f, packedSmall);
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

  /// 把一张**原图**缩好再塞进内存缓存（0.2.92）。
  ///
  /// 扫描读标签时封面字节本来就在手上，趁热缩好存起来，列表就不必再读盘。
  /// 缩图失败就退回原图（与旧行为一致）。
  Future<void> seed(VFile f, Uint8List original) async {
    if (original.isEmpty) return;
    Uint8List? small;
    try {
      small = await CoverThumbCache.instance.encodeSmall(original);
    } catch (_) {
      small = null;
    }
    put(f, small ?? original);
  }

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
