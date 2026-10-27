/// 文件名清理与改名：先出计划，用户确认后才动盘。
///
/// 两种改名：
/// - [planCleanup]：按清理规则改（去广告前缀、轨道前缀、污染后缀、
///   重编码标记，含中文再去空格）；
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
  /// 清理规则：去广告前缀 + 轨道前缀 + 污染后缀 + 重编码标记；
  /// 含中文再去掉全部空格。详见 [TextUtil.normalizeStemForCleanup]。
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

/// 一条「扁平化」计划：把子目录里的文件搬到根目录。
class FlattenPlan {
  FlattenPlan({
    required this.source,
    required this.targetName,
    required this.fromDir,
    this.conflict = false,
  });

  final VFile source;

  /// 搬到根目录后的名字（与根目录已有文件撞名时加 `_2` / `_3`）。
  final String targetName;

  /// 源文件所在目录（相对根目录，预览用）。
  final String fromDir;

  /// 目标名字仍撞车（极端情况），默认不执行。
  final bool conflict;

  bool get renamed => targetName != source.name;
}

/// 扁平化执行结果。
class FlattenResult {
  int moved = 0;
  int failed = 0;
  int removedDirs = 0;
  final List<String> errors = <String>[];

  String summary() => '移动 $moved 个 · 删空目录 $removedDirs 个'
      '${failed > 0 ? ' · 失败 $failed 个' : ''}';
}

/// 扁平化文件夹：把所有嵌套子目录里的音频搬到根目录这一层。
///
/// 只出计划不动盘；撞名时在基本名后加 `_2`、`_3`…，保证不覆盖任何文件。
abstract final class Flattener {
  /// 生成计划（纯计算）。
  ///
  /// [rootDocId] 是目标目录（通常是曲库根）；[files] 是它下面的全部文件
  /// （含子目录里的）。已经在根目录的文件跳过。
  static List<FlattenPlan> plan(List<VFile> files, {required String rootDocId}) {
    final Set<String> taken = <String>{};
    for (final VFile f in files) {
      if (f.dir) continue;
      if ((f.parentId ?? '') == rootDocId) taken.add(f.name.toLowerCase());
    }
    final List<FlattenPlan> out = <FlattenPlan>[];
    for (final VFile f in files) {
      if (f.dir || !f.music()) continue;
      if ((f.parentId ?? '') == rootDocId) continue; // 已在根目录
      String name = f.name;
      if (taken.contains(name.toLowerCase())) name = _unique(name, taken);
      taken.add(name.toLowerCase());
      final String path = _relDir(f, rootDocId);
      out.add(FlattenPlan(source: f, targetName: name, fromDir: path));
    }
    return out;
  }

  static String _unique(String name, Set<String> taken) {
    final int dot = name.lastIndexOf('.');
    final String stem = dot > 0 ? name.substring(0, dot) : name;
    final String ext = dot > 0 ? name.substring(dot) : '';
    for (int i = 2; i < 10000; i++) {
      final String candidate = '${stem}_$i$ext';
      if (!taken.contains(candidate.toLowerCase())) return candidate;
    }
    return '${stem}_${DateTime.now().millisecondsSinceEpoch}$ext';
  }

  static String _relDir(VFile f, String rootDocId) {
    final String id = f.docId;
    final String prefix = rootDocId.endsWith('/') ? rootDocId : '$rootDocId/';
    String rel = id.startsWith(prefix) ? id.substring(prefix.length) : id;
    // docId 末尾是文件名：去掉最后一段剩下的就是目录
    final int slash = rel.lastIndexOf('/');
    rel = slash > 0 ? rel.substring(0, slash) : '';
    // 安卓 SAF 的 docId 形如 `primary:Music/A/B/file.mp3`，把卷前缀也去掉
    final int colon = rel.indexOf(':');
    return colon >= 0 ? rel.substring(colon + 1) : rel;
  }

  /// 执行计划：改名（需要时）→ 移动到根目录 → 删掉空出来的子目录。
  static Future<FlattenResult> execute(
    FileStore st, {
    required VFile root,
    required List<FlattenPlan> plans,
    void Function(int done, int total)? onProgress,
  }) async {
    final FlattenResult r = FlattenResult();
    int done = 0;
    final Set<String> touchedDirs = <String>{};
    for (final FlattenPlan p in plans) {
      done++;
      onProgress?.call(done, plans.length);
      try {
        // 先在原地改名，再用「改名后的新位置」移动。VFile 的身份字段不可变，
        // rename 之后 p.source 的 docId/name 已经失效，还拿它去 move 会在
        // 旧路径上找不到文件 —— 「改名过的文件全部报失败」就是这个根因。
        VFile src = p.source;
        if (p.renamed) {
          final bool ok = await st.rename(src, p.targetName);
          if (!ok) {
            r.failed++;
            r.errors.add('${p.source.name}：改名失败');
            continue;
          }
          final String parent = src.parentId ?? _dirOf(src.docId);
          src = src.copyWith(
              docId: '$parent/${p.targetName}', name: p.targetName);
        }
        final String? err = await st.move(src, root);
        if (err != null) {
          r.failed++;
          r.errors.add('${p.source.name}：$err');
          continue;
        }
        r.moved++;
        if (p.source.parentId != null) touchedDirs.add(p.source.parentId!);
      } catch (e) {
        r.failed++;
        r.errors.add('${p.source.name}：$e');
      }
    }
    // 清掉搬空的目录：从直接父目录沿父链一路向上，直到根目录或遇到非空目录。
    // 之前只删直接父目录，中间层（B 搬空后剩下的 A）会一直留在盘上。
    final String rootPrefix =
        root.docId.endsWith('/') ? root.docId : '${root.docId}/';
    for (final String startId in touchedDirs) {
      String cur = startId;
      while (cur.isNotEmpty && cur.startsWith(rootPrefix)) {
        try {
          final VFile dir = VFile(docId: cur, name: _base(cur), dir: true);
          final List<VFile> kids = await st.children(dir);
          if (kids.isNotEmpty) break;
          if (!await st.delete(dir)) break;
          r.removedDirs++;
          cur = _dirOf(cur);
        } catch (_) {
          // 删不掉不影响结果
          break;
        }
      }
    }
    return r;
  }

  /// docId 的上一级（两级实现都按「/」分段的 docId 走）。
  static String _dirOf(String docId) {
    final int slash = docId.lastIndexOf('/');
    return slash <= 0 ? docId : docId.substring(0, slash);
  }

  /// docId 的最后一段（目录名 / 文件名）。
  static String _base(String path) {
    final int slash = path.lastIndexOf('/');
    return slash < 0 ? path : path.substring(slash + 1);
  }
}
