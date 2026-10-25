/// 扫描层（T09 落位）：目录遍历 + 增量合并。
///
/// - `scanner.dart`：walkMusic（visited 去重，防 provider 重复返回）；
/// - `scan_merge.dart`：docId + size + mtime 未变则接力上次 tags；
/// - `scan_snapshot.dart`：扫描快照持久化。
library;
