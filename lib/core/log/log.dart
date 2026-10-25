/// 日志层（T07 起随事务落地）。
///
/// - `mo_log.dart`：分级日志 + 滚动文件（appSupportDir/logs）；
/// - 关键约束：**日志与提交信息不得含本机路径 / 身份 / 凭据**。
library;
