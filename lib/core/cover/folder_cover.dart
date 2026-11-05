/// 文件夹封面：专辑目录里放的 cover.jpg / folder.jpg 等。
///
/// 很多整专辑下载的曲库不给单首写封面，只在专辑目录里放一张图。
/// 曲库列表里没有自己封面的曲目就用它兜底。
library;

import 'dart:async';
import 'dart:typed_data';

import '../fs/file_store.dart';
import '../model/vfile.dart';
import 'cover_mem_cache.dart';
import 'cover_thumb_hook.dart';

/// 文件夹封面查找（按目录缓存，避免每行都去列目录）。
///
/// 缓存是有界的（条目数 + 字节，见 [CoverMemCache]）且会自动过期：整张专辑
/// 的曲库每个目录都可能有一张几 MB 的图，不限量的话内存会一路涨上去；
/// 只靠 [invalidate] 也不够 —— 用户在别处换了 cover.jpg 时不会有人来通知。
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
  static final CoverMemCache _cache = CoverMemCache();

  /// 目录内容变了（重扫 / 换目录）时调用，否则新放进来的 cover.jpg 要等重启才认。
  static void invalidate() => _cache.clear();

  /// 当前缓存占用（界面 / 测试看内存用）。
  static int get cachedBytes => _cache.bytes;

  /// 找某个目录的封面；没有返回 null。
  ///
  /// 0.2.87：先问磁盘小图缓存（[CoverThumbHook]，键是「这张封面图自己的
  /// docId+size+mtime」）。整专辑曲库每个目录都有一张几 MB 的图，旧版每次
  /// 都要列一遍目录再读 4MB 原图；现在命中小图（20–40KB）直接返回。
  /// 内存里也只存缩过的小图，24MB 预算能放几百张而不是 6 张。
  static Future<Uint8List?> find(FileStore st, VFile dir) async {
    final String key = dir.docId;
    if (_cache.contains(key)) return _cache.get(key);
    Uint8List? art;
    VFile? source;
    bool fromDisk = false;
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
          // 先问磁盘小图：上次缩好的直接用，省掉读 4MB 原图与解码
          final Uint8List? small = await CoverThumbHook.peek?.call(file);
          if (small != null) {
            art = small;
            fromDisk = true;
          } else {
            final Uint8List bytes = await st.headBytes(file, maxBytes);
            art = bytes.isEmpty ? null : bytes;
          }
          source = file;
          break;
        }
        if (art != null) break;
      }
    } catch (_) {
      art = null;
    }
    if (art != null && source != null && !fromDisk) {
      // 原图才需要缩一次（内存只存小图）并落盘（后台，不 await）
      unawaited(CoverThumbHook.save?.call(source, art));
      final Uint8List? small = await CoverThumbHook.shrink?.call(art);
      if (small != null) art = small;
    }
    _cache.put(key, art);
    return art;
  }
}
