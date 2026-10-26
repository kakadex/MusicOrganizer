/// 文件夹封面：专辑目录里放的 cover.jpg / folder.jpg 等。
///
/// 很多整专辑下载的曲库不给单首写封面，只在专辑目录里放一张图。
/// 曲库列表里没有自己封面的曲目就用它兜底。
library;

import 'dart:typed_data';

import '../fs/file_store.dart';
import '../model/vfile.dart';

/// 文件夹封面查找（按目录缓存，避免每行都去列目录）。
abstract final class FolderCover {
  /// 常见封面文件名（不含扩展名）。
  static const List<String> names = <String>[
    'cover', 'folder', 'album', 'front', 'albumart', '封面',
  ];

  /// 认得的图片扩展名（顺序即优先级：jpg 最常见，也最小）。
  static const List<String> exts = <String>['jpg', 'jpeg', 'png', 'webp'];

  /// 单张图最多读这么多字节（防止一张巨图吃内存）。
  static const int maxBytes = 4 * 1024 * 1024;

  /// 目录 docId → 封面字节（null 表示这个目录确实没有封面）。
  static final Map<String, Uint8List?> _cache = <String, Uint8List?>{};

  /// 目录内容变了（重扫 / 换目录）时调用，否则新放进来的 cover.jpg 要等重启才认。
  static void invalidate() => _cache.clear();

  /// 找某个目录的封面；没有返回 null。
  static Future<Uint8List?> find(FileStore st, VFile dir) async {
    final String key = dir.docId;
    if (_cache.containsKey(key)) return _cache[key];
    Uint8List? art;
    try {
      final List<VFile> kids = await st.children(dir);
      final Map<String, String> byName = <String, String>{};
      for (final VFile k in kids) {
        if (k.dir) continue;
        byName[k.name.toLowerCase()] = k.name;
      }
      for (final String base in names) {
        for (final String ext in exts) {
          final String? real = byName['$base.$ext'];
          if (real == null) continue;
          final VFile? file = await st.stat('${dir.docId}/$real');
          if (file == null) continue;
          final Uint8List bytes = await st.headBytes(file, maxBytes);
          art = bytes.isEmpty ? null : bytes;
          break;
        }
        if (art != null) break;
      }
    } catch (_) {
      art = null;
    }
    _cache[key] = art;
    return art;
  }
}
