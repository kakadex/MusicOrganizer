/// 同名图片封面：曲目旁边放一张同名图片当封面。
///
/// 很多从网上整包下的曲库不给单首写内嵌封面，只在音频旁边放一张
/// `歌名.jpg`（与 `歌名.mp3` 同名）。认得它，曲库列表才有封面。
library;

import 'dart:typed_data';

import '../fs/file_store.dart';
import '../model/vfile.dart';
import 'cover_mem_cache.dart';

/// 同名图片封面查找（按文件缓存，同样走有界 + 过期，见 [CoverMemCache]）。
abstract final class SidecarCover {
  /// 认得的图片扩展名（顺序即优先级：jpg 最常见，也最小）。
  static const List<String> exts = <String>['jpg', 'jpeg', 'png', 'webp'];

  /// 单张图最多读这么多字节（防止一张巨图吃内存）。
  static const int maxBytes = 4 * 1024 * 1024;

  /// 文件 docId → 图片字节（null 表示确实没有）。
  static final CoverMemCache _cache = CoverMemCache();

  /// 曲库重扫后清缓存（否则新放进来的图片要等重启才认）。
  static void invalidate() => _cache.clear();

  /// 当前缓存占用（界面 / 测试看内存用）。
  static int get cachedBytes => _cache.bytes;

  /// 找某个音频旁边的同名图片；没有返回 null。
  static Future<Uint8List?> find(FileStore st, VFile audio) async {
    final String key = audio.docId;
    if (_cache.contains(key)) return _cache.get(key);
    Uint8List? art;
    try {
      final String? parentId = audio.parentId;
      if (parentId != null && parentId.isNotEmpty) {
        final String stem = audio.stem();
        for (final String ext in exts) {
          final VFile? file = await st.stat('$parentId/$stem.$ext');
          if (file == null) continue;
          final Uint8List bytes = await st.headBytes(file, maxBytes);
          if (bytes.isNotEmpty) {
            art = bytes;
            break;
          }
        }
      }
    } catch (_) {
      art = null;
    }
    _cache.put(key, art);
    return art;
  }
}
