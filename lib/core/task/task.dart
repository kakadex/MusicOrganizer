/// 任务引擎（T11 落位）：批量任务编排与取消。
///
/// - `task_center.dart`：任务注册 / 进度 / 取消广播；
/// - `task_control.dart`：isCancelled() 检查点（worker 每首必过）；
/// - `partial_sink.dart`：部分结果落盘（续跑基础）。
library;
