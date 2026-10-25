/// 酷狗歌词源（T10b）—— 移植自旧 net/LyricSources.java 的 kugou() 段。
///
/// 搜索（`krcs.kugou.com/search`）拿候选的 id 与 accesskey，再走
/// `lyrics.kugou.com/download` 取歌词。取词两步：
///   1. 先要 `fmt=krc`（逐字），用 [Krc] 解开后转成只带行时间轴的 LRC；
///   2. 解不出来就退回 `fmt=lrc` 的明文歌词 —— **降级是常态，不是异常**
///      （线上 KRC 样本多一层加密，见 `Krc` 的类注释）。
/// 「艺人 + 歌名」查不到时按旧版只用歌名再搜一次（关键词越长越容易空）。
library;

import 'dart:convert';

import '../lyrics/krc.dart';
import '../match/text_util.dart';
import '../model/lyric_hit.dart';
import '../net/http_client.dart';
import 'endpoints.dart';
import 'lyric_source.dart';
import 'tag_source.dart';

class KugouLyricSource implements LyricSource {
  @override
  String get key => 'lyric_kugou';

  @override
  String get label => '酷狗（歌词）';

  /// 最多对几条候选去取歌词（每条都要再发一次请求）。
  static const int maxLyricFetch = 2;

  @override
  Future<List<LyricHit>> search(LyricQuery q,
      {TextFetcher? text, JsonFetcher? json}) async {
    final List<LyricHit> out = <LyricHit>[];
    final String term = '${q.artist.trim()} ${q.title.trim()}'.trim();
    final String title = q.title.trim();
    if (term.isEmpty || title.isEmpty) return out;

    // Http.getJson 还有 headers / timeout 两个必填参数，这里包一层对齐契约
    final JsonFetcher get = json ??
        (String url, Map<String, String>? params) =>
            Http.getJson(url, params, null, Http.readTimeoutCnMs);

    final double? local = q.duration;
    final Map<String, String> params = <String, String>{
      'ver': '1',
      'man': 'yes',
      'client': 'mobi',
      'keyword': term,
      'duration': local != null && local > 0 ? '${(local * 1000).round()}' : '',
      'hash': '',
    };
    List<dynamic> candidates = JsonPick.list(await get(Endpoints.urlOf(key, 0), params), 'candidates');
    if (candidates.isEmpty) {
      params['keyword'] = title;
      candidates = JsonPick.list(await get(Endpoints.urlOf(key, 0), params), 'candidates');
    }
    if (candidates.isEmpty) return out;

    final List<_Pick> picks = <_Pick>[];
    for (final dynamic item in candidates) {
      if (item is! Map) continue;
      final double ms = double.tryParse(JsonPick.str(item, 'duration')) ?? 0;
      final _Pick p = _Pick()
        ..title = JsonPick.str(item, 'song')
        ..artist = JsonPick.str(item, 'singer')
        ..id = JsonPick.str(item, 'id')
        ..accessKey = JsonPick.str(item, 'accesskey')
        ..duration = ms > 0 ? ms / 1000.0 : null;
      p.score = _score(q, p.title, p.artist, p.duration);
      p.order = picks.length;
      picks.add(p);
    }
    _sortPicks(picks);

    int fetched = 0;
    for (final _Pick p in picks) {
      if (fetched >= maxLyricFetch) break;
      if (p.id.isEmpty || p.accessKey.isEmpty) continue;
      fetched++;
      final LyricHit? hit = await _fetch(Endpoints.urlOf(key, 1), get, p);
      if (hit != null) out.add(hit);
    }
    return out;
  }

  /// 取一条候选的歌词：KRC 优先，解不出降级明文 LRC。
  static Future<LyricHit?> _fetch(String url, JsonFetcher get, _Pick p) async {
    final String krc = await _content(url, get, p, 'krc');
    if (krc.isNotEmpty) {
      final String plain = Krc.decode(krc);
      if (plain.trim().isNotEmpty) {
        final String lrc = Krc.toLrc(plain);
        if (lrc.isNotEmpty) return _hit(p, lrc);
      }
    }
    final String body = await _content(url, get, p, 'lrc');
    if (body.isEmpty) return null;
    if (body.trim().startsWith('[')) return _hit(p, body);
    final List<int>? bytes = Krc.decodeBase64(body);
    if (bytes == null || bytes.isEmpty) return null;
    final String text = utf8.decode(bytes, allowMalformed: true);
    if (text.trim().isEmpty) return null;
    return _hit(p, text);
  }

  /// 取服务端 `content` 字段（krc / lrc 看 fmt）；失败返回空串。
  static Future<String> _content(
      String url, JsonFetcher get, _Pick p, String fmt) async {
    final Object? payload = await get(url, <String, String>{
      'ver': '1',
      'client': 'pc',
      'id': p.id,
      'accesskey': p.accessKey,
      'fmt': fmt,
      'charset': 'utf8',
    });
    return JsonPick.str(payload, 'content');
  }

  static LyricHit _hit(_Pick p, String synced) => LyricPick.hit(
        'kugou',
        title: p.title,
        artist: p.artist,
        duration: p.duration,
        synced: synced,
      );

  /// 粗排打分（旧 net/LyricSources.java 的 roughScore）：只为决定先取哪几条歌词。
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
}

/// 一条待取歌词的搜索结果（旧 net/LyricSources.java 的 Pick）。
class _Pick {
  String title = '';
  String artist = '';
  String id = '';
  String accessKey = '';
  double? duration;
  double score = 0;
  int order = 0;
}
