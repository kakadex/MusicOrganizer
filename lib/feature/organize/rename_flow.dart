/// 文件名清理 / 改名流程：选规则或模板 → 出计划（旧名 → 新名）→ 确认 → 执行。
///
/// 整理页与曲库多选菜单共用一套：写入一律先预览，确认后才动盘。
library;

import 'package:flutter/material.dart';

import '../../app/repo.dart';
import '../../app/ui_kit.dart';
import '../../core/cleanup/cleaner.dart';
import '../../core/cleanup/name_template.dart';
import '../../core/fs/file_store.dart';
import '../../core/model/vfile.dart';
import '../../core/tx/write_preview.dart';
import '../common/write_confirm_sheet.dart';

/// 自定义模板输入框下方的实时提示：合法就显示「样例 → 新名」，不合法就说清原因。
Widget _templateHint(BuildContext context, String raw, VFile sample) {
  final String text = raw.trim();
  if (text.isEmpty) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 0, MoKit.pagePad, 4),
      child: Text('在下面输入模板后这里会显示改名效果',
          style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.faint(context))),
    );
  }
  final String? err = NameTemplate.validate(text);
  final String line = err ??
      NameTemplate.render(text, NameTemplate.fields(sample.cachedTags), sample.ext());
  final bool bad = err != null;
  return Padding(
    padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 0, MoKit.pagePad, 6),
    child: Text(
      bad ? err : '样例：${sample.name} → ${line.isEmpty ? '（拼不出名字，检查字段是否为空）' : line}',
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
          fontSize: MoKit.fsCaption,
          color: bad ? MoKit.err(context) : MoKit.sub(context)),
    ),
  );
}

/// 打开改名流程。[files] 是要改名的文件。
Future<void> runRenameFlow(BuildContext context, List<VFile> files) async {
  if (files.isEmpty) return;
  final Repo repo = Repo.instance;
  final FileStore? store = repo.store;
  if (store == null) {
    moSnack(context, '还没有准备好文件访问');
    return;
  }
  final TextEditingController custom = TextEditingController();
  // 输入框内容单独做成可监听值：底栏按钮要跟着「模板是否合法」实时变灰
  final ValueNotifier<String> typed = ValueNotifier<String>('');
  custom.addListener(() => typed.value = custom.text);
  String? pattern; // null = 用清理规则
  // 预览拿第一个有标签的文件算，最贴近用户看到的第一个结果
  final VFile sample = files.firstWhere(
      (VFile f) => f.cachedTags?.anyValue() ?? false,
      orElse: () => files.first);
  final bool? picked = await showMoSheet<bool>(
    context,
    title: '文件名清理（${files.length} 个文件）',
    children: <Widget>[
      MoTile(
        title: '按清理规则',
        subtitle: '去污染后缀、重编码标记；含中文再去掉多余空格',
        icon: Icons.auto_fix_high_outlined,
        onTap: () {
          pattern = null;
          Navigator.of(context).pop(true);
        },
      ),
      const Padding(
        padding: EdgeInsets.fromLTRB(MoKit.pagePad, 10, MoKit.pagePad, 4),
        child: Text('按标签改名（模板）：',
            style: TextStyle(fontSize: MoKit.fsCaption)),
      ),
      for (final String p in NameTemplate.presets)
        MoTile(
          title: p,
          subtitle: NameTemplate.render(
              p, NameTemplate.fields(sample.cachedTags), sample.ext()),
          onTap: () {
            pattern = p;
            Navigator.of(context).pop(true);
          },
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 8, MoKit.pagePad, 4),
        child: TextField(
          controller: custom,
          decoration: const InputDecoration(
            isDense: true,
            border: OutlineInputBorder(),
            hintText: '自定义模板，如 {artist} - {title}',
          ),
        ),
      ),
      // 边输边看：拼错了当场提示，不用等出计划才发现「拼不出名字」
      ValueListenableBuilder<String>(
        valueListenable: typed,
        builder: (BuildContext c, String v, Widget? _) => _templateHint(c, v, sample),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 0, MoKit.pagePad, 4),
        child: Text(NameTemplate.help(),
            style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
      ),
    ],
    // 固定底栏：模板选项再多也不会把确认按钮顶出屏幕
    footer: ValueListenableBuilder<String>(
      valueListenable: typed,
      builder: (BuildContext fctx, String v, Widget? _) {
        final String text = v.trim();
        final bool ok = text.isNotEmpty && NameTemplate.validate(text) == null;
        return SizedBox(
          width: double.infinity,
          child: MoButton('用这个模板', primary: false, onPressed: ok
              ? () {
                  pattern = text;
                  Navigator.of(fctx).pop(true);
                }
              : null),
        );
      },
    ),
  );
  typed.dispose();
  custom.dispose();
  if (picked != true) return;
  if (!context.mounted) return;
  if (pattern != null && pattern!.isEmpty) {
    moSnack(context, '模板不能为空');
    return;
  }
  final List<RenamePlan> plans = pattern == null
      ? await Cleaner.planCleanup(store, files)
      : await Cleaner.planTemplate(store, files, pattern!);
  if (!context.mounted) return;
  final List<RenamePlan> todo = plans.where((RenamePlan p) => p.changed).toList();
  final int conflict = plans
      .where((RenamePlan p) => p.status == RenamePlan.statusConflict)
      .length;
  if (todo.isEmpty) {
    moSnack(context,
        conflict > 0 ? '没有可改名的文件（$conflict 个目标名撞车）' : '文件名已经干净了');
    return;
  }
  // 统一预览：逐文件列「旧名 → 新名」，用户可取消勾选不想改的
  final List<WriteTarget> targets = todo.map((RenamePlan p) {
    return WriteTarget(
      docId: p.source.docId,
      name: p.source.name,
      path: repo.relPath(p.source),
      kind: WriteKind.rename,
      lines: <WriteLine>[WriteLineX.rename(p.source.name, p.newName)],
      data: p,
    );
  }).toList();

  final List<WriteTarget>? chosen = await WriteConfirmSheet.show(
    context,
    title: '改名计划',
    subtitle: conflict > 0
        ? '另有 $conflict 个目标名撞车，会跳过（不覆盖）。'
        : '目标位置没有同名文件，可以安全执行。',
    targets: targets,
    commitLabel: '确认改名',
    unit: '个',
    verb: '改名',
    expandAll: true,
  );
  if (chosen == null || chosen.isEmpty) return;
  final List<RenamePlan> doList = chosen
      .map((WriteTarget t) => t.data)
      .whereType<RenamePlan>()
      .toList();
  final CleanerResult r = await Cleaner.execute(store, doList);
  await repo.rescan();
  if (!context.mounted) return;
  moSnack(context, r.summary());
}
