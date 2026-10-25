/// 在线歌词源的统一契约（T10b）—— 参照旧 net/LyricSources.java 的各家实现。
///
/// 与 [TagSource] 同构：一个源一个实现，注册表统一登记，聚合流程只跟契约打交道。
/// 各源字段形状不同（有的带译文轨、有的有逐字 KRC），在这个契约里抹平成 [LyricHit]。
library;

import '../model/lyric_hit.dart';
import 'tag_source.dart';

/// 取原始文本的回调（有的源返回 JSON，有的返回 JSONP / 纯文本）。
typedef TextFetcher = Future<String?> Function(
    String url, Map<String, String>? params);

/// 一次歌词查询。
class LyricQuery {
  LyricQuery({this.title = '', this.artist = '', this.album = '', this.duration});

  final String title;
  final String artist;
  final String album;

  /// 本地时长（秒）；读不到为 null。
  final double? duration;
}

/// 一个在线歌词源。
abstract class LyricSource {
  /// 与 `Endpoints` 里登记的 key 一致（如 `lyric_netease`）。
  String get key;

  /// 界面显示名。
  String get label;

  /// 按查询取歌词；取不到返回空列表（不允许返回 null）。
  Future<List<LyricHit>> search(LyricQuery q,
      {TextFetcher? text, JsonFetcher? json});
}

/// 从 [LyricQuery] 造命中对象时共用的填充工具。
abstract final class LyricPick {
  static LyricHit hit(
    String source, {
    String title = '',
    String artist = '',
    double? duration,
    String synced = '',
    String plain = '',
    String translation = '',
  }) {
    final LyricHit h = LyricHit()
      ..source = source
      ..title = title
      ..artist = artist
      ..duration = duration
      ..synced = synced
      ..plain = plain
      ..translation = translation;
    return h;
  }

  /// 时长差（秒）；任一方读不到返回 null。
  static double? durationDiff(double? a, double? b) {
    if (a == null || b == null) return null;
    return (a - b).abs();
  }
}
