/// LRCLIB 歌词源（T10b）—— 移植自旧 net/LrcClient.java 的「查询构造 + 结果解析」部分。
///
/// 精确 `/api/get` 优先（带 track_name / artist_name / album_name / duration），
/// 拿不到同步歌词再回退 `/api/search`（关键词 = 歌名 + 艺人）。
/// 350ms 一票的节流、缓存、失败原因都留在客户端层，本文件只负责
/// 「按查询造参数」与「把节点抹平成 [LyricHit]」。
///
/// 排序沿用旧版：同步歌词优先 → 时长接近优先。
library;

import '../model/lyric_hit.dart';
import '../net/http_client.dart';
import 'endpoints.dart';
import 'lyric_source.dart';
import 'tag_source.dart';

class LrclibSource implements LyricSource {
  @override
  String get key => 'lrclib';

  @override
  String get label => 'LRCLIB';

  /// 模糊搜索最多取前几条（旧 LrcClient 的 `i < 10`）。
  static const int maxSearch = 10;

  /// 时长差取不到时用的兜底值（排最后）。
  static const double faraway = 1e9;

  @override
  Future<List<LyricHit>> search(LyricQuery q,
      {TextFetcher? text, JsonFetcher? json}) async {
    final List<LyricHit> out = <LyricHit>[];
    final String title = q.title.trim();
    if (title.isEmpty) return out;

    // Http.getJson 还有 headers / timeout 两个必填参数，这里包一层对齐契约
    final JsonFetcher get = json ??
        (String url, Map<String, String>? params) =>
            Http.getJson(url, params, null, Http.readTimeoutOverseasMs);

    final Map<String, String> exact = <String, String>{'track_name': title};
    final String artist = q.artist.trim();
    final String album = q.album.trim();
    if (artist.isNotEmpty) exact['artist_name'] = artist;
    if (album.isNotEmpty) exact['album_name'] = album;
    final double? dur = q.duration;
    if (dur != null && dur > 0) exact['duration'] = '${dur.round()}';

    final Object? payload = await get(Endpoints.urlOf(key, 0), exact);
    final LyricHit? hit = _toHit(payload);
    if (hit != null) out.add(hit);

    // 精确查询没给同步歌词时再走模糊搜索（旧版口径：hasSynced 为假才搜）
    if (hit == null || hit.synced.isEmpty) {
      final Object? found = await get(Endpoints.urlOf(key, 1),
          <String, String>{'q': '$title $artist'.trim()});
      final List<dynamic> list = _listOf(found);
      for (int i = 0; i < list.length && i < maxSearch; i++) {
        final LyricHit? h = _toHit(list[i]);
        if (h != null) out.add(h);
      }
    }

    // 排序：同步歌词优先 → 时长接近优先（旧 LrcClient.lookup 末尾的排序）
    out.sort((LyricHit a, LyricHit b) {
      final int x = (b.synced.isNotEmpty ? 1 : 0) - (a.synced.isNotEmpty ? 1 : 0);
      if (x != 0) return x;
      final double? da = LyricPick.durationDiff(a.duration, q.duration);
      final double? db = LyricPick.durationDiff(b.duration, q.duration);
      return (da ?? faraway).compareTo(db ?? faraway);
    });
    return out;
  }

  /// 一个节点 → 命中；没有歌词返回 null（旧 LrcClient.normalize + hasLyrics）。
  static LyricHit? _toHit(Object? node) {
    if (node is! Map) return null;
    final String synced = JsonPick.str(node, 'syncedLyrics');
    final String plain = JsonPick.str(node, 'plainLyrics');
    final bool instrumental = JsonPick.str(node, 'instrumental') == 'true';
    if (synced.isEmpty && plain.isEmpty && !instrumental) return null;
    return LyricPick.hit(
      'lrclib',
      title: JsonPick.firstNonEmpty(
          JsonPick.str(node, 'trackName'), JsonPick.str(node, 'name')),
      artist: JsonPick.str(node, 'artistName'),
      duration: double.tryParse(JsonPick.str(node, 'duration')),
      synced: synced,
      plain: plain,
    );
  }

  /// 搜索结果可能是数组，也可能是 `{data: [...]}`。
  static List<dynamic> _listOf(Object? payload) {
    if (payload is List) return payload;
    return JsonPick.list(payload, 'data');
  }
}
