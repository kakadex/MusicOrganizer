/// 咪咕音乐标签源（T10b）—— 移植自旧 net/Sources.java 的 migu(Query) 一段。
///
/// 咪咕主要用来补流派：只有它的 tags 里带流派词，但混着地区 / 场景标签
/// （如「中国台湾」「KTV 金曲」），所以只认 [genreWords] 白名单里的词。
/// 请求必须给 searchSwitch（song=1、tagSong=1），否则回的不是单曲列表；
/// 返回体里可能混着歌单 / 专辑，只留 resourceType=2 的单曲，且最多取 6 条。
library;

import '../model/candidate.dart';
import '../model/query.dart';
import '../net/http_client.dart';
import 'endpoints.dart';
import 'tag_source.dart';

class MiguSource implements TagSource {
  @override
  String get key => 'migu';

  @override
  String get label => '咪咕音乐';

  @override
  bool get supportsTags => true;

  @override
  bool get supportsLyrics => true;

  @override
  bool get supportsCover => true;

  /// 国内五家统一的基准置信度。
  static const double baseConfidence = 0.60;

  /// 咪咕会忽略 pageSize 直接回 20 条，这里自己截断，减少后面的打分开销。
  static const int maxCandidates = 6;

  /// 只认明确的流派词；地区 / 场景标签一概不要。
  static const List<String> genreWords = <String>[
    '流行', '摇滚', '民谣', '电子', '说唱', '嘻哈', '爵士', '古典', '乡村',
    '金属', '朋克', '灵魂乐', '蓝调', '雷鬼', '舞曲', '轻音乐', '古风',
    'R&B', 'R&B/Soul', '世界音乐', '原声', '动漫', '二次元',
  ];

  /// 匿名调用要带的来源页（与接口地址是两回事，换地址时它仍要写原站）。
  static Map<String, String> get headers => <String, String>{
        'Referer': Uri.https('app.c.nf.migu.cn', '/').toString(),
      };

  /// searchSwitch：song / tagSong 打开（tagSong 决定 tags 里有没有流派），
  /// 其余（专辑 / 歌手 / 歌单 / MV）全关。
  static const String searchSwitch = '{"song":1,"album":0,"singer":0,'
      '"tagSong":1,"mvSong":0,"bestShow":1,"songlist":0,"lyricSong":0}';

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
        'text': term,
        'pageNo': '1',
        'pageSize': '5',
        'isCopyright': '1',
        'sort': '1',
        'searchSwitch': searchSwitch,
      });
      final Map<dynamic, dynamic>? resultData =
          JsonPick.map(payload, 'songResultData');
      for (final dynamic item in JsonPick.list(resultData, 'result')) {
        if (item is! Map) continue;
        if (out.length >= maxCandidates) break;
        // 结果里可能混着歌单 / 专辑，只留 resourceType=2（单曲）
        final String type = JsonPick.str(item, 'resourceType');
        if (type.isNotEmpty && type != '2') continue;
        final Candidate c = Candidate()
          ..title = JsonPick.str(item, 'name')
          ..artist = joinNames(JsonPick.list(item, 'singers'))
          ..genre = pickGenre(JsonPick.list(item, 'tags'))
          ..source = key
          ..confidence = baseConfidence;
        final List<dynamic> albums = JsonPick.list(item, 'albums');
        if (albums.isNotEmpty) c.album = JsonPick.str(albums[0], 'name');
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

  /// 取第一个命中白名单的流派词；一个都没有返回空串。
  static String pickGenre(List<dynamic> tags) {
    for (final dynamic e in tags) {
      final String tag = e is String ? e.trim() : '';
      if (tag.isEmpty) continue;
      for (final String word in genreWords) {
        if (tag == word) return tag;
      }
    }
    return '';
  }
}
