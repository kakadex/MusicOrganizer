/// iTunes 标签源。
///
/// 海外源之一：字段为 trackName / artistName / collectionName / releaseDate /
/// trackTimeMillis / artworkUrl100。外文曲目的主力（中文曲目召回弱，靠 [SourceRank] 压后）。
library;

import '../model/candidate.dart';
import '../model/query.dart';
import '../net/http_client.dart';
import 'endpoints.dart';
import 'tag_source.dart';

class ItunesSource implements TagSource {
  @override
  String get key => 'itunes';

  @override
  String get label => 'iTunes';

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
    final String term = TagQuery.term(q);
    if (term.isEmpty) return out;

    // Http.getJson 还有 headers / timeout 两个必填参数，这里包一层对齐契约
    final JsonFetcher get = fetch ??
        (String url, Map<String, String>? params) =>
            Http.getJson(url, params, null, Http.readTimeoutOverseasMs);
    final Object? payload = await get(Endpoints.urlOf(key, 0),
        <String, String>{'term': term, 'media': 'music', 'limit': '5'});
    for (final dynamic item in JsonPick.list(payload, 'results')) {
      if (item is! Map) continue;
      final Candidate c = Candidate()
        ..title = JsonPick.str(item, 'trackName')
        ..artist = JsonPick.str(item, 'artistName')
        ..album = JsonPick.str(item, 'collectionName')
        ..year = JsonPick.yearOf(JsonPick.str(item, 'releaseDate'))
        ..source = key
        ..confidence = baseConfidence
        ..coverUrl = coverUrl(JsonPick.str(item, 'artworkUrl100'));
      final String ms = JsonPick.str(item, 'trackTimeMillis');
      if (ms.isNotEmpty) {
        final double? v = double.tryParse(ms);
        if (v != null && v > 0) c.duration = v / 1000.0;
      }
      out.add(c);
    }
    return out;
  }

  /// artworkUrl100 只有 100×100，换成 600×600（尺寸段在路径里的 `100x100bb`）。
  static String coverUrl(String artworkUrl100) {
    if (artworkUrl100.isEmpty) return '';
    return artworkUrl100.replaceAll('/100x100bb', '/600x600bb').replaceAll('100x100bb', '600x600bb');
  }
}
