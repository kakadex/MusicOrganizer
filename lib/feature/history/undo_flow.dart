/// 撤销也是一次写盘，所以同样要先预览、由用户确认。
///
/// 历史页、Ctrl+Z、写完后的「撤销」提示条共用这一条路径：
/// 先把这一批「当前值 → 还原后」列出来，用户逐首勾选，只还原勾中的那些。
library;

import 'package:flutter/material.dart';

import '../../app/repo.dart';
import '../../core/match/tag_fill.dart';
import '../../core/fs/file_store.dart';
import '../../core/model/journal_entry.dart';
import '../../core/model/tags.dart';
import '../../core/model/vfile.dart';
import '../../core/scan/scanner.dart';
import '../../core/tx/journal.dart';
import '../common/write_confirm_sheet.dart';
import '../../core/tx/write_preview.dart';

/// 带预览地撤销一个批次。
///
/// 返回还原成功的条数；用户取消或一项都没勾返回 null。
Future<int?> undoBatchWithPreview(
  BuildContext context, {
  required String batchId,
  String title = '确认撤销',
}) async {
  final Repo repo = Repo.instance;
  final Journal? journal = repo.journal;
  final tx = repo.tx;
  if (journal == null || tx == null) return null;

  final List<JournalEntry> entries = await journal.targets(batchId);
  final Map<String, VFile> byId = <String, VFile>{
    for (final VFile f in repo.files) f.docId: f,
  };
  final List<WriteTarget> targets = <WriteTarget>[];
  for (final JournalEntry e in entries) {
    // 旧日志只写了 uri（同一份 docId），两个都认，否则撤销会静默 0 条
    final String key = e.targetId.isNotEmpty ? e.targetId : e.uri;
    final VFile? f = byId[key];
    if (f == null) continue;
    final List<WriteLine> lines = <WriteLine>[];
    final Set<String> keys = <String>{...e.after.keys, ...e.before.keys};
    for (final String k in keys) {
      final String now = (e.after[k] ?? '').trim();
      final String back = (e.before[k] ?? '').trim();
      if (now == back) continue;
      lines.add(WriteLine(
        label: TagFill.label(k),
        oldText: now,
        newText: back,
        key: k,
      ));
    }
    if (lines.isEmpty) continue;
    targets.add(WriteTarget(
      docId: f.docId,
      name: e.name.isNotEmpty ? e.name : f.name,
      path: repo.relPath(f),
      kind: WriteKind.tag,
      note: '还原到写入前',
      lines: lines,
      file: f,
      data: e,
    ));
  }
  if (!context.mounted) return null;
  if (targets.isEmpty) return 0;

  final List<WriteTarget>? picked = await WriteConfirmSheet.show(
    context,
    title: title,
    subtitle: '勾中的曲目会还原到写入前的值',
    targets: targets,
    commitLabel: '撤销',
    unit: '首',
    verb: '还原',
    expandAll: true,
  );
  if (picked == null || picked.isEmpty) return null;
  final Set<String> keep = <String>{
    for (final WriteTarget t in picked)
      if (t.data is JournalEntry) (t.data! as JournalEntry).id,
  };

  int ok = 0;
  await journal.revertBatch(
    batchId,
    skip: (JournalEntry e) => !keep.contains(e.id),
    revertOne: (JournalEntry entry) async {
      final String key = entry.targetId.isNotEmpty ? entry.targetId : entry.uri;
      final VFile? f = byId[key];
      if (f == null) return false;
      // 只写「确实需要变」的字段：日志里记了全部字段（含原值为空的那些），
      // 整包写回去会把无关字段一并重写（旧版本还会留下空帧）。
      Tags now = f.cachedTags ?? Tags();
      final FileStore? st = repo.store;
      if (st != null) {
        try {
          now = await Scanner.readTags(st, f);
        } catch (_) {
          // 读不到就退回缓存值，按日志逐项还原
        }
      }
      final Map<String, String> updates = <String, String>{};
      for (final String k in <String>{...entry.before.keys, ...entry.after.keys}) {
        final String back = (entry.before[k] ?? '').trim();
        if (now.get(k).trim() != back) updates[k] = back;
      }
      if (updates.isEmpty) {
        // 已经是写入前的值（用户手动改回去了），不用再动文件
        ok++;
        return true;
      }
      final String err = await tx.apply(f, updates, record: false);
      if (err.isNotEmpty) return false;
      ok++;
      repo.invalidate(f);
      return true;
    },
  );
  return ok;
}
