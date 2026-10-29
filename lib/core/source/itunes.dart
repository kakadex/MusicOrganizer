/// iTunes 标签源。
///
/// 海外源之一：字段为 trackName / artistName / collectionName / releaseDate /
/// trackTimeMillis / artworkUrl100。外文曲目的主力（中文曲目召回弱，靠 [SourceRank] 压后）。
library;

import '../lyrics/zh.dart';
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
    // 中文歌走台湾区：那里中文歌手的名字是「崔健」而不是拼音
    // 「Cui Jian」，否则艺人相似度趋零，原唱会被当成「艺人对不上」淘汰。
    // 外文歌仍走美国区，曲库更全。
    final bool cn = TagQuery.isChineseTrack(q);
    final Object? payload = await get(Endpoints.urlOf(key, 0),
        <String, String>{
          'term': term,
          'media': 'music',
          'limit': '10',
          'country': cn ? 'TW' : 'US',
        });
    for (final dynamic item in JsonPick.list(payload, 'results')) {
      if (item is! Map) continue;
      // 台湾区返回的是繁体（一無所有 / 新長征路上的搖滾）：写入标签前统一转简，
      // 否则用户曲库里会混进繁体标题，和本地文件名对不上。
      String pick(String field) {
        final String raw = JsonPick.str(item, field);
        return cn ? Zh.toSimplified(raw) : raw;
      }

      final Candidate c = Candidate()
        ..title = pick('trackName')
        ..artist = pick('artistName')
        ..album = pick('collectionName')
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
