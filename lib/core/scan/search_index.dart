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

  /// 歌词的归一串（**惰性计算**）。
  ///
  /// 为什么不像其它字段那样在 [renormalize] 里直接算：歌词是唯一的长文本
  /// （单首上限 [SearchIndex.lyricsHead] = 20000 字），而归一化是 O(长度) 的。
  /// 实测一首 1.86 万字歌词算一次要 1.4 ms，建索引 / 读标签时每首都要算，
  /// 900 首带歌词的库就是 1.3 秒，5000 首接近 5 秒——全都压在 UI 线程上。
  ///
  /// 但搜索时歌词是 [_anyField] 的**最后一道**判断：找歌名 / 歌手在前几个字段
  /// 就命中了，绝大多数查询根本用不到歌词串。所以改成第一次真正读到时才算，
  /// 算完缓存；任何字段变化由 [renormalize] 置空失效。
  String? _nLyricsCache;

  String get _nLyrics => _nLyricsCache ??= SearchQuery.norm(lyrics);

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

  /// 标签是否齐（**标题 + 艺术家**都有）。
  ///
  /// 只看这两个字段：它们是「能不能被搜到 / 值不值得补」的关键。专辑、年份、
  /// 流派缺了不算「无标签」——否则一张合辑里缺专辑的行会永远挂在无标签筛选下，
  /// 而它其实什么都不缺。
  ///
  /// 标题取标签里的值，不拿文件名顶替：文件名不是标签。
  bool tagComplete() => title.trim().isNotEmpty && artist.trim().isNotEmpty;

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
  ///
  /// 歌词不在这里算，只把惰性缓存置空（见 [_nLyrics] 的说明）。
  void renormalize() {
    _nName = SearchQuery.norm(name);
    _nPath = SearchQuery.norm(relPath);
    _nTitle = SearchQuery.norm(title);
    _nArtist = SearchQuery.norm(artist);
    _nAlbumArtist = SearchQuery.norm(albumArtist);
    _nAlbum = SearchQuery.norm(album);
    _nGenre = SearchQuery.norm(genre);
    _nComment = SearchQuery.norm(comment);
    _nLyricsCache = null;
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

  /// docId → 在 [_entries] 里的下标（0.2.69）。
  ///
  /// 原来 `add` 更新已有条目时用 `_entries.indexOf(old)` 线性查找，
  /// 批量写 800 首标签逐首 invalidate 就是 800×800/2 ≈ 32 万次比较，
  /// 全部压在 UI 线程上 —— 用户感知就是「批量写入时明显卡顿」。
  /// 用这张表把定位降到 O(1)；条目只替换不移动，所以下标永远有效。
  final Map<String, int> _at = <String, int>{};

  void clear() {
    _entries.clear();
    _byId.clear();
    _at.clear();
  }

  int size() => _entries.length;

  List<Entry> all() => List<Entry>.unmodifiable(_entries);

  Entry? find(String? docId) => docId == null ? null : _byId[docId];

  /// 加入索引；同一个 docId 只保留一条（重复会让库页把同一首列两遍）。
  void add(Entry e) {
    final int? at = _at[e.docId];
    if (at != null) {
      _entries[at] = e;
      _byId[e.docId] = e;
      return;
    }
    _at[e.docId] = _entries.length;
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
