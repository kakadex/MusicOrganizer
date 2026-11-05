/// 酷我音乐标签源。
///
/// 酷我字段全大写：SONGNAME（取不到再退 NAME）/ ARTIST / ALBUM / DURATION，
/// 时长本来就是秒。返回体是 `abslist` 数组；标题为空的记录直接丢掉，
/// 否则会往聚合里塞一条「只有时长」的噪声候选。封面从 `hts_IMG` /
/// `web_albumpic_short` 取（搜索接口本身就带，不用单独再问一次）。
library;

import '../model/candidate.dart';
import '../model/query.dart';
import '../net/http_client.dart';
import 'endpoints.dart';
import 'tag_source.dart';

class KuwoSource implements TagSource {
  @override
  String get key => 'kuwo';

  @override
  String get label => '酷我音乐';

  @override
  bool get supportsTags => true;

  @override
  bool get supportsLyrics => true;

  @override
  bool get supportsCover => true;

  /// 国内五家统一的基准置信度。
  static const double baseConfidence = 0.60;

  /// 每页条数。
  static const int pageSize = 5;

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
      // 这串参数是酷我 App 端在用的固定组合，缺一项就拿不到 abslist
      final Object? payload = await get(
          Endpoints.urlOf(key, 0), <String, String>{
        'client': 'kt',
        'all': term,
        'pn': '0',
        'rn': '$pageSize',
        'uid': '1234',
        'ver': 'kwplayer_ar_9.2.2.1',
        'vipver': '1',
        'show_copyright_off': '1',
        'newver': '1',
        'ft': 'music',
        'cluster': '0',
        'strategy': '2012',
        'encoding': 'utf8',
        'rformat': 'json',
        'vermerge': '1',
        'mobi': '1',
      });
      for (final dynamic item in JsonPick.list(payload, 'abslist')) {
        if (item is! Map) continue;
        final Candidate c = Candidate()
          ..title = JsonPick.firstNonEmpty(
              JsonPick.str(item, 'SONGNAME'), JsonPick.str(item, 'NAME'))
          ..artist = JsonPick.str(item, 'ARTIST')
          ..album = JsonPick.str(item, 'ALBUM')
          ..coverUrl = coverOf(JsonPick.firstNonEmpty(
              JsonPick.str(item, 'hts_IMG'),
              JsonPick.str(item, 'web_albumpic_short')))
          ..source = key
          ..confidence = baseConfidence;
        final double? dur = double.tryParse(JsonPick.str(item, 'DURATION'));
        if (dur != null && dur > 0) c.duration = dur;
        if (c.title.isEmpty) continue;
        out.add(c);
      }
    } catch (_) {
      // 单源异常只是少一家结果，聚合层按「空结果」处理
      return <Candidate>[];
    }
    return out;
  }

  /// 酷我的 `hts_IMG` 是完整地址（`http://img4.kuwo.cn/.../90.jpg` 这类，
  /// 末段是尺寸）；`web_albumpic_short` 是缺协议头的相对路径。统一补全并把
  /// 常见小尺寸升到 500（酷我按 `/<尺寸>.jpg` 分档，升档直接替换数字）。
  static String coverOf(String raw) {
    String url = raw.trim();
    if (url.isEmpty) return '';
    if (url.startsWith('//')) {
      url = 'https:$url';
    } else if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://img4.kuwo.cn/star/albumcover/$url';
    }
    return url
        .replaceAll('/90.jpg', '/500.jpg')
        .replaceAll('/120.jpg', '/500.jpg')
        .replaceAll('/150.jpg', '/500.jpg')
        .replaceAll('/240.jpg', '/500.jpg');
  }
}
