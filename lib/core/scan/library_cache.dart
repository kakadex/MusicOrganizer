/// 曲库索引缓存的编解码（纯 Dart，不涉及文件 IO）。
///
/// 进程退掉之后，内存里的文件列表和「读过的标签」全没了，下次启动只能重新
/// 递归整棵目录树、再逐首读一遍标签；曲库一大，用户每次开应用都要等这一轮。
/// 这里把上次扫到的音频条目连同读过的标签编成一份 JSON，由 app 层落盘 / 读回：
/// 启动时先拿它把列表撑起来（秒开），后台再增量扫描补差。
///
/// 只缓存音频文件：界面列表、搜索索引、查重都只认音频，目录树每次重扫成本很低。
library;

import '../model/tags.dart';
import '../model/vfile.dart';

/// 曲库索引缓存。
abstract final class LibraryCache {
  /// 缓存格式版本。结构一变就整体弃用，自动退回全量扫描，不做兼容读写。
  static const int version = 1;

  /// 单条目歌词上限：超过就不落盘，免得几 MB 的歌词把缓存文件撑大。
  static const int maxLyricsChars = 16 * 1024;

  /// 编码：[key] 是根目录 docId，值是该目录下的音频条目。
  static Map<String, Object?> encode(Map<String, List<VFile>> byRoot) {
    final Map<String, Object?> roots = <String, Object?>{};
    byRoot.forEach((String rootId, List<VFile> list) {
      roots[rootId] = <Object?>[
        for (final VFile f in list)
          if (_cacheable(f)) _encodeFile(f),
      ];
    });
    return <String, Object?>{'v': version, 'roots': roots};
  }

  /// 解码；版本不符或结构异常返回空表（调用方按「没有缓存」处理）。
  static Map<String, List<VFile>> decode(Object? raw) {
    final Map<String, List<VFile>> out = <String, List<VFile>>{};
    if (raw is! Map) return out;
    final Object? v = raw['v'];
    if (v is! int || v != version) return out;
    final Object? roots = raw['roots'];
    if (roots is! Map) return out;
    roots.forEach((Object? key, Object? value) {
      if (key is! String || key.isEmpty) return;
      if (value is! List) return;
      final List<VFile> list = <VFile>[];
      final Set<String> seen = <String>{};
      for (final Object? item in value) {
        final VFile? f = _decodeFile(item);
        // 坏条目只跳过它自己：缓存是拿来加速的，坏一条就整组丢掉，
        // 等于让用户白等一次全量扫描
        if (f == null) continue;
        if (seen.add(f.docId)) list.add(f);
      }
      if (list.isNotEmpty) out[key] = list;
    });
    return out;
  }

  /// 只要音频、且身份字段齐全的条目。
  static bool _cacheable(VFile f) =>
      !f.dir && f.audio() && f.docId.isNotEmpty && f.name.isNotEmpty;

  static Map<String, Object?> _encodeFile(VFile f) {
    final Map<String, Object?> out = <String, Object?>{
      'd': f.docId,
      'n': f.name,
      's': f.size,
      't': f.lastModified,
    };
    final String? parent = f.parentId;
    if (parent != null && parent.isNotEmpty) out['p'] = parent;
    if (f.mime.isNotEmpty) out['m'] = f.mime;
    final Tags? tags = f.cachedTags;
    if (tags != null) {
      final Map<String, String> m = tags.toMap();
      final String? lyric = m[Tags.lyrics];
      if (lyric != null && lyric.length > maxLyricsChars) {
        m.remove(Tags.lyrics);
      }
      if (m.isNotEmpty) out['g'] = m;
      if (f.cachedHasCover) out['c'] = 1;
      if (f.cachedHasLyrics) out['l'] = 1;
      if (f.cachedDurationMs > 0) out['u'] = f.cachedDurationMs;
      if (f.cachedBitrateKbps > 0) out['b'] = f.cachedBitrateKbps;
    }
    return out;
  }

  static VFile? _decodeFile(Object? raw) {
    if (raw is! Map) return null;
    final Object? docId = raw['d'];
    final Object? name = raw['n'];
    if (docId is! String || docId.isEmpty) return null;
    if (name is! String || name.isEmpty) return null;
    final Object? size = raw['s'];
    final Object? mtime = raw['t'];
    final Object? parent = raw['p'];
    final Object? mime = raw['m'];
    final VFile f = VFile(
      docId: docId,
      name: name,
      parentId: parent is String ? parent : null,
      mime: mime is String ? mime : '',
      size: size is int ? size : 0,
      lastModified: mtime is int ? mtime : 0,
      dir: false,
    );
    final Object? tags = raw['g'];
    if (tags is Map) {
      final Tags t = Tags();
      tags.forEach((Object? k, Object? v) {
        if (k is String && v is String) t.put(k, v);
      });
      final Object? cover = raw['c'];
      final Object? lyric = raw['l'];
      final Object? dur = raw['u'];
      final Object? br = raw['b'];
      f.cacheMeta(
        t,
        cover: cover == 1,
        lyrics: lyric == 1,
        durationMs: dur is int ? dur : 0,
        bitrateKbps: br is int ? br : 0,
      );
    }
    return f;
  }
}
