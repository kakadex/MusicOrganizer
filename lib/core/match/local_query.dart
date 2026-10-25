/// 本地曲目 → 查询上下文（标签批量 / 封面批量 / 歌词批量共用）。
///
/// 三个批量页面都按同一口径取「标题 / 艺人 / 时长」：文件名候选 + 内嵌标签
/// 按用户设定的权重取舍（[TagQuery]），否则同一首歌在不同页面会搜出不同结果。
library;

import '../model/query.dart';
import '../model/tags.dart';
import '../model/vfile.dart';
import '../source/lyric_source.dart';
import '../source/tag_source.dart';
import 'name_parser.dart';

/// 查询上下文构造（纯 Dart）。
abstract final class LocalQuery {
  /// 由文件与已读标签造一次标签 / 歌词查询。
  static Query forFile(VFile f, Tags tags) => Query()
    ..filenameCandidates = NameParser.candidatePairs(f.stem())
    ..embeddedTags = tags.toMap()
    ..localDuration =
        f.cachedDurationMs > 0 ? f.cachedDurationMs / 1000.0 : null;

  /// 检索用的标题。
  static String title(Query q) => TagQuery.title(q);

  /// 检索用的艺人。
  static String artist(Query q) => TagQuery.artist(q);

  /// 是否中文曲目（决定国内源加成）。
  static bool chinese(Query q) => TagQuery.isChineseTrack(q);

  /// 同一上下文的歌词查询。
  static LyricQuery lyric(Query q, {String album = ''}) => LyricQuery(
        title: TagQuery.title(q),
        artist: TagQuery.artist(q),
        album: album,
        duration: q.localDuration,
      );
}
