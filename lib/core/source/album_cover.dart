/// 专辑封面第二跳：歌搜不到图时，用「专辑名 + 艺人」问各家专辑库，
/// 再把各家的结果放在一起对比，取最像本地这张专辑的那张图。
///
/// 为什么需要：封面批量只看「标签候选里有没有带封面地址的条目」，而
/// 酷狗 / 酷我 / 咪咕 / MusicBrainz 的候选没有封面字段；冷门歌在
/// 网易 / QQ 搜不到同名歌时，整首就没图了。但「专辑」往往仍能搜到。
///
/// 三条纪律（都是实测踩出来的）：
/// 1. **一家不可用就问下一家**，且**所有能给图的源都要问到**——Deezer 在
///    部分网络下直接超时，早先版本一遇到它就放弃，连 iTunes 都不问；
/// 2. **多家结果做对比**：同名专辑/翻唱版很多（实测搜「给我一个理由忘记」
///    第一条是别人的翻唱版），必须按「专辑名 + 艺人」相似度挑，不能见图就拿；
/// 3. **同一专辑只问一次**（[AlbumCoverCache]）+ 全局串行与间隔。
/// 被限流 / 连不上的结果不写缓存，标记 [AlbumCoverLookup.temporary] 供重试。
library;

import '../match/text_util.dart';
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

  /// 命中的源（netease / kugou / deezer / itunes / cache）；空串表示没命中。
  final String source;

  /// 失败是「暂时性」的（源不可用 / 联网失败），稍后重试可能成功。
  ///
  /// 这种结果不写缓存，避免把「今天连不上」记成「这张专辑没图」。
  final bool temporary;
}

/// 一家给出的专辑候选（还没判定是不是同一张）。
class _AlbumPick {
  _AlbumPick(this.url, this.source, this.album, this.artist);

  final String url;
  final String source;
  final String album;
  final String artist;
}

/// 专辑封面查询（纯编排，网络细节在 [Http]）。
abstract final class AlbumCover {
  /// 两次专辑查询之间的最小间隔（毫秒）。
  ///
  /// 有专辑缓存后真正发出去的请求不多，留点间隔避免把对端打穿。
  static const int defaultIntervalMs = 250;

  /// 判定「同一张专辑」的最低综合分。
  static const double acceptScore = 0.62;

  /// 专辑名太泛时不去搜（搜了也只会拿到一堆不相干的图）。
  static const List<String> _genericAlbums = <String>[
    '未知专辑',
    '未知',
    'unknown',
    'unknown album',
    'untitled',
    'various artists',
    '群星',
    '精选',
  ];

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
  /// [album] 空或太泛时直接返回空（不联网）。各家依次问，能用的都问；
  /// 最后按「专辑名 + 艺人」相似度挑最像的那张。
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
    if (a.isEmpty || _isGeneric(a)) {
      return const AlbumCoverLookup('', '');
    }

    final String? cached = cache?.lookup(a, ar);
    if (cached != null) {
      return cached.isEmpty
          ? const AlbumCoverLookup('', 'cache')
          : AlbumCoverLookup(cached, 'cache');
    }

    // 串行：查缓存是同步的（上面），只有真正要联网时才排队。
    // 排队期间别的任务可能已经把同一张专辑写进缓存了，进闸门后再查一次。
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
    final String term = artist.isEmpty ? album : '$artist $album';
    final bool cn = _looksChinese(album, artist);

    int tried = 0; // 尝试过的源数（含「因不可用跳过」）
    int answered = 0; // 正常应答的源数（返回了 JSON）
    final List<_AlbumPick> picks = <_AlbumPick>[];

    /// 问一家：不可用就跳过、继续问下一家。
    Future<void> ask(
      String url,
      Map<String, String> params,
      Map<String, String>? headers,
      List<_AlbumPick> Function(Map<dynamic, dynamic> payload) parse,
    ) async {
      if (url.isEmpty) return;
      tried++;
      final String host = _hostOf(url);
      if (blocked(host)) return; // 不可用 → 跳过，问下一家
      await _waitTurn(minIntervalMs);
      final Object? payload = await _get(fetch, url, params, headers);
      if (payload is Map) {
        answered++;
        picks.addAll(parse(payload));
      }
    }

    // ① 网易云专辑搜索（中文场景最全；歌曲搜索接口不带 picUrl，只能走专辑搜索）。
    await ask(
      Endpoints.urlOf('netease', 1),
      <String, String>{'s': term, 'type': '10', 'limit': '5'},
      <String, String>{
        'Referer': 'https://music.163.com/',
        'Cookie': 'appver=2.0.2',
      },
      (Map<dynamic, dynamic> payload) {
        final Map<dynamic, dynamic>? result = JsonPick.map(payload, 'result');
        final List<dynamic> albums = JsonPick.list(result, 'albums');
        final List<_AlbumPick> out = <_AlbumPick>[];
        for (final dynamic item in albums) {
          if (item is! Map) continue;
          final String pic = JsonPick.str(item, 'picUrl');
          if (pic.isEmpty) continue;
          out.add(_AlbumPick(
            _neteasePic(pic),
            'netease',
            JsonPick.str(item, 'name'),
            _firstArtist(JsonPick.list(item, 'artists')),
          ));
        }
        return out;
      },
    );

