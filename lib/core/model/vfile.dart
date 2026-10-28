/// SAF 文档抽象。
///
/// 身份字段不可变（[copyWith] 生成新实例）；标签 / 封面 / 时长缓存可变
/// （[cacheMeta] / [clearMeta]）。
library;

import 'tags.dart';

class VFile {
  /// 音频扩展名（小写，含点）。
  static const Set<String> audioExts = <String>{
    '.mp3', '.flac', '.m4a', '.wav', '.ogg', '.aac', '.wma', '.ape',
    '.opus', '.wv', '.mpc', '.dsf',
  };

  /// 歌词扩展名。
  static const Set<String> lyricExts = <String>{
    '.lrc', '.krc', '.qrc', '.trc', '.srt',
  };

  /// 音频 + 歌词。
  static final Set<String> musicExts = <String>{...audioExts, ...lyricExts};

  /// 唯一标识（如 `primary:Music/a.mp3`）。
  final String docId;

  /// 父目录 docId；根目录为 null。
  final String? parentId;

  /// 显示名（含扩展名）。
  final String name;

  final String mime;
  final int size;
  final int lastModified;
  final bool dir;

  /// 上次读到的标签；null 表示还没读过（缓存为空也算「读过」）。
  Tags? cachedTags;

  /// 上次判定「有内嵌封面」。
  bool cachedHasCover = false;

  /// 上次判定「有歌词」。
  bool cachedHasLyrics = false;

  /// 歌词太长、没随缓存落盘（正文要现读，但**不算缺歌词**）。
  ///
  /// 没有这个标记的话，缓存恢复回来的条目有 [cachedHasLyrics] 却没有歌词正文，
  /// 体检 / 批量补歌词会把它当成「缺歌词的歌」——于是每次冷启动都重读一遍、
  /// 还要联网补一次，而它其实一直有歌词，只是太大没进缓存而已。
  bool cachedLyricsOversize = false;

  /// 上次读到的时长（毫秒）/ 码率（kbps）。
  int cachedDurationMs = 0;
  int cachedBitrateKbps = 0;

  VFile({
    required this.docId,
    this.parentId,
    required String name,
    String? mime,
    this.size = 0,
    this.lastModified = 0,
    this.dir = false,
  })  : name = name.isEmpty ? '' : name,
        mime = mime ?? '';

  /// 小写扩展名（含点）；无扩展名返回 ""。
  String ext() {
    final int dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot).toLowerCase();
  }

  /// 去扩展名的基本名。
  String stem() {
    final int dot = name.lastIndexOf('.');
    return dot <= 0 ? name : name.substring(0, dot);
  }

  bool audio() => !dir && audioExts.contains(ext());
  bool lyric() => !dir && lyricExts.contains(ext());
  bool music() => !dir && musicExts.contains(ext());
  bool isHidden() => name.startsWith('.');
  bool metaCached() => cachedTags != null;

  /// 写入缓存（读盘成功后调用）。存副本。
  void cacheMeta(Tags? tags,
      {bool cover = false,
      bool lyrics = false,
      bool lyricsOversize = false,
      int durationMs = 0,
      int bitrateKbps = 0}) {
    cachedTags = tags == null ? Tags() : tags.copy();
    cachedHasCover = cover;
    cachedHasLyrics = lyrics;
    cachedLyricsOversize = lyricsOversize;
    cachedDurationMs = durationMs;
    cachedBitrateKbps = bitrateKbps;
  }

  /// 丢掉缓存（标签写入 / 外部改动之后必须调用）。
  void clearMeta() {
    cachedTags = null;
    cachedHasCover = false;
    cachedHasLyrics = false;
    cachedLyricsOversize = false;
    cachedDurationMs = 0;
    cachedBitrateKbps = 0;
  }

  /// 相对根 docId 的路径片段（不含根目录名），用 / 分隔。
  String relativePath(String rootDocId) {
    final String prefix =
        rootDocId.endsWith('/') ? rootDocId : '$rootDocId/';
    if (docId.length > prefix.length && docId.startsWith(prefix)) {
      return docId.substring(prefix.length);
    }
    return name;
  }

  String pathAfterRoot() {
    final int idx = docId.indexOf(':');
    return idx >= 0 ? docId.substring(idx + 1) : docId;
  }

  /// 身份字段变更生成新实例（缓存字段原样携带）。
  VFile copyWith({
    String? docId,
    String? parentId,
    String? name,
    String? mime,
    int? size,
    int? lastModified,
    bool? dir,
  }) {
    final VFile v = VFile(
      docId: docId ?? this.docId,
      parentId: parentId ?? this.parentId,
      name: name ?? this.name,
      mime: mime ?? this.mime,
      size: size ?? this.size,
      lastModified: lastModified ?? this.lastModified,
      dir: dir ?? this.dir,
    );
    v.cachedTags = cachedTags;
    v.cachedHasCover = cachedHasCover;
    v.cachedHasLyrics = cachedHasLyrics;
    v.cachedLyricsOversize = cachedLyricsOversize;
    v.cachedDurationMs = cachedDurationMs;
    v.cachedBitrateKbps = cachedBitrateKbps;
    return v;
  }

  @override
  String toString() => name;
}
