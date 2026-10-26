/// 文件名清理与改名：先出计划，用户确认后才动盘。
///
/// 两种改名：
/// - [planCleanup]：按清理规则改（去污染后缀、重编码标记、含中文去空格）；
/// - [planTemplate]：按模板改（`{artist} - {title}` 之类，用标签里的值拼）。
///
/// 两条路都先算「改成什么」，再由界面列出来（旧名 → 新名），确认后调
/// [execute] 落盘。目标名撞车一律标冲突、不覆盖。
library;

import '../fs/file_store.dart';
import '../match/text_util.dart';
import '../model/tags.dart';
import '../model/vfile.dart';
import 'name_template.dart';

/// 一条改名计划。
class RenamePlan {
  RenamePlan({
    required this.source,
    required this.newName,
    this.status = statusOk,
    this.reason = '',
  });

  /// 状态常量。
  static const String statusOk = 'ok';
  static const String statusUnchanged = 'unchanged';
  static const String statusConflict = 'conflict';

  /// 要改名的文件。
  final VFile source;

  /// 目标文件名（**含扩展名**）。
  final String newName;

  /// 状态：[statusOk] / [statusUnchanged] / [statusConflict]。
  final String status;

  /// 冲突或跳过的原因（给界面显示）。
  final String reason;

  /// 是否真的要改名。
  bool get changed => status == statusOk;

  /// 旧名 → 新名（一行说明）。
  String describe() {
    if (status == statusUnchanged) return '${source.name} → （不变）';
    return '${source.name} → $newName';
  }
}

/// 执行结果。
class CleanerResult {
  int renamed = 0;
  int conflict = 0;
  int failed = 0;

  String summary() =>
      '改名 $renamed 个 · 跳过 $conflict 个 · 失败 $failed 个';
}

/// 文件名清理与改名计划。
abstract final class Cleaner {
  /// 清理规则：去污染后缀 + 重编码标记；含中文再去掉全部空格。
  static Future<List<RenamePlan>> planCleanup(
      FileStore st, List<VFile> files) async {
    final Map<String, Set<String>> siblings =
        await _childrenIndex(st, files);
    final List<RenamePlan> plans = <RenamePlan>[];
    final Set<String> reserved = <String>{};
    for (final VFile f in files) {
      final String stem = f.stem();
      final String newStem = TextUtil.normalizeStemForCleanup(stem);
      if (newStem == stem) {
        plans.add(RenamePlan(
            source: f,
            newName: f.name,
            status: RenamePlan.statusUnchanged));
        continue;
      }
      final String target = '$newStem${f.ext()}';
      plans.add(_check(f, target, siblings, reserved));
    }
    return plans;
  }

  /// 按模板改名（用标签里的值拼文件名）。
  ///
  /// 没标签或字段全空的文件跳过 —— 拼不出名字就别改。
  static Future<List<RenamePlan>> planTemplate(
      FileStore st, List<VFile> files, String pattern) async {
    final Map<String, Set<String>> siblings =
        await _childrenIndex(st, files);
    final List<RenamePlan> plans = <RenamePlan>[];
    final Set<String> reserved = <String>{};
    for (final VFile f in files) {
      final Tags? tags = f.cachedTags;
      final String name = NameTemplate.render(
          pattern, NameTemplate.fields(tags), f.ext());
      if (name.isEmpty || name == f.name) {
        plans.add(RenamePlan(
            source: f,
            newName: f.name,
            status: RenamePlan.statusUnchanged,
            reason: tags == null ? '还没读标签' : '按模板拼不出名字'));
        continue;
      }
      plans.add(_check(f, name, siblings, reserved));
    }
    return plans;
  }

  /// 判冲突：目标名在同目录已存在，或与本批另一条撞名。
  static RenamePlan _check(VFile f, String target,
      Map<String, Set<String>> siblings, Set<String> reserved) {
    final String parent = f.parentId ?? '';
    final String key = '$parent/$target'.toLowerCase();
    final Set<String> names = siblings[parent] ?? const <String>{};
    bool exists = false;
    for (final String n in names) {
      if (n.toLowerCase() == target.toLowerCase() &&
          n.toLowerCase() != f.name.toLowerCase()) {
        exists = true;
        break;
      }
    }
    if (reserved.contains(key)) {
      return RenamePlan(
          source: f,
          newName: target,
          status: RenamePlan.statusConflict,
          reason: '目标名与本批另一文件重复');
    }
    if (exists) {
      return RenamePlan(
          source: f,
          newName: target,
          status: RenamePlan.statusConflict,
          reason: '目标文件已存在');
    }
    reserved.add(key);
    return RenamePlan(source: f, newName: target);
  }

  /// 列出相关目录的子项名（每个目录只列一次）。
  static Future<Map<String, Set<String>>> _childrenIndex(
      FileStore st, List<VFile> files) async {
    final Map<String, Set<String>> out = <String, Set<String>>{};
    final Set<String> dirs = <String>{};
    for (final VFile f in files) {
      final String parent = f.parentId ?? '';
      if (parent.isEmpty) continue;
      dirs.add(parent);
    }
    for (final String dir in dirs) {
      try {
        final List<VFile> kids =
            await st.children(VFile(docId: dir, name: _base(dir), dir: true));
        out[dir] = <String>{for (final VFile k in kids) k.name};
      } catch (_) {
        out[dir] = <String>{};
      }
    }
    return out;
  }

  static String _base(String path) {
    final int slash = path.lastIndexOf('/');
    return slash < 0 ? path : path.substring(slash + 1);
  }

  /// 执行改名计划：只改 [RenamePlan.changed] 的条目，冲突的一律跳过。
  static Future<CleanerResult> execute(
      FileStore st, List<RenamePlan> plans) async {
    final CleanerResult r = CleanerResult();
    for (final RenamePlan p in plans) {
      if (p.status == RenamePlan.statusUnchanged) {
        r.conflict++;
        continue;
      }
      if (p.status == RenamePlan.statusConflict) {
        r.conflict++;
        continue;
      }
      try {
        if (await st.rename(p.source, p.newName)) {
          r.renamed++;
        } else {
          r.failed++;
        }
      } catch (_) {
        r.failed++;
      }
    }
    return r;
  }
}
