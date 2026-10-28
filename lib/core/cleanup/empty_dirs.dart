/// 空文件夹清理：递归找出「整棵子树里一个文件都没有」的目录，预览后删除。
///
/// 为什么按「子树没有文件」而不是「当前是空目录」：删掉一批空目录后，父目录
/// 往往也跟着空了。只删当前空的，用户得点第二次、第三次。这里一次算到底，
/// 保证「预览里列出多少个，执行就删多少个」。
///
/// 两条保护：
/// 1. 曲库根目录本身不删；
/// 2. 根目录下的「未识别」占位目录不删（整理时不认识歌手的曲子会落在这里，
///    删了下次又建一遍，白白多一轮扫描）。
library;

import '../fs/file_store.dart';
import '../match/text_util.dart';
import '../model/cancel_token.dart';
import '../model/vfile.dart';

/// 一个可删的空目录。
class EmptyDir {
  EmptyDir({required this.dir, required this.depth, required this.relPath});

  /// 目录对象（[VFile.dir] 为 true）。
  final VFile dir;

  /// 相对曲库根的层级，1 = 根的直接子目录。
  final int depth;

  /// 相对曲库根的路径，界面直接显示。
  final String relPath;
}

/// 一次扫描的结果。
class EmptyDirPlan {
  /// 可删的空目录（按层级从深到浅，删除顺序即此顺序）。
  final List<EmptyDir> empty = <EmptyDir>[];

  /// 受保护的目录（根目录下的「未识别」），只用于界面提示。
  final List<String> protectedDirs = <String>[];

  /// 扫过的目录数（含不空的）。
  int scannedDirs = 0;

  /// 因为取消而没扫完。
  bool cancelled = false;

  int get count => empty.length;
}

/// 单个目录的处理结果。
enum _Outcome { removed, notEmpty, failed }

/// 删除结果。
class EmptyDeleteResult {
  /// 确认删掉的个数（删完复查过，确实不在了）。
  int removed = 0;

  /// 扫描后又有文件进来的（按设计保留）。
  int skipped = 0;

  /// 系统拒绝 / 没删掉的。
  int failed = 0;

  String summary() => '已删除 $removed 个空文件夹'
      '${skipped > 0 ? '，$skipped 个里面又有文件（保留）' : ''}'
      '${failed > 0 ? '，$failed 个没删掉' : ''}';
}

/// 空目录扫描与删除。
abstract final class EmptyDirs {
  /// 目录数上限：防御异常深的树或链接环（SAF 下已按 docId 去过重，这里是兜底）。
  static const int maxScannedDirs = 20000;

  /// 扫一遍，找出所有「子树里没有文件」的目录。
  static Future<EmptyDirPlan> plan(
    FileStore store,
    VFile root, {
    CancelToken? cancel,
    void Function(int scanned)? onProgress,
  }) async {
    final EmptyDirPlan out = EmptyDirPlan();
    // 桌面 docId 是反斜杠路径（`C:////Users////...`），安卓是 `primary:Music/...`：
    // 统一成正斜杠再比前缀，否则桌面上算出来的相对路径会退化成「只有目录名」。
    final String rootId = root.docId.replaceAll('\\', '/');
    final String rootPrefix = rootId.endsWith('/') ? rootId : '$rootId/';
    final String unrecognized = TextUtil.unrecognizedDir.toLowerCase();

    /// 返回这棵子树里有没有文件。
    Future<bool> walk(VFile dir, int depth) async {
      if (cancel?.isCancelled() ?? false) {
        out.cancelled = true;
        return true; // 当作「有文件」，取消时绝不能继续往下判空
      }
      if (out.scannedDirs >= maxScannedDirs) return true;
      List<VFile> kids;
      try {
        kids = await store.children(dir);
      } catch (_) {
        return true; // 读不了就当有内容，别删
      }
      out.scannedDirs++;
      if (onProgress != null && out.scannedDirs % 200 == 0) {
        onProgress(out.scannedDirs);
      }
      bool hasFile = false;
      for (final VFile k in kids) {
        if (!k.dir) {
          hasFile = true;
          continue;
        }
        if (await walk(k, depth + 1)) hasFile = true;
      }
      if (!hasFile && depth > 0) {
        final bool isProtected = depth == 1 && dir.name.toLowerCase() == unrecognized;
        if (isProtected) {
          out.protectedDirs.add(_rel(dir, rootPrefix));
        } else {
          out.empty.add(EmptyDir(
              dir: dir, depth: depth, relPath: _rel(dir, rootPrefix)));
        }
      }
      return hasFile;
    }

    await walk(root, 0);
    // 深的先删：父目录等子目录删完才可能变空（虽然这里已按子树判定，
    // 但删除顺序仍按深度降序，失败时上层目录不会被误删）
    out.empty.sort((EmptyDir a, EmptyDir b) {
      final int d = b.depth.compareTo(a.depth);
      return d != 0 ? d : a.relPath.compareTo(b.relPath);
    });
    return out;
  }

  /// 删除计划里的目录（会再确认一遍「确实空了」，删完再复查一次）。
  ///
  /// 为什么要复查：安卓 SAF 上 `DocumentsContract.deleteDocument` 偶尔会
  /// 返回 true 但目录还在（列表缓存 / 延迟提交）。老代码直接按返回值计数，
  /// 界面上就会出现「提示已清理，实际一个没少」。这里以 `stat` 复核为准。
  static Future<EmptyDeleteResult> delete(
    FileStore store,
    List<EmptyDir> dirs, {
    CancelToken? cancel,
    void Function(int done, int total)? onProgress,
  }) async {
    final EmptyDeleteResult result = EmptyDeleteResult();
    int done = 0;
    for (final EmptyDir e in dirs) {
      if (cancel?.isCancelled() ?? false) break;
      done++;
      onProgress?.call(done, dirs.length);
      final _Outcome out = await _deleteOne(store, e.dir);
      switch (out) {
        case _Outcome.removed:
          result.removed++;
        case _Outcome.notEmpty:
          result.skipped++;
        case _Outcome.failed:
          result.failed++;
      }
    }
    return result;
  }

  /// 单个目录：确认空 → 删 → 复查；失败重试一次（给 SAF 一点时间）。
  static Future<_Outcome> _deleteOne(FileStore store, VFile dir) async {
    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        final List<VFile> kids = await store.children(dir);
        if (kids.isNotEmpty) return _Outcome.notEmpty;
      } catch (_) {
        return _Outcome.failed;
      }
      try {
        await store.delete(dir);
      } catch (_) {
        // 继续走下面的复核：有的实现抛异常但其实删掉了
      }
      try {
        final VFile? after = await store.stat(dir.docId);
        if (after == null) return _Outcome.removed;
      } catch (_) {
        // stat 失败（不属于任何树 / 通道异常）按没删掉处理，别谎报
      }
      if (attempt == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }
    return _Outcome.failed;
  }

  static String _rel(VFile dir, String rootPrefix) {
    final String id = dir.docId.replaceAll('\\', '/');
    if (id.startsWith(rootPrefix)) return id.substring(rootPrefix.length);
    // 抓不到前缀（不属于这棵树 / 卷前缀不同）时退回目录名，至少还能显示
    return dir.name;
  }
}
