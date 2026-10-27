/// 批量标签 feature。
///
/// - `batch_edit.dart`：批量改标签 —— 给多首统一设字段（专辑 / 流派 / 年份…），
///   可重排音轨号；先逐首预览「旧值 → 新值」，确认后才写盘。
///
/// 批量「联网匹配」走曲库页的「匹配标签」（见 `core/task/match_runner.dart`
/// 与 `core/match/tag_plan.dart` 的三态策略），不在这个目录里。
library;

export 'batch_edit.dart';
