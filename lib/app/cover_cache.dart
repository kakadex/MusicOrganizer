import 'dart:typed_data';

import '../core/model/vfile.dart';
import '../core/scan/scanner.dart';
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

  static String keyOf(VFile f) => '${f.docId}|${f.size}|${f.lastModified}';

  /// 已缓存的字节（没有返回 null，不代表「一定没有封面」）。
  Uint8List? peek(VFile f) => _bytes[keyOf(f)];

  /// 已经确认没有封面（避免每次滚动都重读）。
  bool knownMiss(VFile f) => _miss.contains(keyOf(f));

  /// 读一次封面；并发调用同一首只发一次请求。
  Future<Uint8List?> load(VFile f) async {
    final String key = keyOf(f);
    final Uint8List? hit = _bytes[key];
    if (hit != null) return hit;
    if (_miss.contains(key)) return null;
    if (_loading.contains(key)) return null;
    _loading.add(key);
    try {
      final store = Repo.instance.store;
      if (store == null) return null;
      final Uint8List? art = await Scanner.readCover(store, f);
      if (art == null || art.isEmpty) {
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
      return art;
    } catch (_) {
      _miss.add(key);
      return null;
    } finally {
      _loading.remove(key);
    }
  }

  void clear() {
    _bytes.clear();
    _miss.clear();
    _loading.clear();
  }
}
