/// 把选中曲目标签里的繁体统一转成简体。
///
/// 与「删除全部封面、标签、歌词」同一套骨架：先预览逐首列出会改的字段，确认后
/// 走标签事务写回（可撤销）。只改文字，不碰封面与音频数据。
library;

import 'package:flutter/material.dart';

import '../../app/repo.dart';
import '../../app/ui_kit.dart';
import '../../core/fs/file_store.dart';
import '../../core/model/journal_entry.dart' show JournalOp;
import '../../core/model/tags.dart';
import '../../core/model/task_control.dart';
import '../../core/model/vfile.dart';
import '../../core/scan/scanner.dart';
import '../../core/tag/tag_io.dart';
import '../../core/tag/tag_zh.dart';
import '../../core/task/task_center.dart';
import '../../core/tx/write_preview.dart';
import '../common/write_confirm_sheet.dart';
import '../history/undo_flow.dart';

/// 打开「标签转简体」流程。[files] 是选中的曲目。
Future<void> runConvertTagsToSimplified(
    BuildContext context, List<VFile> files) async {
  final Repo repo = Repo.instance;
  if (files.isEmpty) return;
  final FileStore? store = repo.store;
  if (store == null) {
    moSnack(context, '还没有选择曲库目录');
    return;
  }
  final List<VFile> targets = files
      .where((VFile f) => !f.dir && TagIO.canWrite(f.ext()))
      .toList();
  if (targets.isEmpty) {
    moSnack(context, '选中的文件都不支持写标签');
    return;
  }
  if (TaskCenter.isBusy()) {
    moSnack(context, '已有任务在跑，先等它结束');
    return;
  }

  // 和批量删除一样挂任务中心：几百首时「逐首读标签」也要点时间，得让用户看见。
  final RunningTask? task = TaskCenter.start('标签转简体');
  final TaskControl? ctl = task?.control;
  try {
    final List<WriteTarget> plans = <WriteTarget>[];
    for (int i = 0; i < targets.length; i++) {
      if (ctl?.isCancelled() ?? false) break;
      final VFile f = targets[i];
      if (i % 20 == 0) ctl?.report(i, targets.length, '正在检查 ${f.name}');
      try {
        final Tags tags = f.cachedTags ?? await Scanner.readTags(store, f);
        final Map<String, String> changes = TagZh.changes(tags);
        if (changes.isEmpty) continue;
        plans.add(WriteTarget(
          docId: f.docId,
          name: f.name,
          path: repo.relPath(f),
          kind: WriteKind.tag,
          lines: <WriteLine>[
            for (final MapEntry<String, String> e in changes.entries)
              if (e.key == Tags.lyrics)
                // 歌词可能几 KB：预览只标「繁体原文 → 转成简体」，
                // 完整新值放 payload，写盘时用它，不用截断版
                WriteLine(
                  label: '歌词',
                  oldText: '繁体原文',
                  newText: '转成简体',
                  key: Tags.lyrics,
                  payload: e.value,
                )
              else
                WriteLine(
                  label: Tags.labels[e.key] ?? e.key,
                  oldText: tags.get(e.key),
                  newText: e.value,
                  key: e.key,
                ),
          ],
          file: f,
        ));
      } catch (_) {
        // 单首读不出来只跳过它自己，不能让整批「什么都没发生」
      }
    }
    if (!context.mounted) return;
    await _confirmAndRun(context, repo, plans, targets.length);
  } finally {
    TaskCenter.finish();
  }
}

Future<void> _confirmAndRun(
    BuildContext context, Repo repo, List<WriteTarget> plans, int chosen) async {
  if (plans.isEmpty) {
    moSnack(context, '选中的文件里没有需要转成简体的标签');
    return;
  }
  final int nothing = chosen - plans.length;
  final List<WriteTarget>? picked = await WriteConfirmSheet.show(
    context,
    title: '标签转简体',
    subtitle: nothing > 0
        ? '逐首列出会改动的字段（繁体 → 简体）；另外 $nothing 首本来就是简体，不列在这里'
        : '逐首列出会改动的字段（繁体 → 简体）',
    warning: '只改文字标签与内嵌歌词，封面和音频数据不动；写盘后可用「撤销」还原',
    targets: plans,
    commitLabel: '转换',
    unit: '首',
    verb: '转换',
    expandAll: plans.length <= 20,
  );
  if (picked == null || picked.isEmpty || !context.mounted) return;

  final tx = repo.tx;
  if (tx == null) {
    moSnack(context, '还没有准备好写盘通道');
    return;
  }
  final String batchId = 'zhsimp-${DateTime.now().millisecondsSinceEpoch}';
  final TaskControl? ctl = TaskCenter.control();
  int done = 0;
  int failed = 0;
  bool stopped = false;
  final List<VFile> touched = <VFile>[];
  for (int i = 0; i < picked.length; i++) {
    if (ctl?.isCancelled() ?? false) {
      stopped = true;
      break;
    }
    final WriteTarget t = picked[i];
    ctl?.report(i, picked.length, '正在转换 ${t.name}');
    final VFile? f = t.file as VFile?;
    if (f == null) continue;
    final Map<String, String> updates = <String, String>{};
    for (final WriteLine l in t.lines) {
      if (!l.selected || !l.changed) continue;
      final String? k = l.key;
      if (k == null || k.isEmpty) continue;
      // 歌词的完整新值在 payload 里（预览只显示开头），别拿截断版写回
      final String value = (l.payload as String?) ?? l.newText;
      updates[k] = value;
    }
    if (updates.isEmpty) continue;
    final String err =
        await tx.apply(f, updates, batchId: batchId, op: JournalOp.tags);
    if (err.isEmpty) {
      done++;
      repo.invalidate(f);
      touched.add(f);
    } else {
      failed++;
    }
  }
  if (touched.isNotEmpty) {
    await repo.loadMeta(only: touched);
  }
  if (!context.mounted) return;
  final String head = stopped ? '已停止，已转换 $done 首' : '已转换 $done 首';
  moSnack(context, '$head${failed > 0 ? '，失败 $failed 首' : ''}',
      actionLabel: done == 0 ? null : '撤销',
      onAction: () async {
        final int? n = await undoBatchWithPreview(context, batchId: batchId);
        if (n != null && context.mounted) moSnack(context, '已撤销 $n 处');
      });
}
