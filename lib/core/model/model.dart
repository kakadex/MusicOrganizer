/// 模型层（T04 落位）：不可变值对象 + copyWith。
///
/// - `vfile.dart`：VFile（id / parentId / name / size / mtime / isDir；
///   缓存 tags? / hasCover / hasLyrics / durationMs / bitrateKbps；写盘后 clearMeta）；
/// - `tags.dart`：Tags（const KEYS + Map；year 截断 4 位）；
/// - `track_group.dart` / `lyric_doc.dart` / `journal_entry.dart` /
///   `candidate.dart` / `tag_fill.dart`（含 FillMode enum）/
///   `task_control.dart` / `partial_sink.dart` / `health_item.dart` /
///   `duplicate_group.dart` / `query.dart`。
library;
