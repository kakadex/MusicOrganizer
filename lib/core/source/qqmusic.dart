/// QQ 音乐标签源。
///
/// 接口是网页版在用的 musicu.fcg：整个请求包（comm + req 两层）序列化成 JSON
/// 塞进 `data=` 参数，走 GET 出去。字段口径：index_album 就是专辑内曲序号
/// （中文曲目的「音轨」多来自这里），封面必须用 albummid 拼（songmid 会 404），
/// 年份取 time_public 的前四位。
library;

import 'dart:convert';

import '../model/candidate.dart';
import '../model/query.dart';
import '../net/http_client.dart';
import 'endpoints.dart';
import 'tag_source.dart';

class QqMusicSource implements TagSource {
  @override
  String get key => 'qqmusic';

  @override
  String get label => 'QQ 音乐';

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

  /// 匿名调用要带的来源页（与接口地址是两回事，换地址时它仍要写原站）。
  static Map<String, String> get headers => <String, String>{
        'Referer': Uri.https('y.qq.com', '/').toString(),
      };

  /// 请求包：comm 是客户端标识（ct/cv/uin 是网页版的固定值），req 里才是检索条件。
  static String requestData(String term) {
    final Map<String, Object> root = <String, Object>{
      'comm': <String, Object>{'ct': 19, 'cv': 1859, 'uin': 0},
      'req': <String, Object>{
        'method': 'DoSearchForQQMusicDesktop',
        'module': 'music.search.SearchCgiService',
        'param': <String, Object>{
          'num_per_page': pageSize,
          'page_num': 1,
          'query': term,
        },
      },
    };
    return jsonEncode(root);
  }

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
      final Object? payload = await get(Endpoints.urlOf(key, 0),
          <String, String>{'data': requestData(term)});
      // 结果埋得深：req.data.body.song.list
      final Map<dynamic, dynamic>? req = JsonPick.map(payload, 'req');
      final Map<dynamic, dynamic>? data = JsonPick.map(req, 'data');
      final Map<dynamic, dynamic>? body = JsonPick.map(data, 'body');
      final Map<dynamic, dynamic>? song = JsonPick.map(body, 'song');
      for (final dynamic item in JsonPick.list(song, 'list')) {
        if (item is! Map) continue;
        final Candidate c = Candidate()
          ..title = JsonPick.firstNonEmpty(
              JsonPick.str(item, 'name'), JsonPick.str(item, 'title'))
          ..artist = joinNames(JsonPick.list(item, 'singer'))
          ..year = JsonPick.yearOf(JsonPick.str(item, 'time_public'))
          ..track = trackOf(JsonPick.str(item, 'index_album'))
          ..source = key
          ..confidence = baseConfidence;
        final Map<dynamic, dynamic>? album = JsonPick.map(item, 'album');
        if (album != null) {
          c.album = JsonPick.str(album, 'name');
          c.coverUrl = coverOf(JsonPick.firstNonEmpty(
              JsonPick.str(album, 'mid'), JsonPick.str(album, 'albummid')));
        }
        // interval 本来就是秒，不用折算
        final double? dur = double.tryParse(JsonPick.str(item, 'interval'));
        if (dur != null && dur > 0) c.duration = dur;
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

  /// 曲序号：只有正数才写，0 表示这家没给。
  static String trackOf(String indexAlbum) {
    final int? idx = int.tryParse(indexAlbum);
    if (idx == null || idx <= 0) return '';
    return '$idx';
  }

  /// 封面按 albummid 拼图片 CDN（不是接口地址，故不进 Endpoints 注册表）。
  static String coverOf(String albumMid) {
    if (albumMid.isEmpty) return '';
    return Uri.https(
            'y.gtimg.cn', '/music/photo_new/T002R800x800M000$albumMid.jpg')
        .toString();
  }
}
