/// 文件系统抽象层（T03/T08 落位）。
///
/// - `file_store.dart`：FileStore 抽象契约（架构设计 §2.2，安卓 SAF /
///   桌面 dart:io 双实现的共同父类）；
/// - `tree_lookup.dart`：多根 docId 前缀分派（等价旧 Storage.TreeLookup）；
/// - `desktop_file_store.dart`：dart:io 直读写实现；
/// - `saf_file_store.dart`：DocumentsContract MethodChannel 实现。
library;
