/// 专辑封面第二跳：歌搜不到图时，用「专辑名 + 艺人」单独问封面源。
///
/// 为什么需要：封面批量只看「标签候选里有没有带封面地址的条目」，而
/// 酷狗 / 酷我 / 咪咕 / MusicBrainz 的候选没有封面字段；冷门歌在
/// 网易 / QQ / Deezer / iTunes 搜不到同名歌时，整首就没图了。但「专辑」
/// 往往仍能搜到 —— Deezer 的专辑搜索必带 cover_xl，iTunes 的专辑条目
/// 带 artworkUrl100。这里就是那第二跳：歌图拿不到，退而求专辑图。
///
/// 两条纪律（2026-11-05 实测教训：不加这两条，同一批歌两轮能跑出 50 / 87
/// 两种结果，因为 Deezer / iTunes 有调用频率限制，跑中后段就被限流）：
/// 1. **同一专辑只问一次**：[AlbumCoverCache] 缓存「专辑+艺人 → 图地址」；
/// 2. **全局串行 + 最小间隔**：同一时刻只有一条专辑查询在途，且两次请求
///    至少间隔 [defaultIntervalMs]，不再几十首并发把对端打穿。
/// 另：被限流 / 联网失败的结果**不算「没图」**，标记 [AlbumCoverLookup.temporary]，
/// 由调用方稍后重试。
library;

import '../model/candidate.dart';
import '../net/http_client.dart';
import 'album_cover_cache.dart';
import 'endpoints.dart';
import 'itunes.dart';
import 'tag_source.dart';

/// 一次专辑封面查询的产出。
class AlbumCoverLookup {
  const AlbumCoverLookup(this.url, this.source, {this.temporary = false});

  /// 封面图地址；空串表示没有拿到。
  final String url;

  /// 命中的源（deezer / itunes / cache）；空串表示没命中。
  final String source;

  /// 失败是「暂时性」的（被限流 / 联网失败），稍后重试可能成功。
  ///
  /// 这种结果不写缓存，避免把「今天被限流」记成「这张专辑没图」。
  final bool temporary;
}

/// 专辑封面查询（纯编排，网络细节在 [Http]）。
abstract final class AlbumCover {
  /// 两次专辑查询之间的最小间隔（毫秒）。
  ///
  /// 取 350ms：iTunes 约 20 次/分钟（≈3 秒一次），Deezer 约 50 次/5 秒
  /// （≈100 毫秒一次）。有专辑缓存后真正发出去的请求只剩几十条，350ms
  /// 够用且不至于把补封面拖成几分钟。
  static const int defaultIntervalMs = 350;

  /// 串行闸门：上一条查询结束后才放下一条进来。
  static Future<void> _gate = Future<void>.value();

  /// 下一条请求允许发出的时候（毫秒时间戳）。
  static int _nextAtMs = 0;

  /// 测试用：清掉串行/节流状态。
  static void resetLimiter() {
    _gate = Future<void>.value();
    _nextAtMs = 0;
  }

  /// 用专辑名 + 艺人搜专辑图。
  ///
  /// [album] 空时直接返回空（不联网）。Deezer 在前（中文专辑也能命中、
  /// 图固定 1000×1000），iTunes 兜底（专辑条目在台湾区收中文全）。
  ///
  /// [cache] 命中时**不发任何请求**；查询成功/确认无图都会写回缓存。
  /// [isBlocked] 判断某主机当前是否在熔断冷却中（测试可注入）。
  static Future<AlbumCoverLookup> lookup(
    String album,
    String artist, {
    JsonFetcher? fetch,
    AlbumCoverCache? cache,
    bool Function(String host)? isBlocked,
    int minIntervalMs = defaultIntervalMs,
  }) async {
    final String a = album.trim();
    final String ar = artist.trim();
    if (a.isEmpty) return const AlbumCoverLookup('', '');

    final String? cached = cache?.lookup(a, ar);
    if (cached != null) {
      return cached.isEmpty
          ? const AlbumCoverLookup('', 'cache')
          : AlbumCoverLookup(cached, 'cache');
    }

    // 串行：查缓存是同步的（上面），只有真正要联网时才排队。
    // 排队期间别的任务可能已经把同一张专辑写进缓存了，进闸门后再查一次，
    // 避免同专辑并发时白问一遍。
    return _serial<AlbumCoverLookup>(() {
      final String? again = cache?.lookup(a, ar);
      if (again != null) {
        return Future<AlbumCoverLookup>.value(again.isEmpty
            ? const AlbumCoverLookup('', 'cache')
            : AlbumCoverLookup(again, 'cache'));
      }
      return _query(a, ar,
          fetch: fetch,
          cache: cache,
          isBlocked: isBlocked,
          minIntervalMs: minIntervalMs);
    });
  }

