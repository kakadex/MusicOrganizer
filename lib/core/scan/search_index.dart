/// 曲库内存搜索索引（纯逻辑，可离线单测）。
///
/// 为什么不用 SQLite FTS：规模是几千到几万首，内存索引冷构建 100ms 级、
/// 每次查询毫秒级，还省掉建库与迁移；歌词只存前若干行（见 [SearchIndex.lyricsHead]），
/// 内存占用可控。
///
/// 字段在 [Entry.renormalize] 里预先归一（繁转简 + 去标点 + 小写），
/// 查询时只做 `contains`，避免每次按键重复做重活。
library;

import '../model/tags.dart';
import '../model/vfile.dart';
import 'search_query.dart';

/// 索引条目：既是搜索单元，也是列表行的数据源。
class Entry {
  Entry({
    required this.docId,
    required this.name,
    required this.relPath,
    this.size = 0,
    this.modified = 0,
    this.file,
  }) {
    _nExt = ext();
    renormalize();
  }

  final String docId;
  final String name;
  final String relPath;
  final int size;
  final int modified;

  /// 音频文件对象；纯测试时可传 null。
  final VFile? file;

  String title = '';
  String artist = '';
  String albumArtist = '';
  String album = '';
  String genre = '';
  String comment = '';
  String year = '';

  /// 歌词（同名 .lrc 或标签里的歌词），只保留前 [SearchIndex.lyricsHead] 字符。
  String lyrics = '';

  /// 有没有内嵌封面（未知时 false，读了 meta 才准确）。
  bool hasCover = false;

  /// 时长（毫秒）；0 = 还没读到或取不到。
  int durationMs = 0;

  /// 码率（kbps）；0 = 还没读到或取不到。
  int bitrateKbps = 0;

  /// 有没有歌词（同名 .lrc 或标签内嵌）。
  bool hasLyrics = false;

  /// 标签是否已读过（决定要不要显示「—」与是否参与标签搜索）。
  bool metaLoaded = false;

  late String _nName;
  late String _nPath;
  late String _nTitle;
  late String _nArtist;
  late String _nAlbumArtist;
  late String _nAlbum;
  late String _nGenre;
  late String _nComment;
  late String _nLyrics;
  late String _nYear;
  late String _nExt;

  /// 小写扩展名（不含点）。
  String ext() {
    final int dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  }

  /// 标题：优先标签，其次文件名（去扩展名）。
  String displayTitle() {
    if (title.trim().isNotEmpty) return title.trim();
    final int dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// 副标题：艺人 · 专辑，缺失时给空串（界面显示「—」）。
  String displaySub() {
    final StringBuffer sb = StringBuffer();
    if (artist.trim().isNotEmpty) sb.write(artist.trim());
    if (album.trim().isNotEmpty) {
      if (sb.isNotEmpty) sb.write(' · ');
      sb.write(album.trim());
    }
    return sb.toString();
  }

  /// 标签是否齐（标题 + 艺人 + 专辑都有）。
  bool tagComplete() =>
      displayTitle().isNotEmpty && artist.trim().isNotEmpty && album.trim().isNotEmpty;

  void applyTags(Tags? tags, bool cover) {
    if (tags != null) {
      title = tags.get('title');
      artist = tags.get('artist');
      albumArtist = tags.get('albumArtist');
      album = tags.get('album');
      genre = tags.get('genre');
      comment = tags.get('comment');
      year = tags.get('year');
      final String lyric = tags.get(Tags.lyrics);
      if (lyric.trim().isNotEmpty) {
        lyrics = _clip(lyric);
        hasLyrics = true;
      }
    }
    hasCover = cover;
    metaLoaded = true;
    renormalize();
  }

  void applyLyrics(String? text) {
    if (text == null || text.trim().isEmpty) return;
    lyrics = _clip(text);
    hasLyrics = true;
    renormalize();
  }

  /// 预计算归一串；任何字段变化后都要调一次。
  void renormalize() {
    _nName = SearchQuery.norm(name);
    _nPath = SearchQuery.norm(relPath);
    _nTitle = SearchQuery.norm(title);
    _nArtist = SearchQuery.norm(artist);
    _nAlbumArtist = SearchQuery.norm(albumArtist);
    _nAlbum = SearchQuery.norm(album);
    _nGenre = SearchQuery.norm(genre);
    _nComment = SearchQuery.norm(comment);
    _nLyrics = SearchQuery.norm(lyrics);
    _nYear = SearchQuery.norm(year);
  }

  static String _clip(String text) =>
      text.length > SearchIndex.lyricsHead ? text.substring(0, SearchIndex.lyricsHead) : text;
}

/// 曲库内存索引。
class SearchIndex {
  /// 每首歌最多存这么多字符的歌词用于搜索（约 2000 行正文的 1/4，够命中副歌）。
  static const int lyricsHead = 20000;

