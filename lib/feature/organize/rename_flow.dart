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
  String? pattern; // null = 用清理规则
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
      Padding(
        padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 0, MoKit.pagePad, 4),
        child: Text(NameTemplate.help(),
            style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
      ),
      Padding(
        padding: const EdgeInsets.all(MoKit.pagePad),
        child: MoButton('用这个模板', primary: false, onPressed: () {
          pattern = custom.text.trim();
          Navigator.of(context).pop(true);
        }),
      ),
    ],
  );
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
  final bool? go = await showMoSheet<bool>(
    context,
    title: '改名计划（${todo.length} 个）',
    children: <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 0, MoKit.pagePad, 4),
        child: Text(conflict > 0
            ? '另有 $conflict 个目标名撞车，会跳过（不覆盖）。'
            : '目标位置没有同名文件，可以安全执行。',
            style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
      ),
      for (final RenamePlan p in todo.take(80))
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: MoKit.pagePad, vertical: 2),
          child: Text('${p.source.name}  →  ${p.newName}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: MoKit.fsBody, color: MoKit.text(context))),
        ),
      if (todo.length > 80)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: MoKit.pagePad, vertical: 2),
          child: Text('……还有 ${todo.length - 80} 个',
              style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
        ),
      Padding(
        padding: const EdgeInsets.all(MoKit.pagePad),
        child: MoButton('确认改名 ${todo.length} 个', primary: false,
            onPressed: () => Navigator.of(context).pop(true)),
      ),
    ],
  );
  if (go != true) return;
  final CleanerResult r = await Cleaner.execute(store, todo);
  await repo.rescan();
  if (!context.mounted) return;
  moSnack(context, r.summary());
}