  static Future<AlbumCoverLookup> _query(
    String album,
    String artist, {
    JsonFetcher? fetch,
    AlbumCoverCache? cache,
    bool Function(String host)? isBlocked,
    required int minIntervalMs,
  }) async {
    final bool Function(String) blocked = isBlocked ?? Http.breaker.isCoolingDown;
    final JsonFetcher get = fetch ??
        (String url, Map<String, String>? params) =>
            Http.getJson(url, params, null, Http.readTimeoutOverseasMs);

    final String term = artist.isEmpty ? album : '$artist $album';
    int tried = 0; // 尝试过的源数（含「因冷却跳过」）
    int answered = 0; // 正常应答的源数（返回了 JSON）

    // ① Deezer 专辑搜索。
    final String deezerUrl = Endpoints.urlOf('deezer', 1);
    if (deezerUrl.isNotEmpty) {
      tried++;
      final String host = _hostOf(deezerUrl);
      // 冷却中的源跳过，但**继续问下一家**——Deezer 连不上时 iTunes 往往
      // 是好的（实测：Deezer 超时、iTunes 200）。早先版本在这里直接返回
      // 「暂时失败」，一次都不问 iTunes，整批歌因此被误判成拿不到封面。
      if (!blocked(host)) {
        await _waitTurn(minIntervalMs);
        final Object? payload =
            await get(deezerUrl, <String, String>{'q': term, 'limit': '5'});
        if (payload is Map) {
          answered++;
          final String cover = _pickDeezer(payload);
          if (cover.isNotEmpty) {
            cache?.remember(album, artist, cover);
            return AlbumCoverLookup(cover, 'deezer');
          }
        }
      }
    }

    // ② iTunes 兜底：entity=album 只回专辑条目，artworkUrl100 升到 600。
    final String itunesUrl = Endpoints.urlOf('itunes', 0);
    if (itunesUrl.isNotEmpty) {
      tried++;
      final String host = _hostOf(itunesUrl);
      if (!blocked(host)) {
        await _waitTurn(minIntervalMs);
        final Object? payload = await get(itunesUrl, <String, String>{
          'term': term,
          'media': 'music',
          'entity': 'album',
          'limit': '5',
          'country': _looksChinese(album, artist) ? 'TW' : 'US',
        });
        if (payload is Map) {
          answered++;
          final String cover = _pickItunes(payload);
          if (cover.isNotEmpty) {
            cache?.remember(album, artist, cover);
            return AlbumCoverLookup(cover, 'itunes');
          }
        }
      }
    }

    // 一家都没正常应答（全在冷却 / 全超时）→ 暂时性失败，**不写负缓存**：
    // 明天网络好了还得再查。
    if (answered == 0) {
      return tried == 0 ? const AlbumCoverLookup('', '') : _temp();
    }
    // 部分源没应答：结论不完整，返回「没找到」但不缓存，避免把
    // 「Deezer 当时连不上」记成「这张专辑没图」14 天。
    if (answered < tried) return const AlbumCoverLookup('', '');
    cache?.remember(album, artist, '');
    return const AlbumCoverLookup('', '');
  }

  /// Deezer 响应里挑第一条封面地址。
  static String _pickDeezer(Map<dynamic, dynamic> payload) {
    for (final dynamic item in JsonPick.list(payload, 'data')) {
      if (item is! Map) continue;
      final String cover = JsonPick.firstNonEmpty(
          JsonPick.str(item, 'cover_xl'), JsonPick.str(item, 'cover_big'));
      if (cover.isNotEmpty) return cover;
    }
    return '';
  }

  /// iTunes 响应里挑第一条封面地址。
  static String _pickItunes(Map<dynamic, dynamic> payload) {
    for (final dynamic item in JsonPick.list(payload, 'results')) {
      if (item is! Map) continue;
      final String cover =
          ItunesSource.coverUrl(JsonPick.str(item, 'artworkUrl100'));
      if (cover.isNotEmpty) return cover;
    }
    return '';
  }

  /// 专辑查询涉及的两家主机，当前冷却剩余秒数的最大值（0 = 没在冷却）。
  ///
  /// 封面页据此决定「补跑前要等多久」，不必写死 90 秒。
  static int cooldownSecondsLeft() {
    int max = 0;
    for (final String url in <String>[
      Endpoints.urlOf('deezer', 1),
      Endpoints.urlOf('itunes', 0),
    ]) {
      final String host = _hostOf(url);
      final int left = Http.breaker.cooldownSecondsLeft(host);
      if (left > max) max = left;
    }
    return max;
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

  static const AlbumCoverLookup _tempLookup =
      AlbumCoverLookup('', '', temporary: true);

  static AlbumCoverLookup _temp() => _tempLookup;

  /// 等到「下一次允许发请求」的时刻。
  static Future<void> _waitTurn(int minIntervalMs) async {
    if (minIntervalMs <= 0) return;
    final int now = DateTime.now().millisecondsSinceEpoch;
    final int wait = _nextAtMs - now;
    _nextAtMs = (now > _nextAtMs ? now : _nextAtMs) + minIntervalMs;
    if (wait > 0) await Future<void>.delayed(Duration(milliseconds: wait));
  }

  /// 让 [task] 排在上一条专辑查询之后执行（全局串行）。
  static Future<T> _serial<T>(Future<T> Function() task) {
    final Future<T> next = _gate.then((_) => task());
    _gate = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  static String _hostOf(String url) {
    final String host = Uri.tryParse(url)?.host ?? '';
    return host.isEmpty ? url : host;
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
