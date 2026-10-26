/// Deezer 标签源。
///
/// 海外源之一：字段干净（title / artist.name / album.title / duration），
/// 还能给出封面地址（cover_xl → cover_big）。中文曲目召回弱，靠 [SourceRank] 压后。
library;

import '../model/candidate.dart';
import '../model/query.dart';
import '../net/http_client.dart';
import 'endpoints.dart';
import 'tag_source.dart';

class DeezerSource implements TagSource {
  @override
  String get key => 'deezer';

  @override
  String get label => 'Deezer';

  @override
  bool get supportsTags => true;

  @override
  bool get supportsLyrics => false;

  @override
  bool get supportsCover => true;

  /// 海外源的基准置信度。
  static const double baseConfidence = 0.75;

  @override
  Future<List<Candidate>> search(Query q, {JsonFetcher? fetch}) async {
    final List<Candidate> out = <Candidate>[];
    final String query = TagQuery.term(q);
    if (query.isEmpty) return out;

    // Http.getJson 还有 headers / timeout 两个必填参数，这里包一层对齐契约
    final JsonFetcher get = fetch ??
        (String url, Map<String, String>? params) =>
            Http.getJson(url, params, null, Http.readTimeoutOverseasMs);
    final Object? payload = await get(
        Endpoints.urlOf(key, 0), <String, String>{'q': query, 'limit': '5'});
    final List<dynamic> data = JsonPick.list(payload, 'data');
    for (final dynamic item in data) {
      if (item is! Map) continue;
      final Candidate c = Candidate()
        ..title = JsonPick.str(item, 'title')
        ..artist = JsonPick.str(JsonPick.map(item, 'artist'), 'name')
        ..album = JsonPick.str(JsonPick.map(item, 'album'), 'title')
        ..source = key
        ..confidence = baseConfidence;
      final Map? album = JsonPick.map(item, 'album');
      if (album != null) {
        c.coverUrl = JsonPick.firstNonEmpty(
            JsonPick.str(album, 'cover_xl'), JsonPick.str(album, 'cover_big'));
      }
      final String dur = JsonPick.str(item, 'duration');
      if (dur.isNotEmpty) {
        final double? d = double.tryParse(dur);
        if (d != null && d > 0) c.duration = d;
      }
      out.add(c);
    }
    return out;
  }
}
