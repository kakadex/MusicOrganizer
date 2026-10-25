/// 取消令牌（对应 Python threading.Event）—— 纯 Dart。
///
/// Dart 单线程下「暂停阻塞检查点」的语义由业务循环协作完成（见 task_control.dart），
/// 这里只定义查询接口。
abstract class CancelToken {
  /// 检查点：返回是否已取消。
  bool isCancelled();

  /// 不阻塞的取消状态查询（调度线程用，避免被暂停检查点卡住）。
  bool isCancelledNow() => isCancelled();
}
