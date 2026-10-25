/// lyrics.ovh 歌词源（T10b）—— 移植自旧 net/LyricSources.java 的 ovh() 段。
///
/// 只有纯文本、没有时间轴，但当另外几家全空时，用户勾了「接受纯文本歌词」
/// 至少还能拿到词。地址是**路径参数**（`/v1/{艺人}/{歌名}`），两段都要单独编码；
/// 艺人读不到时按旧版填 `unknown`。
library;

import '../model/lyric_hit.dart';
import '../net/http_client.dart';
import 'endpoints.dart';
import 'lyric_source.dart';
import 'tag_source.dart';

class OvhLyricSource implements LyricSource {
  @override
  String get key => 'lyric_ovh';

  @override
  String get label => 'lyrics.ovh';

  /// 艺人读不到时的占位（旧版 ovh() 里的 "unknown"）。
  static const String unknownArtist = 'unknown';

  @override
  Future<List<LyricHit>> search(LyricQuery q,
      {TextFetcher? text, JsonFetcher? json}) async {
    final List<LyricHit> out = <LyricHit>[];
    final String title = q.title.trim();
    if (title.isEmpty) return out;
    final String artist = q.artist.trim();

    // Http.getJson 还有 headers / timeout 两个必填参数，这里包一层对齐契约
    final JsonFetcher get = json ??
        (String url, Map<String, String>? params) =>
            Http.getJson(url, params, null, Http.readTimeoutOverseasMs);

    final Object? payload = await get(_url(artist, title), null);
    final String lyric = JsonPick.str(payload, 'lyrics');
    if (lyric.trim().isEmpty) return out;
    out.add(LyricPick.hit(
      'lyricsovh',
      title: title,
      artist: artist,
      plain: lyric,
    ));
    return out;
  }

  /// `/v1/{艺人}/{歌名}`：基址去掉末尾斜杠，两段路径各自编码。
  String _url(String artist, String title) {
    String base = Endpoints.urlOf(key, 0);
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    final String a = artist.isEmpty ? unknownArtist : artist;
    return '$base/${Uri.encodeComponent(a)}/${Uri.encodeComponent(title)}';
  }
}
