/// 增量扫描（把上次的标签缓存接力到这次扫描结果）。
///
/// 判定：同一 docId 且 size 与 lastModified 都没变，就沿用上次标签；变了当作新文件重读。
library;

import '../model/vfile.dart';

/// 合并结果。
class ScanMergeResult {
  ScanMergeResult({
    required this.files,
    required this.reused,
    required this.fresh,
    required this.removed,
  });

  /// 本次扫描出的文件（音频对象的缓存字段已被就地填好）。
  final List<VFile> files;

  /// 沿用了上次标签的音频数。
  final int reused;

  /// 需要重读标签的音频数（新增或被改动）。
  final int fresh;

  /// 上次有、这次没有的音频数。
  final int removed;

  String summary() {
    final StringBuffer sb = StringBuffer('标签复用 $reused 首');
    if (fresh > 0) sb.write('，需重读 $fresh 首');
    if (removed > 0) sb.write('，已移除 $removed 首');
    return sb.toString();
  }
}

/// 增量扫描合并（纯 Dart）。
abstract final class ScanMerge {
  /// 合并；[current] 里音频对象的缓存字段会被就地写入。
  static ScanMergeResult merge(List<VFile>? previous, List<VFile>? current) {
    final List<VFile> out = <VFile>[];
    if (current != null) {
      final Set<String> ids = <String>{};
      for (final VFile f in current) {
        if (ids.add(f.docId)) out.add(f);
      }
    }
    final Map<String, VFile> before = <String, VFile>{};
    if (previous != null) {
      for (final VFile f in previous) {
        if (f.dir || !f.audio()) continue;
        before.putIfAbsent(f.docId, () => f);
      }
    }

    final Set<String> seen = <String>{};
    int reused = 0;
    int fresh = 0;
    for (final VFile f in out) {
      if (f.dir || !f.audio()) continue;
      seen.add(f.docId);
      final VFile? old = before[f.docId];
      if (old != null && _sameFile(old, f) && old.metaCached()) {
        f.cacheMeta(old.cachedTags,
            cover: old.cachedHasCover, lyrics: old.cachedHasLyrics);
        reused++;
      } else {
        f.clearMeta();
        fresh++;
      }
    }

    int removed = 0;
    for (final String docId in before.keys) {
      if (!seen.contains(docId)) removed++;
    }
    return ScanMergeResult(files: out, reused: reused, fresh: fresh, removed: removed);
  }

  static bool _sameFile(VFile a, VFile b) =>
      a.size == b.size && a.lastModified == b.lastModified;
}
