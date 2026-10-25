/// 任务中心 —— 移植自旧 core/TaskCenter.java（同时只允许一个任务在跑）。
///
/// Dart 单线程：任务就是一个 `Future`，「并发」靠 `Net.map` 的文件级 / 源级并发，
/// 任务中心只负责**状态与生命周期**，不负责排队执行。
///
/// 三条纪律：
/// 1. 同一时间只允许一个任务（新任务来了先拒，界面上直接提示）；
/// 2. worker 每处理一首必须过一次 `isCancelled()` 检查点；
/// 3. 暂停时把已完成的部分交给 [PartialSink]，界面可以「预览已获取的部分」。
library;

import '../model/cancel_token.dart';
import '../model/partial_sink.dart';
import '../model/task_control.dart';

/// 一个运行中的任务。
class RunningTask {
  RunningTask(this.title, this.control, {this.partial});

  final String title;
  final TaskControl control;

  /// 部分结果缓冲区（支持「暂停时先看已获取的部分」）。
  final PartialSink<Object>? partial;
}

/// 全局任务中心（单例式静态状态，界面与业务都能访问）。
abstract final class TaskCenter {
  static RunningTask? _current;

  /// 启动一个任务；已有任务在跑返回 null（不排队、不覆盖）。
  static RunningTask? start(String title, {PartialSink<Object>? partial}) {
    if (_current != null) return null;
    final TaskControl control = TaskControl();
    _current = RunningTask(title, control, partial: partial);
    return _current;
  }

  /// 当前任务；没有返回 null。
  static RunningTask? current() => _current;

  /// 当前任务的控制器（没有返回 null）。
  static TaskControl? control() => _current?.control;

  /// 是否正在跑任务。
  static bool isBusy() => _current != null;

  /// 取消当前任务（异步生效：worker 在检查点退出）。
  static void cancel() => _current?.control.cancel();

  /// 暂停 / 继续。
  static void togglePause() => _current?.control.togglePause();

  /// 任务结束（无论成功失败都要调用，否则下一个任务起不来）。
  static void finish() {
    final RunningTask? t = _current;
    if (t == null) return;
    t.control.finish();
    _current = null;
  }

  /// 部分结果快照（没有返回 null）。
  static List<Object>? partialSnapshot() => _current?.partial?.snapshot();

  /// 已获取的部分结果条数。
  static int partialCount() => _current?.partial?.size() ?? 0;

  /// worker 的取消检查点；没有任务时视为「未取消」。
  static bool cancelled(CancelToken? token) => token?.isCancelled() ?? false;

  /// 测试用：强制复位。
  static void reset() => _current = null;
}
