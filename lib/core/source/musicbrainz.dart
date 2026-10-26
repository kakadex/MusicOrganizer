/// MusicBrainz 标签源。
///
/// 定位是**海外锚点**：中文曲目召回弱（库里常是罗马字译名），但外文曲目与
/// 「国内站没收的冷门歌」还得靠它。字段只有 title/artist/album/date，
/// 没有音轨与封面地址 —— 出封面靠别家补。
library;

import '../model/candidate.dart';
import '../model/query.dart';
import 'mb_client.dart';
import 'tag_source.dart';

class MusicBrainzSource implements TagSource {
  MusicBrainzSource({this.client});

  final MbClient? client;

  /// 兜底客户端（未注入时用它；单例，票约与缓存跨查询共享）。
  static final MbClient shared = MbClient();

  @override
  String get key => 'musicbrainz';

  @override
  String get label => 'MusicBrainz';

  @override
  bool get supportsTags => true;

  @override
  bool get supportsLyrics => false;

  @override
  bool get supportsCover => true;

  /// 海外锚点的基准置信度（比 Deezer/iTunes 高一级）。
  static const double baseConfidence = 0.85;

  @override
  Future<List<Candidate>> search(Query q, {JsonFetcher? fetch}) async {
    final List<Candidate> out = <Candidate>[];
    final MbClient mb = client ?? shared;
    final String title = TagQuery.title(q);
    final String artist = TagQuery.artist(q);
    if (mb.isOffline() || (title.isEmpty && artist.isEmpty)) return out;

    final List<MbRecording> hits =
        await mb.searchRecordings(title, artist, limit: 8, fetch: fetch);
    for (final MbRecording r in hits) {
      out.add(Candidate()
        ..title = r.title
        ..artist = r.artist
        ..album = r.album
        ..year = JsonPick.yearOf(r.date)
        ..source = key
        ..confidence = baseConfidence);
    }
    return out;
  }
}
