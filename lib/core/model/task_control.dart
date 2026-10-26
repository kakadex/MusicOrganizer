/// 任务控制器。
///
/// 同时承担「进度上报」与「暂停 / 取消」。
///
/// Dart 单线程下无法在检查点阻塞工作线程，因此 [isCancelled]
/// 只做非阻塞状态查询；「暂停」由业务循环协作检查 [isPaused] 实现。
library;

import 'cancel_token.dart';

/// 任务控制器（纯 Dart）。
class TaskControl implements CancelToken {
  TaskControl([String message = '']) : _message = message;

  bool _paused = false;
  bool _cancelled = false;
  bool _finished = false;

  int _done = 0;
  int _total = 0;
  String _message = '';
  final int _startedAt = DateTime.now().millisecondsSinceEpoch;
  int _finishedAt = 0;

  @override
  bool isCancelled() => _cancelled;

  @override
  bool isCancelledNow() => _cancelled;

  bool isPaused() => _paused;
  bool isFinished() => _finished;

  /// 暂停；已结束 / 已取消时无效。
  void pause() {
    if (_finished || _cancelled) return;
    _paused = true;
  }

  void resume() {
    if (!_paused) return;
    _paused = false;
  }

  void togglePause() => _paused ? resume() : pause();

  /// 请求停止：解除暂停并让检查点返回已取消。
  void cancel() {
    if (_cancelled || _finished) return;
    _cancelled = true;
    _paused = false;
  }

  /// 工作线程结束时调用。
  void finish() {
    _finished = true;
    _paused = false;
    _finishedAt = DateTime.now().millisecondsSinceEpoch;
  }

  /// 上报进度；total<=0 表示总量未知。
  void report(int done, int total, [String? message]) {
    _done = done;
    _total = total;
    if (message != null) _message = message;
  }

  int done() => _done;
  int total() => _total;
  String message() => _message;

  /// 0~100；总量未知时返回 -1。
  int percent() {
    if (_total <= 0) return -1;
    final int p = 100 * _done ~/ _total;
    if (p < 0) return 0;
    return p > 100 ? 100 : p;
  }

  int elapsedMs() {
    final int end = _finishedAt > 0
        ? _finishedAt
        : DateTime.now().millisecondsSinceEpoch;
    final int v = end - _startedAt;
    return v < 0 ? 0 : v;
  }

  /// 形如「37/120  · 周杰伦 - 七里香.mp3」。
  String summary() {
    final StringBuffer sb = StringBuffer();
    if (_total > 0) {
      sb.write('$_done/$_total  ·  ');
    } else if (_done > 0) {
      sb.write('$_done  ·  ');
    }
    sb.write(_message);
    if (_paused) sb.write('　（已暂停）');
    return sb.toString();
  }
}
