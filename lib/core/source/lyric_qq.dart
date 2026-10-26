/// QQ 音乐歌词源。
///
/// 搜索走网页版 `musicu.fcg`（`DoSearchForQQMusicDesktop`，旧的 client_search_cp
/// 已返 500）拿 songmid，取歌词走 `fcg_query_lyric_new.fcg`。
/// 两个要点：
///   - 请求头要带 `Referer: y.qq.com`（搜索）/`y.qq.com/portal/player.html`（取词）；
///     本工程的取词回调只有 url + params 两个入参，请求头由上层客户端统一注入；
///   - 取词带 `nobase64=1`，但接口偶尔无视它仍返回 base64，所以这里做一次兜底解码；
///     响应有时还被 JSONP 包裹，先剥回调再解析。
/// 译文轨在 `trans`（很多曲子为空串，有就用、没有不影响原文）。
library;

import 'dart:convert';

import '../match/text_util.dart';
import '../model/lyric_hit.dart';
import '../net/http_client.dart';
import 'endpoints.dart';
import 'lyric_source.dart';
import 'tag_source.dart';

class QqLyricSource implements LyricSource {
  @override
  String get key => 'lyric_qq';

  @override
  String get label => 'QQ 音乐（歌词）';

  /// 搜索返回条数上限。
  static const int searchLimit = 6;

  /// 最多对几条候选去取歌词（每条都要再发一次请求）。
  static const int maxLyricFetch = 2;

  @override
  Future<List<LyricHit>> search(LyricQuery q,
      {TextFetcher? text, JsonFetcher? json}) async {
    final List<LyricHit> out = <LyricHit>[];
    final String term = '${q.artist.trim()} ${q.title.trim()}'.trim();
    if (term.isEmpty) return out;

    // Http.getJson / getText 还有 headers / timeout 两个必填参数，这里包一层对齐契约
    final JsonFetcher getJson = json ??
        (String url, Map<String, String>? params) =>
            Http.getJson(url, params, null, Http.readTimeoutCnMs);
    final TextFetcher getText = text ??
        (String url, Map<String, String>? params) =>
            Http.getText(url, params, null, Http.readTimeoutCnMs);

    final Map<String, Object> body = <String, Object>{
      'comm': <String, Object>{'ct': 19, 'cv': 1859, 'uin': 0},
      'req': <String, Object>{
        'method': 'DoSearchForQQMusicDesktop',
        'module': 'music.search.SearchCgiService',
        'param': <String, Object>{
          'num_per_page': searchLimit,
          'page_num': 1,
          'query': term,
        },
      },
    };
    final Object? payload = await getJson(
        Endpoints.urlOf(key, 0), <String, String>{'data': jsonEncode(body)});
    final Object? song = JsonPick.map(
        JsonPick.map(JsonPick.map(JsonPick.map(payload, 'req'), 'data'), 'body'),
        'song');
    final List<_Pick> picks = <_Pick>[];
    for (final dynamic item in JsonPick.list(song, 'list')) {
      if (item is! Map) continue;
      final _Pick p = _Pick()
        ..node = item
        ..title = JsonPick.firstNonEmpty(
            JsonPick.str(item, 'name'), JsonPick.str(item, 'title'))
        ..artist = _singers(JsonPick.list(item, 'singer'))
        ..duration = double.tryParse(JsonPick.str(item, 'interval'));
      p.score = _score(q, p.title, p.artist, p.duration);
      p.order = picks.length;
      picks.add(p);
    }
    _sortPicks(picks);

    int fetched = 0;
    for (final _Pick p in picks) {
      if (fetched >= maxLyricFetch) break;
      // 新搜索接口里唯一标识字段是 mid（老接口叫 songmid）
      final String mid = JsonPick.firstNonEmpty(
          JsonPick.str(p.node, 'mid'), JsonPick.str(p.node, 'songmid'));
      if (mid.isEmpty) continue;
      fetched++;
      final String? raw = await getText(Endpoints.urlOf(key, 1), <String, String>{
        'songmid': mid,
        'format': 'json',
        'nobase64': '1',
        'g_tk': '5381',
      });
      final String lyric = _field(raw, 'lyric');
      if (lyric.trim().isEmpty) continue;
      out.add(LyricPick.hit(
        'qqmusic',
        title: p.title,
        artist: p.artist,
        duration: p.duration,
        synced: lyric,
        translation: _field(raw, 'trans'),
      ));
    }
    return out;
  }

  /// 歌手数组 → 「甲,乙」。
  static String _singers(List<dynamic> array) {
    final List<String> names = <String>[];
    for (final dynamic a in array) {
      if (a is Map) names.add(JsonPick.str(a, 'name'));
    }
    return TextUtil.joinArtists(names, ',');
  }

  /// 剥 JSONP 包裹 → 取字段 → 必要时 base64 解码 → 反转义 HTML 实体。
  static String _field(String? raw, String key) {
    if (raw == null) return '';
    String text = raw.trim();
    final int brace = text.indexOf('{');
    if (brace > 0) text = text.substring(brace);
    final int close = text.lastIndexOf('}');
    if (close >= 0 && close < text.length - 1) text = text.substring(0, close + 1);
    Object? node;
    try {
      node = jsonDecode(text);
    } on FormatException {
      return '';
    }
    String value = JsonPick.str(node, key);
    if (value.isEmpty) return '';
    if (!value.contains('[')) {
      // 没有时间轴前缀，多半是被 base64 了
      final String? plain = _decodeBase64(value);
      if (plain != null && plain.contains('[')) value = plain;
    }
    return _unescapeHtml(value);
  }

  static String? _decodeBase64(String value) {
    String padded = value.trim();
    final int m = padded.length % 4;
    if (m != 0) padded += '=' * (4 - m);
    try {
      return utf8.decode(base64.decode(padded), allowMalformed: true);
    } on FormatException {
      return null;
    }
  }

  /// 粗排打分：只为决定先取哪几条歌词。
  static double _score(LyricQuery q, String title, String artist, double? dur) {
    final double ts = TextUtil.textSimilarity(q.title, title);
    final double a = q.artist.trim().isEmpty || artist.isEmpty
        ? 0.5
        : TextUtil.bestArtistSimilarity(q.artist.trim(), artist);
    double d = 0.5;
    final double? local = q.duration;
    if (local != null && local > 0 && dur != null && dur > 0) {
      final double diff = (local - dur).abs();
      d = diff <= 3 ? 1.0 : (diff >= 15 ? 0.0 : 1.0 - (diff - 3) / 12.0);
    }
    return 0.55 * ts + 0.25 * a + 0.20 * d;
  }

  static void _sortPicks(List<_Pick> picks) {
    picks.sort((_Pick a, _Pick b) {
      final int x = b.score.compareTo(a.score);
      return x != 0 ? x : a.order.compareTo(b.order);
    });
  }

  /// QQ 返回的歌词里偶有数字实体与 &apos; 之类，不转义会原样写进 .lrc。
  static String _unescapeHtml(String text) {
    if (!text.contains('&')) return text;
    return text
        .replaceAll('&apos;', "'")
        .replaceAll('&quot;', '"')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&#39;', "'")
        .replaceAll('&#58;', ':')
        .replaceAll('&#46;', '.')
        .replaceAll('&#45;', '-')
        .replaceAll('&#44;', ',')
        .replaceAll('&amp;', '&');
  }
}

/// 一条待取歌词的搜索结果。
class _Pick {
  Map<dynamic, dynamic> node = const <dynamic, dynamic>{};
  String title = '';
  String artist = '';
  double? duration;
  double score = 0;
  int order = 0;
}
