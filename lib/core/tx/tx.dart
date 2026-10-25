/// 事务层（T07 落位）：标签写盘七步事务 + 日志。
///
/// - `tag_transaction.dart`：副本 → 校验 → 备份 → 写回 → 回读 → journal，
///   失败恢复；Dart 侧 async 互斥保写盘串行；
/// - `journal.dart`：appSupportDir/tag_journal.jsonl，2,000 条上限、
///   全量重写、revertBatch 逆序回滚；
/// - `journal_history.dart`：批次视图（补桌面旧缺口）。
library;
