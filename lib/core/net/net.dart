/// 网络并发编排 —— 移植自旧 net/Net.java（Dart 单线程 async 版）。
///
/// - [map] / [mapIndexed]：文件级并发（默认 3，可调 1-5），结果按输入顺序返回；
/// - [gather]：源级并发，Future.wait + 总预算 timeout（默认 12s 随倍率缩放）。
///
/// **两级不共用池（防死锁）**：文件级 worker 用信号量限流，源级任务各自独立
/// Future，避免文件 worker 占满后等子任务导致死锁。
library;

import 'dart:async';
import 'dart:math';

import '../model/cancel_token.dart';
import 'net_tuning.dart';

/// 单元素处理任务（不关心序号）。
typedef Work<T, R> = Future<R> Function(T item);

/// 单元素处理任务，携带元素在输入列表中的原始序号。
typedef IndexedWork<T, R> = Future<R> Function(int index, T item);

/// 网络并发编排（纯 Dart）。
abstract final class Net {
  /// IO 池线程数（源级并发上限，留余量）。
  static const int ioThreads = 8;

  /// 文件级并发的默认值（实际生效值见 [fileConcurrency]）。
  static const int fileConcurrencyDefault = 3;

  /// 本地文件批量预读并发度。
  static const int readThreads = 4;

  /// 单个文件的源级总预算（毫秒）。
  static const int sourceBudgetMs = 12000;

  /// 当前生效的文件级并发（设置页可调）。
  static int fileConcurrency() => NetTuning.fileConcurrency();

  /// 当前生效的单源总预算（随超时倍率缩放）。
  static int sourceBudget() => NetTuning.scale(sourceBudgetMs);

  /// 有序并发处理：结果与 [items] 一一对应，未处理（被取消）的位置为 null。
  static Future<List<R?>> map<T, R>(List<T> items, int threads,
      CancelToken? cancel, Work<T, R> work) {
    return mapIndexed<T, R>(items, threads, cancel,
        (int index, T item) => work(item));
  }

  /// 与 [map] 相同，但 worker 能拿到元素序号。
  static Future<List<R?>> mapIndexed<T, R>(List<T> items, int threads,
      CancelToken? cancel, IndexedWork<T, R> work) async {
    final int size = items.length;
    final List<R?> out = List<R?>.filled(size, null);
    if (size == 0) return out;
    final int poolSize = max(1, min(threads, size));
    final _Semaphore sem = _Semaphore(poolSize);
    final List<Future<void>> jobs = <Future<void>>[];
    for (int i = 0; i < size; i++) {
      final int idx = i;
      jobs.add(sem.acquire().then((_) async {
        try {
          if (cancel == null || !cancel.isCancelledNow()) {
            out[idx] = await work(idx, items[idx]);
          }
        } catch (_) {
          out[idx] = null; // 单首失败不影响其它文件
        } finally {
          sem.release();
        }
      }));
    }
    await Future.wait(jobs);
    return out;
  }

  /// 并发跑一批任务，按完成顺序收集；总预算用尽或用户取消时立即返回已完成部分。
  ///
  /// 预算到点后未完成的任务会被放弃（其 Future 仍会在后台自行结束）；
  /// 生产调用方通过底层 HttpClient 超时兜底。
  static Future<List<T>> gather<T>(List<Future<T> Function()> tasks,
      int budgetMs, CancelToken? cancel) async {
    final List<T> out = <T>[];
    if (tasks.isEmpty) return out;
    final int total = tasks.length;
    final Completer<void> done = Completer<void>();
    int remaining = total;

    Future<void> run(int i) async {
      try {
        final T v = await tasks[i]();
        out.add(v);
      } catch (_) {
        // 单源异常只是少一个结果
      } finally {
        remaining--;
        if (remaining == 0 && !done.isCompleted) done.complete();
      }
    }

    for (int i = 0; i < total; i++) {
      unawaited(run(i));
    }

    final int deadlineMs = DateTime.now().millisecondsSinceEpoch +
        (budgetMs < 500 ? 500 : budgetMs);
    while (!done.isCompleted) {
      if (cancel != null && cancel.isCancelledNow()) break;
      if (DateTime.now().millisecondsSinceEpoch >= deadlineMs) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return out;
  }
}

class _Semaphore {
  _Semaphore(this._permits);

  int _permits;
  final List<Completer<void>> _waiters = <Completer<void>>[];

  Future<void> acquire() {
    if (_permits > 0) {
      _permits--;
      return Future<void>.value();
    }
    final Completer<void> c = Completer<void>();
    _waiters.add(c);
    return c.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else {
      _permits++;
    }
  }
}