    // ② 酷狗专辑搜索（imgurl 里带 {size} 占位，换成 500）。
    await ask(
      Endpoints.urlOf('kugou', 1),
      <String, String>{
        'keyword': term,
        'page': '1',
        'pagesize': '5',
        'format': 'json',
      },
      null,
      (Map<dynamic, dynamic> payload) {
        final Map<dynamic, dynamic>? data = JsonPick.map(payload, 'data');
        final List<dynamic> albums = JsonPick.list(data, 'info');
        final List<_AlbumPick> out = <_AlbumPick>[];
        for (final dynamic item in albums) {
          if (item is! Map) continue;
          final String img = JsonPick.str(item, 'imgurl');
          if (img.isEmpty) continue;
          out.add(_AlbumPick(
            _kugouImg(img),
            'kugou',
            JsonPick.str(item, 'albumname'),
            JsonPick.str(item, 'singername'),
          ));
        }
        return out;
      },
    );

    // ③ Deezer 专辑搜索。
    await ask(
      Endpoints.urlOf('deezer', 1),
      <String, String>{'q': term, 'limit': '5'},
      null,
      (Map<dynamic, dynamic> payload) {
        final List<_AlbumPick> out = <_AlbumPick>[];
        for (final dynamic item in JsonPick.list(payload, 'data')) {
          if (item is! Map) continue;
          final String cover = JsonPick.firstNonEmpty(
              JsonPick.str(item, 'cover_xl'), JsonPick.str(item, 'cover_big'));
          if (cover.isEmpty) continue;
          out.add(_AlbumPick(
            cover,
            'deezer',
            JsonPick.str(item, 'title'),
            JsonPick.str(JsonPick.map(item, 'artist'), 'name'),
          ));
        }
        return out;
      },
    );

    // ④ iTunes 专辑搜索（中文走台湾区，否则艺人名会是拼音）。
    await ask(
      Endpoints.urlOf('itunes', 0),
      <String, String>{
        'term': term,
        'media': 'music',
        'entity': 'album',
        'limit': '5',
        'country': cn ? 'TW' : 'US',
      },
      null,
      (Map<dynamic, dynamic> payload) {
        final List<_AlbumPick> out = <_AlbumPick>[];
        for (final dynamic item in JsonPick.list(payload, 'results')) {
          if (item is! Map) continue;
          final String cover =
              ItunesSource.coverUrl(JsonPick.str(item, 'artworkUrl100'));
          if (cover.isEmpty) continue;
          out.add(_AlbumPick(
            cover,
            'itunes',
            JsonPick.str(item, 'collectionName'),
            JsonPick.str(item, 'artistName'),
          ));
        }
        return out;
      },
    );

    // ⑤ 多家结果做对比：取与本地专辑名 / 艺人最像的那张。
    _AlbumPick? best;
    double bestScore = 0;
    for (final _AlbumPick p in picks) {
      final double s = _score(album, artist, p.album, p.artist);
      if (s > bestScore) {
        bestScore = s;
        best = p;
      }
    }
    if (best != null && bestScore >= acceptScore) {
      cache?.remember(album, artist, best.url);
      return AlbumCoverLookup(best.url, best.source);
    }

    // 一家都没正常应答（全不可用 / 全断网）→ 暂时性失败，**不写负缓存**。
    if (answered == 0) {
      return tried == 0 ? const AlbumCoverLookup('', '') : _temp();
    }
    // 部分源没应答：结论不完整，返回「没找到」但不缓存。
    if (answered < tried) return const AlbumCoverLookup('', '');
    cache?.remember(album, artist, '');
    return const AlbumCoverLookup('', '');
  }

  /// 专辑查询涉及的主机，冷却剩余秒数的最大值（0 = 没在冷却）。
  ///
  /// 封面页据此决定「补跑前要等多久」，不必写死 90 秒。
  static int cooldownSecondsLeft() => Http.maxCooldownSeconds(<String>[
        Endpoints.urlOf('netease', 1),
        Endpoints.urlOf('kugou', 1),
        Endpoints.urlOf('deezer', 1),
        Endpoints.urlOf('itunes', 0),
      ]);

  /// 与本地专辑的相似度；明显不像的返回 0（等同淘汰）。
  static double _score(
      String album, String artist, String candAlbum, String candArtist) {
    if (candAlbum.trim().isEmpty) return 0;
    final double t = TextUtil.textSimilarity(album, candAlbum);
    if (t < 0.55) return 0;
    final double a = (artist.isEmpty || candArtist.trim().isEmpty)
        ? 0.55 // 缺一方：不当作反证，也不给满分
        : TextUtil.bestArtistSimilarity(artist, candArtist);
    if (a < 0.45) return 0;
    return 0.65 * t + 0.35 * a;
  }

  /// 网易云专辑图：统一 https 并要 800×800。
  static String _neteasePic(String pic) {
    String u = pic.trim();
    if (u.startsWith('//')) u = 'https:$u';
    if (u.startsWith('http://')) u = 'https://${u.substring(7)}';
    return '$u${u.contains('?') ? '&' : '?'}param=800y800';
  }

  /// 酷狗专辑图：`{size}` 换成 500，并升 https。
  static String _kugouImg(String img) {
    String u = img.trim().replaceAll('{size}', '500');
    if (u.startsWith('//')) u = 'https:$u';
    if (u.startsWith('http://')) u = 'https://${u.substring(7)}';
    return u;
  }

  /// `[{'name':'A'},{'name':'B'}]` → `A`（专辑的主艺人）。
  static String _firstArtist(List<dynamic> artists) {
    for (final dynamic e in artists) {
      final String name = JsonPick.str(e, 'name');
      if (name.isNotEmpty) return name;
    }
    return '';
  }

  static bool _isGeneric(String album) {
    final String n = TextUtil.normCompare(album);
    for (final String g in _genericAlbums) {
      if (n == TextUtil.normCompare(g)) return true;
    }
    return false;
  }

  static Future<Object?> _get(JsonFetcher? fetch, String url,
      Map<String, String> params, Map<String, String>? headers) {
    if (fetch != null) return fetch(url, params);
    return Http.getJson(url, params, headers, Http.readTimeoutOverseasMs);
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
}
