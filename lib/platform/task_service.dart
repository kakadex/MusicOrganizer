/// 平台侧任务通知（安卓前台服务）。
///
/// 长任务跑起来时挂一条常驻通知，把进程标成「前台」，退到后台才不会被系统回收；
/// 任务结束立刻撤掉。桌面与不支持的平台上是空操作。
library;

import 'dart:async';

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
    TaskCenter.onFinish = () => unawaited(_finishAndVerify());
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

  /// 前台服务当前状态：RUNNING（已进前台）/ STARTING（服务在，还没进前台）/ STOPPED。
  ///
  /// 桌面与测试环境没有这个通道，一律按 STOPPED 处理。
  static Future<String> state() async {
    if (kIsWeb) return 'STOPPED';
    try {
      final Object? r = await _ch.invokeMethod<Object?>('serviceState');
      return r is String ? r : 'STOPPED';
    } on MissingPluginException {
      return 'STOPPED';
    } on PlatformException {
      return 'STOPPED';
    }
  }

  /// 等前台服务真正退出（最多 [timeout]）。
  static Future<bool> awaitStopped({
    Duration timeout = const Duration(milliseconds: 800),
  }) async {
    final int deadline =
        DateTime.now().millisecondsSinceEpoch + timeout.inMilliseconds;
    while (DateTime.now().millisecondsSinceEpoch < deadline) {
      if (await state() == 'STOPPED') return true;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return await state() == 'STOPPED';
  }

  /// 任务收尾：先请服务停，再确认它真的退了。
  ///
  /// 停止请求是异步投递的，任务结束时若服务还没退干净，通知会残留到下一次
  /// 任务开始。这里补一次停止，把「发后即忘」变成「发后确认」。
  static Future<void> _finishAndVerify() async {
    await stop();
    if (await awaitStopped()) return;
    await stop();
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
