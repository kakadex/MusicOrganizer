/// 批量改标签：给选中的曲目统一设几个字段（专辑名 / 流派 / 年份…），可重排音轨号。
///
/// 硬规矩：先预览（逐首「旧值 → 新值」），确认后才写盘；写盘走事务层。
library;

import 'package:flutter/material.dart';

import '../../app/repo.dart';
import '../../app/ui_kit.dart';
import '../../core/match/batch_edit.dart';
import '../../core/model/tags.dart';
import '../../core/model/vfile.dart';
import '../../core/tag/tag_io.dart';
import '../../core/tx/write_preview.dart';
import '../common/write_confirm_sheet.dart';

/// 打开批量编辑流程。[files] 是选中的曲目。
Future<void> runBatchEdit(BuildContext context, List<VFile> files) async {
  final Repo repo = Repo.instance;
  if (files.isEmpty) return;
  final int editable = BatchEditSpec.editableCount(files);
  if (editable == 0) {
    moSnack(context, '选中的文件都不支持写标签');
    return;
  }
  final Map<String, TextEditingController> ctl = <String, TextEditingController>{
    for (final String f in BatchEditSpec.fields) f: TextEditingController(),
  };
  int trackStart = 1;
  bool renumber = false;
  final TextEditingController trackCtl = TextEditingController(text: '1');

  final bool? go = await showMoSheet<bool>(
    context,
    title: '批量改标签（$editable 首可写）',
    children: <Widget>[
      StatefulBuilder(builder: (BuildContext ctx, StateSetter setSheet) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.fromLTRB(MoKit.pagePad, 0, MoKit.pagePad, 4),
              child: Text('填了就生效；留空表示不动这个字段。',
                  style: TextStyle(fontSize: MoKit.fsCaption)),
            ),
            for (final String f in BatchEditSpec.fields)
              Padding(
                padding:
                    const EdgeInsets.fromLTRB(MoKit.pagePad, 4, MoKit.pagePad, 4),
                child: Row(
                  children: <Widget>[
                    SizedBox(
                      width: 48,
                      child: Text(_label(f),
                          style: TextStyle(
                              fontSize: MoKit.fsCaption, color: MoKit.sub(ctx))),
                    ),
                    Expanded(
                      child: TextField(
                        controller: ctl[f],
                        style: TextStyle(
                            fontSize: MoKit.fsBody, color: MoKit.text(ctx)),
                        decoration: const InputDecoration(
                          isDense: true,
                          filled: true,
                          border: OutlineInputBorder(),
                          hintText: '（不填 = 不动）',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 10, MoKit.pagePad, 2),
              child: Row(
                children: <Widget>[
                  Checkbox(
                    value: renumber,
                    onChanged: (bool? v) => setSheet(() => renumber = v == true),
                    visualDensity: VisualDensity.compact,
                  ),
                  const SizedBox(width: 4),
                  Text('音轨号按顺序重排，从',
                      style: TextStyle(
                          fontSize: MoKit.fsBody, color: MoKit.text(ctx))),
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 56,
                    child: TextField(
                      controller: trackCtl,
                      keyboardType: TextInputType.number,
                      style: TextStyle(
                          fontSize: MoKit.fsBody, color: MoKit.text(ctx)),
                      decoration: const InputDecoration(
                        isDense: true,
                        filled: true,
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (String v) => trackStart = int.tryParse(v) ?? 1,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      }),
    ],
    // 固定底栏：字段再多、键盘弹起时也不会把「生成预览」顶出屏幕
    footer: Builder(
      builder: (BuildContext fctx) => SizedBox(
        width: double.infinity,
        child: MoButton('生成预览', onPressed: () => Navigator.of(fctx).pop(true)),
      ),
    ),
  );
  for (final TextEditingController c in ctl.values) {
    c.dispose();
  }
  trackCtl.dispose();
  if (go != true || !context.mounted) return;

  final BatchEditSpec spec = BatchEditSpec()
    ..renumberTrack = renumber
    ..trackStart = trackStart;
  for (final MapEntry<String, TextEditingController> e in ctl.entries) {
    final String v = e.value.text.trim();
    if (v.isNotEmpty) spec.values[e.key] = v;
  }
  if (spec.isEmpty) {
    moSnack(context, '没有要修改的字段');
    return;
  }

  // 预览：逐首列「旧值 → 新值」，用户可整首 / 逐字段勾选
  final List<VFile> targets = files
      .where((VFile f) => !f.dir && TagIO.canWrite(f.ext()))
      .toList();
  int index = 0;
  final List<WriteTarget> plans = <WriteTarget>[];
  for (final VFile f in targets) {
    final int at = index++;
    final Map<String, String> updates = spec.updatesFor(at);
    final Tags now = f.cachedTags ?? Tags();
    final List<WriteLine> lines = <WriteLine>[];
    for (final MapEntry<String, String> e in updates.entries) {
      final String old = now.get(e.key).trim();
      if (old == e.value) continue;
      lines.add(WriteLine(
        label: _label(e.key),
        oldText: old,
        newText: e.value,
        key: e.key,
      ));
    }
    if (lines.isEmpty) continue;
    plans.add(WriteTarget(
      docId: f.docId,
      name: f.name,
      path: repo.relPath(f),
      kind: WriteKind.tag,
      lines: lines,
      file: f,
      data: at,
    ));
  }
  if (plans.isEmpty) {
    moSnack(context, '这些文件的标签已经和要填的一样了');
    return;
  }

  final List<WriteTarget>? picked = await WriteConfirmSheet.show(
    context,
    title: '批量改标签预览',
    subtitle: spec.summary(),
    targets: plans,
    commitLabel: '写入',
    unit: '首',
    verb: '写入',
    expandAll: true,
  );
  if (picked == null || picked.isEmpty || !context.mounted) return;

  final tx = repo.tx;
  if (tx == null) {
    moSnack(context, '还没有准备好写盘通道');
    return;
  }
  final String batchId = 'batchedit-${DateTime.now().millisecondsSinceEpoch}';
  // 整批事务：批内每首写之前留一份备份，中途失败可以「要么全成、要么全退」。
  // 单文件事务只保证一首不出半成品，200 首里第 137 首失败时前 136 首已经落盘了。
  tx.beginBatch(batchId);
  int done = 0;
  int failed = 0;
  for (final WriteTarget t in picked) {
    final VFile? f = t.file as VFile?;
    if (f == null) continue;
    // 只写用户勾中的字段（音轨号用的是原始顺序算出来的值，取消勾选不影响其余文件）
    final Map<String, String> updates = t.toUpdates();
    if (updates.isEmpty) continue;
    final String err = await tx.apply(f, updates, batchId: batchId);
    if (err.isEmpty) {
      done++;
      repo.invalidate(f);
    } else {
      failed++;
    }
  }
  if (failed > 0 && done > 0 && context.mounted) {
    // 半途失败：已经写入的那部分是留着还是一起退回去，交给用户定
    final bool? rollback = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('这一批没有全部写入成功'),
        content: Text('已写入 $done 首，失败 $failed 首。\n\n'
            '要不要把已经写入的 $done 首全部退回？'
            '${tx.batchTruncated(batchId) ? '\n\n（备份空间到上限，只能退回其中一部分）' : ''}'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('保留已写入的'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('整批退回'),
          ),
        ],
      ),
    );
    if (rollback == true) {
      final (int ok, int bad) = await tx.rollbackBatch(batchId);
      for (final WriteTarget t in picked) {
        final VFile? f = t.file as VFile?;
        if (f != null) repo.invalidate(f);
      }
      if (!context.mounted) return;
      moSnack(context, '已退回 $ok 首${bad > 0 ? '，退回失败 $bad 首' : ''}');
      return;
    }
  }
  await tx.commitBatch(batchId);
  if (!context.mounted) return;
  moSnack(context, '已写入 $done 首${failed > 0 ? '，失败 $failed 首' : ''}');
}

String _label(String key) {
  switch (key) {
    case 'title':
      return '标题';
    case 'artist':
      return '艺人';
    case 'album':
      return '专辑';
    case 'genre':
      return '流派';
    case 'year':
      return '年份';
    case 'comment':
      return '注释';
    default:
      return key;
  }
}