  final List<Entry> _entries = <Entry>[];
  final Map<String, Entry> _byId = <String, Entry>{};

  void clear() {
    _entries.clear();
    _byId.clear();
  }

  int size() => _entries.length;

  List<Entry> all() => List<Entry>.unmodifiable(_entries);

  Entry? find(String? docId) => docId == null ? null : _byId[docId];

  /// 加入索引；同一个 docId 只保留一条（重复会让库页把同一首列两遍）。
  void add(Entry e) {
    final Entry? old = _byId[e.docId];
    if (old != null) {
      final int at = _entries.indexOf(old);
      if (at >= 0) _entries[at] = e;
      _byId[e.docId] = e;
      return;
    }
    _entries.add(e);
    _byId[e.docId] = e;
  }

  /// 已读标签的条数（界面上用来说清「标签搜索覆盖了多少」）。
  int loadedCount() => _entries.where((Entry e) => e.metaLoaded).length;

  /// 按查询过滤，返回保持原顺序的子集。
  List<Entry> search(SearchQuery? q) {
    if (q == null || q.isEmpty) return List<Entry>.unmodifiable(_entries);
    return _entries.where((Entry e) => matches(e, q)).toList();
  }

  static bool matches(Entry e, SearchQuery? q) {
    if (q == null) return true;
    if (e.size < q.minSize || (q.maxSize >= 0 && e.size > q.maxSize)) return false;
    for (final MapEntry<String, String> f in q.fields.entries) {
      if (f.value.isEmpty) continue;
      if (!_fieldValue(e, f.key).contains(f.value)) return false;
    }
    for (final String term in q.terms) {
      if (term.isEmpty) continue;
      if (!_anyField(e, term)) return false;
    }
    return true;
  }

  static String _fieldValue(Entry e, String field) {
    switch (field) {
      case 'title':
        // 没读过标签时退化为文件名，免得 title:xxx 在未加载的行上永远不命中
        return e._nTitle.isEmpty ? e._nName : e._nTitle;
      case 'artist':
        return e._nArtist;
      case 'albumArtist':
        return e._nAlbumArtist;
      case 'album':
        return e._nAlbum;
      case 'genre':
        return e._nGenre;
      case 'comment':
        return e._nComment;
      case 'lyrics':
        return e._nLyrics;
      case 'path':
        return e._nPath;
      case 'ext':
        return e._nExt;
      case 'year':
        return e._nYear;
      default:
        return '';
    }
  }

  /// 自由词：文件名 / 路径 / 标签 / 歌词任意命中即可。
  static bool _anyField(Entry e, String term) =>
      e._nName.contains(term) ||
      e._nPath.contains(term) ||
      e._nTitle.contains(term) ||
      SearchQuery.norm(e.displayTitle()).contains(term) ||
      e._nArtist.contains(term) ||
      e._nAlbumArtist.contains(term) ||
      e._nAlbum.contains(term) ||
      e._nGenre.contains(term) ||
      e._nComment.contains(term) ||
      e._nLyrics.contains(term);
}
