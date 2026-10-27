/// 平台侧任务通知（安卓前台服务）。
///
/// 长任务跑起来时挂一条常驻通知，把进程标成「前台」，退到后台才不会被系统回收；
/// 任务结束立刻撤掉。桌面与不支持的平台上是空操作。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/model/task_control.dart';
import '../core/task/task_center.dart';

/// 任务通知开关。
abstract final class TaskService {
  static const MethodChannel _ch = MethodChannel('com.dsh.musicorganizer/host');

  static bool _attached = false;

  /// 任务序号：每次任务开始自增，通知与停止请求都带上它。
  ///
  /// 有了它，平台侧能区分「新任务的启动」和「上一个任务迟到的停止」，
  /// 节流器也就不用再兼顾「任务边界标记」这个职责。
  static int _seq = 0;

  /// 把任务中心的生命周期接到通知栏上（main 里调一次）。
  static void attach() {
    if (_attached) return;
    _attached = true;
    TaskCenter.onStart = (String title) {
      _seq++;
      update(title, 0, 0, '');
    };
    TaskCenter.onFinish = stop;
    TaskControl.onReport = (int done, int total, String message) {
      final RunningTask? t = TaskCenter.current();
      if (t == null) return;
      update(t.title, done, total, message);
    };
  }

  /// 上次推送时间与文案：进度回调是「每首一次」，全推过去会刷爆通道。
  ///
  /// 只做频率限制——「是不是新任务」由 [_seq] 决定，不靠这里的 key。
  static int _lastMs = 0;
  static int _lastSeq = -1;
  static String _lastKey = '';

  /// 更新通知（没起服务时顺手起一个）。
  static Future<void> update(
    String title,
    int done,
    int total,
    String message,
  ) async {
    if (kIsWeb) return;
    final String key = '$_seq|$title|$done|$total';
    final int now = DateTime.now().millisecondsSinceEpoch;
    if (key == _lastKey) return;
    // 同一个任务内 300ms 只推一次；换了任务立刻推
    if (_lastSeq == _seq && now - _lastMs < 300) return;
    _lastKey = key;
    _lastSeq = _seq;
    _lastMs = now;
    try {
      await _ch.invokeMethod<void>('updateTask', <String, Object?>{
        'seq': _seq,
        'title': title,
        'text': message,
        'done': done,
        'total': total,
      });
    } on MissingPluginException {
      // 桌面 / 测试环境没有这个通道：通知栏本来也不需要
    } on PlatformException {
      // 通知权限没给：不影响任务本身
    }
  }

  /// 撤掉通知。
  static Future<void> stop() async {
    if (kIsWeb) return;
    try {
      await _ch.invokeMethod<void>('stopTask', <String, Object?>{'seq': _seq});
    } on MissingPluginException {
      // 同上
    } on PlatformException {
      // 同上
    }
  }
}
