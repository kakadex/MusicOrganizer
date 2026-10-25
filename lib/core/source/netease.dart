/// 网易云音乐标签源（T10b）—— 移植自旧 net/Sources.java 的 netease(Query) 一段。
///
/// 国内五家里字段最全的一家：年份来自 album.publishTime（毫秒时间戳），
/// 封面来自 album.picUrl 追加 800×800 参数，艺人是数组需要拼串。
/// 匿名调用必须带 Referer 与 Cookie(appver=2.0.2)，否则会被「操作频繁」挡掉；
/// 单次最多返回 5 条。
library;

import '../model/candidate.dart';
import '../model/query.dart';
import '../net/http_client.dart';
import 'endpoints.dart';
import 'tag_source.dart';

class NeteaseSource implements TagSource {
  @override
  String get key => 'netease';

  @override
  String get label => '网易云音乐';

  @override
  bool get supportsTags => true;

  @override
  bool get supportsLyrics => true;

  @override
  bool get supportsCover => true;

  /// 国内五家统一的基准置信度。
  static const double baseConfidence = 0.60;

  /// 一次最多返回几条。
  static const int maxCandidates = 5;

  /// 匿名调用要带的两个头：Referer 是站点要求的来源页（与接口地址是两回事，
  /// 换镜像地址时它仍要写原站），Cookie 里的 appver 用来避开匿名频率限制。
  static Map<String, String> get headers => <String, String>{
        'Referer': Uri.https('music.163.com', '/').toString(),
        'Cookie': 'appver=2.0.2',
      };

  @override
  Future<List<Candidate>> search(Query q, {JsonFetcher? fetch}) async {
    final List<Candidate> out = <Candidate>[];
    final String term = TagQuery.term(q);
    if (term.isEmpty) return out;

    // Http.getJson 还有 headers / timeout 两个必填参数，这里包一层对齐契约
    final JsonFetcher get = fetch ??
        (String url, Map<String, String>? params) =>
            Http.getJson(url, params, headers, Http.readTimeoutCnMs);
    try {
      final Object? payload = await get(Endpoints.urlOf(key, 0), <String, String>{
        's': term,
        'type': '1',
        'offset': '0',
        'limit': '$maxCandidates',
      });
      final Map<dynamic, dynamic>? result = JsonPick.map(payload, 'result');
      if (result == null) return out;
      for (final dynamic item in JsonPick.list(result, 'songs')) {
        if (item is! Map) continue;
        if (out.length >= maxCandidates) break;
        final Candidate c = Candidate()
          ..title = JsonPick.str(item, 'name')
          ..artist = joinNames(JsonPick.list(item, 'artists'))
          ..source = key
          ..confidence = baseConfidence;
        final Map<dynamic, dynamic>? album = JsonPick.map(item, 'album');
        if (album != null) {
          c.album = JsonPick.str(album, 'name');
          c.year = yearOfPublishTime(JsonPick.str(album, 'publishTime'));
          final String pic = JsonPick.str(album, 'picUrl');
          if (pic.isNotEmpty) {
            c.coverUrl = '$pic${pic.contains('?') ? '&' : '?'}param=800y800';
          }
        }
        // 时长是毫秒，统一折算成秒
        final double? dur = double.tryParse(JsonPick.str(item, 'duration'));
        if (dur != null && dur > 0) c.duration = dur / 1000.0;
        out.add(c);
      }
    } catch (_) {
      // 单源异常只是少一家结果，聚合层按「空结果」处理
      return <Candidate>[];
    }
    return out;
  }

  /// `[{'name':'A'},{'name':'B'}]` → `A,B`；空名跳过。
  static String joinNames(List<dynamic> array) {
    final List<String> names = <String>[];
    for (final dynamic e in array) {
      final String name = JsonPick.str(e, 'name');
      if (name.isNotEmpty) names.add(name);
    }
    return names.join(',');
  }

  /// publishTime 是毫秒时间戳；取不到或超出合理范围返回空串。
  static String yearOfPublishTime(String millis) {
    final double? v = double.tryParse(millis);
    if (v == null || v <= 0) return '';
    return JsonPick.yearOfMillis(v.toInt());
  }
}
