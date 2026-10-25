/// MusicBrainz 客户端 —— 移植自旧 net/MbClient.java。
///
/// 只做一件事：按「歌名 + 歌手」查录音，返回抹平后的命中（title/artist/album/date/score）。
/// 三条纪律：
/// 1. **1s 一票**：MusicBrainz 对匿名请求有严格限速，超了会被封一段时间；
/// 2. **结果缓存**：同一首歌在多文件批量里会被反复问，缓存掉重复请求；
/// 3. **离线锁**：连续失败 3 次就当这个源不可用，成功一次立即解锁
///    （以前只清计数不清锁，网络抖三次就把整场会话的查询永久关掉，且日志看不出来）。
library;

import '../match/text_util.dart';
import '../net/http_client.dart';
import '../net/ticket_limiter.dart';
import 'endpoints.dart';
import 'tag_source.dart';

/// 一条录音命中。
class MbRecording {
  String title = '';
  String artist = '';
  String album = '';
  String date = '';

  /// MusicBrainz 自己的相关度（0~100）。
  int score = 0;
}

/// MusicBrainz 查询客户端。
class MbClient {
  /// 匿名请求的最小间隔。
  static const int minIntervalMs = 1050;

  static const int timeoutMs = 12000;

  static const int cacheLimit = 512;

  /// 连续失败几次后判定离线。
  static const int offlineAfterErrors = 3;

  /// 判定离线后的冷却时长；冷却结束后允许再探一次，成功即解锁。
  ///
  /// 为什么不「一旦离线就锁死整场会话」：网络抖三次（比如刚开代理、切 Wi-Fi）
  /// 就把 MusicBrainz 永久关掉，用户根本看不出原因。冷却后可恢复，
  /// 请求频率仍由票约控制在 1s 一发，不会打爆对方。
  MbClient({this.offlineCooldown = const Duration(seconds: 60)});

  /// 离线冷却时长。
  final Duration offlineCooldown;

  final TicketLimiter _limiter =
      TicketLimiter(interval: const Duration(milliseconds: minIntervalMs));

  final Map<String, List<MbRecording>> _cache = <String, List<MbRecording>>{};

  int _consecutiveErrors = 0;
  DateTime? _offlineUntil;

  /// 是否处于离线冷却中（连续失败多次后暂时不再发请求）。
  bool isOffline() {
    final DateTime? until = _offlineUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  /// 测试用：重置状态。
  void reset() {
    _offlineUntil = null;
    _consecutiveErrors = 0;
    _cache.clear();
  }

  /// 查录音；查不到返回空列表。
  Future<List<MbRecording>> searchRecordings(String title, String? expectedArtist,
      {int limit = 8, JsonFetcher? fetch}) async {
    if (isOffline() || title.trim().isEmpty || limit <= 0) return <MbRecording>[];
    final int n = limit.clamp(1, 20);
    final String key = _key(title, expectedArtist, n);
    final List<MbRecording>? cached = _cache[key];
    if (cached != null) return List<MbRecording>.of(cached);

    await _limiter.acquire();
    final StringBuffer query = StringBuffer('recording:"${luceneEscape(title.trim())}"');
    if (expectedArtist != null && expectedArtist.trim().isNotEmpty) {
      query.write(' AND artist:"${luceneEscape(expectedArtist.trim())}"');
    }
    final JsonFetcher get = fetch ??
        (String url, Map<String, String>? params) =>
            Http.getJson(url, params, null, timeoutMs);
    final Object? payload = await get(Endpoints.urlOf('musicbrainz', 0),
        <String, String>{'query': query.toString(), 'fmt': 'json', 'limit': '$n'});

    if (payload is! Map) {
      if (++_consecutiveErrors >= offlineAfterErrors) {
        _offlineUntil = DateTime.now().add(offlineCooldown);
      }
      return <MbRecording>[];
    }
    _consecutiveErrors = 0;
    _offlineUntil = null;

    final List<MbRecording> out = <MbRecording>[];
    for (final dynamic item in JsonPick.list(payload, 'recordings')) {
      if (out.length >= 20) break;
      final MbRecording? r = parseRecording(item);
      if (r != null) out.add(r);
    }
    if (_cache.length > cacheLimit) _cache.clear();
    _cache[key] = List<MbRecording>.of(out);
    return out;
  }

  /// 解析一条录音；标题或艺人为空视为无效（歌名不能被当成歌手）。
  static MbRecording? parseRecording(Object? node) {
    if (node is! Map) return null;
    final String title = JsonPick.str(node, 'title').trim();
    final String artist = joinArtistCredit(node).trim();
    if (title.isEmpty || artist.isEmpty) return null;

    final MbRecording r = MbRecording()
      ..title = title
      ..artist = artist
      ..date = JsonPick.str(node, 'first-release-date');
    final List<dynamic> releases = JsonPick.list(node, 'releases');
    if (releases.isNotEmpty && releases[0] is Map) {
      final Map<dynamic, dynamic> r0 = releases[0] as Map<dynamic, dynamic>;
      r.album = JsonPick.str(r0, 'title');
      if (r.date.isEmpty) r.date = JsonPick.str(r0, 'date');
    }
    final String score = JsonPick.str(node, 'score');
    r.score = int.tryParse(score) ?? 0;
    return r;
  }

  /// 从 artist-credit 拼歌手名（含 joinphrase），缺失时用 name 兜底。
  static String joinArtistCredit(Object? node) {
    if (node is! Map) return '';
    final List<dynamic> credits = JsonPick.list(node, 'artist-credit');
    if (credits.isEmpty) return '';
    final StringBuffer sb = StringBuffer();
    final List<String> names = <String>[];
    for (final dynamic item in credits) {
      if (item is! Map) continue;
      String name = JsonPick.str(item, 'name');
      if (name.isEmpty) name = JsonPick.str(JsonPick.map(item, 'artist'), 'name');
      if (name.isEmpty) continue;
      names.add(name);
      sb.write(name);
      sb.write(JsonPick.str(item, 'joinphrase'));
    }
    if (sb.isEmpty && names.isNotEmpty) return names.join(' & ');
    return sb.toString().trim();
  }

  /// Lucene 特殊字符转义（查询串里这些字符有语法含义）。
  static String luceneEscape(String text) =>
      text.replaceAllMapped(RegExp(r'([+\-!(){}\[\]^"~*?:\\/])'), (Match m) => '\\\\${m[1]}');

  static String _key(String title, String? artist, int limit) =>
      '${TextUtil.normCompare(title)}|${TextUtil.normCompare(artist)}|$limit';
}
