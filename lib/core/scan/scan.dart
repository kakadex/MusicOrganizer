/// 扫描层（T09 落位）：目录遍历 + 增量合并 + 搜索索引。
///
/// - `scanner.dart`：walkMusic（visited 去重，防 provider 重复返回）、
///   walkAll（全量遍历，深度上限 64）、readHead（标签 + 封面一次读完）；
/// - `scan_merge.dart`：docId + size + mtime 未变则接力上次 tags；
/// - `scan_stats.dart`：扫描统计（纯数据）；
/// - `search_query.dart`：搜索输入解析（词 / 字段 / 大小条件）；
/// - `search_index.dart`：内存索引（字段预先归一，查询只做 contains）。
///
/// 时长 / 码率不在这一层：它们依赖平台能力（媒体库 / 音频解码），
/// 接入时走 `platform/` 的通道，扫描层只负责存结果。
library;
