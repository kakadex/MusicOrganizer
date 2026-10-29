/// 酷狗音乐标签源。
///
/// 移动端搜索接口，字段全小写下划线：songname / singername / album_name，
/// duration 本来就是秒。这家不给年份、音轨与封面，只用来补标题 / 艺人 / 专辑 / 时长。
library;

import '../model/candidate.dart';
import '../model/query.dart';
import '../net/http_client.dart';
import 'endpoints.dart';
import 'tag_source.dart';

class KugouSource implements TagSource {
  @override
  String get key => 'kugou';

  @override
  String get label => '酷狗音乐';

  @override
  bool get supportsTags => true;

  @override
  bool get supportsLyrics => true;

  @override
  bool get supportsCover => true;

  /// 国内五家统一的基准置信度。
  static const double baseConfidence = 0.60;

  /// 每页条数。
  /// 每页条数（10 条：翻唱挤占前几条时仍有机会拿到原唱）。
  static const int pageSize = 10;

  @override
  Future<List<Candidate>> search(Query q, {JsonFetcher? fetch}) async {
    final List<Candidate> out = <Candidate>[];
    final String term = TagQuery.term(q);
    if (term.isEmpty) return out;

    // Http.getJson 还有 headers / timeout 两个必填参数，这里包一层对齐契约
    final JsonFetcher get = fetch ??
        (String url, Map<String, String>? params) =>
            Http.getJson(url, params, null, Http.readTimeoutCnMs);
    try {
      final Object? payload = await get(Endpoints.urlOf(key, 0), <String, String>{
        'keyword': term,
        'page': '1',
        'pagesize': '$pageSize',
        'format': 'json',
      });
      final Map<dynamic, dynamic>? data = JsonPick.map(payload, 'data');
      for (final dynamic item in JsonPick.list(data, 'info')) {
        if (item is! Map) continue;
        final Candidate c = Candidate()
          ..title = JsonPick.str(item, 'songname')
          ..artist = JsonPick.str(item, 'singername')
          ..album = JsonPick.str(item, 'album_name')
          ..source = key
          ..confidence = baseConfidence;
        final double? dur = double.tryParse(JsonPick.str(item, 'duration'));
        if (dur != null && dur > 0) c.duration = dur;
        out.add(c);
      }
    } catch (_) {
      // 单源异常只是少一家结果，聚合层按「空结果」处理
      return <Candidate>[];
    }
    return out;
  }
}
