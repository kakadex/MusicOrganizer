/// 专辑封面第二跳：歌搜不到图时，用「专辑名 + 艺人」单独问封面源。
///
/// 为什么需要：封面批量只看「标签候选里有没有带封面地址的条目」，而
/// 酷狗 / 酷我 / 咪咕 / MusicBrainz 的候选没有封面字段；冷门歌在
/// 网易 / QQ / Deezer / iTunes 搜不到同名歌时，整首就没图了。但「专辑」
/// 往往仍能搜到 —— Deezer 的专辑搜索必带 cover_xl，iTunes 的专辑条目
/// 带 artworkUrl100。这里就是那第二跳：歌图拿不到，退而求专辑图。
///
/// 纪律：只取图、不写标签；两家都是海外源，走海外超时。
library;

import '../model/candidate.dart';
import '../net/http_client.dart';
import 'endpoints.dart';
import 'itunes.dart';
import 'tag_source.dart';

/// 一次专辑封面查询的产出。
class AlbumCoverLookup {
  AlbumCoverLookup(this.url, this.source);

  /// 封面图地址；空串表示两家都没搜到。
  final String url;

  /// 命中的源（deezer / itunes）；空串表示没命中。
  final String source;
}

/// 专辑封面查询（纯编排，网络细节在 [Http]）。
abstract final class AlbumCover {
  /// 用专辑名 + 艺人搜专辑图。
  ///
  /// [album] / [artist] 都空时直接返回空（不联网）。Deezer 在前
  /// （中文专辑也能命中、图固定 1000×1000），iTunes 兜底（台湾区收中文全）。
  static Future<AlbumCoverLookup> lookup(
    String album,
    String artist, {
    JsonFetcher? fetch,
  }) async {
    final String a = album.trim();
    final String ar = artist.trim();
    if (a.isEmpty) return AlbumCoverLookup('', '');

    final JsonFetcher get = fetch ??
        (String url, Map<String, String>? params) =>
            Http.getJson(url, params, null, Http.readTimeoutOverseasMs);

    // ① Deezer 专辑搜索：q=专辑名（可带艺人提高准确度）。
    final String deezerUrl = Endpoints.urlOf('deezer', 1);
    if (deezerUrl.isNotEmpty) {
      final Object? payload = await get(
          deezerUrl,
          <String, String>{
            'q': ar.isEmpty ? a : '$ar $a',
            'limit': '5',
          });
      for (final dynamic item in JsonPick.list(payload, 'data')) {
        if (item is! Map) continue;
        final String cover = JsonPick.firstNonEmpty(
            JsonPick.str(item, 'cover_xl'), JsonPick.str(item, 'cover_big'));
        if (cover.isNotEmpty) return AlbumCoverLookup(cover, 'deezer');
      }
    }

    // ② iTunes 兜底：entity=album 只回专辑条目，artworkUrl100 升到 600。
    final String itunesUrl = Endpoints.urlOf('itunes', 0);
    if (itunesUrl.isNotEmpty) {
      final Object? payload = await get(itunesUrl, <String, String>{
        'term': ar.isEmpty ? a : '$ar $a',
        'media': 'music',
        'entity': 'album',
        'limit': '5',
        'country': _looksChinese(a, ar) ? 'TW' : 'US',
      });
      for (final dynamic item in JsonPick.list(payload, 'results')) {
        if (item is! Map) continue;
        final String cover =
            ItunesSource.coverUrl(JsonPick.str(item, 'artworkUrl100'));
        if (cover.isNotEmpty) return AlbumCoverLookup(cover, 'itunes');
      }
    }
    return AlbumCoverLookup('', '');
  }

  /// 从标签候选里取「专辑名 + 主艺人」：给 [lookup] 用。
  ///
  /// 取第一条带专辑名的候选（排序后就是最可信那条），艺人用同一条的；
  /// 候选没给艺人时退本地艺人（调用方传进来）。
  static (String, String) fromCandidates(
    Iterable<Candidate> candidates,
    String fallbackArtist,
  ) {
    for (final Candidate c in candidates) {
      final String album = c.album.trim();
      if (album.isEmpty) continue;
      return (album, c.artist.trim().isNotEmpty ? c.artist.trim() : fallbackArtist);
    }
    return ('', '');
  }

  /// 粗判中文（决定 iTunes 走台湾区还是美国区）：含汉字就算。
  static bool _looksChinese(String album, String artist) {
    for (final String s in <String>[album, artist]) {
      for (final int r in s.runes) {
        if (r >= 0x4E00 && r <= 0x9FFF) return true;
      }
    }
    return false;
  }
}
