/// 网易云歌词源（T10b）—— 移植自旧 net/LyricSources.java 的 netease() 段。
///
/// 搜索（`/api/search/get`）→ 取前几条最像的候选 → 逐个取歌词（`/api/song/lyric`）。
/// 照旧版保留的两个要点：
///   - 匿名搜索要带 `Referer: music.163.com` 与 `Cookie: appver=2.0.2`，否则接口
///     直接返 405「操作频繁」。本工程的取词回调只有 url + params 两个入参，
///     请求头由上层客户端统一注入；
///   - 取歌词时 `lv / kv / tv` 必须**都是 -1**（「有就都给我」）：只给 lv=1 时
///     译文轨 tlyric 整段为空。
/// 歌词在 `lrc.lyric`（标准 LRC 时间轴），译文在 `tlyric.lyric`。
library;

import '../match/text_util.dart';
import '../model/lyric_hit.dart';
import '../net/http_client.dart';
import 'endpoints.dart';
import 'lyric_source.dart';
import 'tag_source.dart';

class NeteaseLyricSource implements LyricSource {
  @override
  String get key => 'lyric_netease';

  @override
  String get label => '网易云（歌词）';

  /// 搜索返回条数（旧版 limit=6）。
  static const int searchLimit = 6;

  /// 最多对几条候选去取歌词（每条都要再发一次请求）。
  static const int maxLyricFetch = 2;

  @override
  Future<List<LyricHit>> search(LyricQuery q,
      {TextFetcher? text, JsonFetcher? json}) async {
    final List<LyricHit> out = <LyricHit>[];
    final String term = '${q.artist.trim()} ${q.title.trim()}'.trim();
    if (term.isEmpty) return out;

    // Http.getJson 还有 headers / timeout 两个必填参数，这里包一层对齐契约
    final JsonFetcher get = json ??
        (String url, Map<String, String>? params) =>
            Http.getJson(url, params, null, Http.readTimeoutCnMs);

    final Object? payload = await get(Endpoints.urlOf(key, 0), <String, String>{
      's': term,
      'type': '1',
      'offset': '0',
      'limit': '$searchLimit',
    });
    final List<dynamic> songs =
        JsonPick.list(JsonPick.map(payload, 'result'), 'songs');
    final List<_Pick> picks = <_Pick>[];
    for (final dynamic item in songs) {
      if (item is! Map) continue;
      final double ms = double.tryParse(JsonPick.str(item, 'duration')) ?? 0;
      final _Pick p = _Pick()
        ..node = item
        ..title = JsonPick.str(item, 'name')
        ..artist = _artists(JsonPick.list(item, 'artists'))
        ..duration = ms > 0 ? ms / 1000.0 : null;
      p.score = _score(q, p.title, p.artist, p.duration);
      p.order = picks.length;
      picks.add(p);
    }
    _sortPicks(picks);

    int fetched = 0;
    for (final _Pick p in picks) {
      if (fetched >= maxLyricFetch) break;
      final int id = int.tryParse(JsonPick.str(p.node, 'id')) ?? 0;
      if (id <= 0) continue;
      fetched++;
      final Object? node = await get(Endpoints.urlOf(key, 1), <String, String>{
        'id': '$id',
        'lv': '-1',
        'kv': '-1',
        'tv': '-1',
      });
      final String lyric = JsonPick.str(JsonPick.map(node, 'lrc'), 'lyric');
      if (lyric.trim().isEmpty) continue;
      out.add(LyricPick.hit(
        'netease',
        title: p.title,
        artist: p.artist,
        duration: p.duration,
        synced: lyric,
        translation: JsonPick.str(JsonPick.map(node, 'tlyric'), 'lyric'),
      ));
    }
    return out;
  }

  /// 艺人数组 → 「甲,乙」。
  static String _artists(List<dynamic> array) {
    final List<String> names = <String>[];
    for (final dynamic a in array) {
      if (a is Map) names.add(JsonPick.str(a, 'name'));
    }
    return TextUtil.joinArtists(names, ',');
  }

  /// 粗排打分（旧 net/LyricSources.java 的 roughScore）：只为决定先取哪几条歌词。
  static double _score(
      LyricQuery q, String title, String artist, double? dur) {
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
}

/// 一条待取歌词的搜索结果（旧 net/LyricSources.java 的 Pick）。
class _Pick {
  Map<dynamic, dynamic> node = const <dynamic, dynamic>{};
  String title = '';
  String artist = '';
  double? duration;
  double score = 0;
  int order = 0;
}
