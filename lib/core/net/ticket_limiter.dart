/// 票约限流器 —— 设计 §4「TicketLimiter 票约」（MusicBrainz 1s 票约）。
///
/// 语义：锁内预约「下一次允许发车的时间」，锁外 sleep 到那个时间。
/// 并发调用各自拿到不同的发车时刻，互不重叠。纯 Dart。
library;

/// 保证同一资源最小发车间隔的限流器。
class TicketLimiter {
  TicketLimiter({this.interval = const Duration(seconds: 1)});

  /// 最小发车间隔。
  final Duration interval;

  DateTime _next = DateTime.fromMillisecondsSinceEpoch(0);

  /// 预约下一次发车，返回还需等待的时长（不阻塞；锁内调用）。
  Duration reserve() {
    final DateTime now = DateTime.now();
    final DateTime departure = _next.isAfter(now) ? _next : now;
    _next = departure.add(interval);
    return departure.difference(now);
  }

  /// 预约并等待到发车时刻（锁外 sleep）。
  Future<void> acquire() async {
    final Duration wait = reserve();
    if (wait > Duration.zero) {
      await Future<void>.delayed(wait);
    }
  }
}
