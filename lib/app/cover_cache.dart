import 'dart:async';
import 'dart:typed_data';

import '../core/model/vfile.dart';
import '../core/tag/cover_art.dart';
import '../core/scan/scanner.dart';
import 'cover_thumb_cache.dart';
import 'repo.dart';

/// 封面内存缓存（列表滚动时不重复解压同一张图）。
///
/// 键带 size + lastModified：换封面 / 重打标签后自动失效，不用手动清。
/// 只缓存「有封面」的结果（缓存无封面会让用户补了目录封面后仍显示空白）。
class CoverCache {
  CoverCache._();

  static final CoverCache instance = CoverCache._();

  static const int _limit = 400;

  final Map<String, Uint8List> _bytes = <String, Uint8List>{};
  final Set<String> _miss = <String>{};
  final Set<String> _loading = <String>{};

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
        _bytes[key] = thumb;
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
      if (_bytes.length >= _limit) {
        // 只淘汰最早插入的一批（约 1/4），避免整表清空后快速回滚时全部重读造成卡顿。
        final List<String> old =
            _bytes.keys.take(_limit ~/ 4).toList(growable: false);
        for (final String k in old) {
          _bytes.remove(k);
        }
      }
      _bytes[key] = art;
      // 后台缩一张存盘：不 await，别让滚动等磁盘
      unawaited(CoverThumbCache.instance.save(f, art));
      return art;
    } catch (_) {
      _miss.add(key);
      return null;
    } finally {
      _loading.remove(key);
      _release();
    }
  }

  void clear() {
    _bytes.clear();
    _miss.clear();
    _loading.clear();
  }
}
