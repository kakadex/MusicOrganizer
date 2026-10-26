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
            Padding(
              padding: const EdgeInsets.all(MoKit.pagePad),
              child: MoButton('生成预览', onPressed: () => Navigator.of(ctx).pop(true)),
            ),
          ],
        );
      }),
    ],
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

  // 预览：逐首列「旧值 → 新值」
  final List<VFile> targets = files
      .where((VFile f) => !f.dir && TagIO.canWrite(f.ext()))
      .toList();
  int index = 0;
  final List<String> preview = <String>[];
  for (final VFile f in targets) {
    final Map<String, String> updates = spec.updatesFor(index++);
    final Tags now = f.cachedTags ?? Tags();
    final List<String> parts = <String>[];
    for (final MapEntry<String, String> e in updates.entries) {
      final String old = now.get(e.key).trim();
      if (old == e.value) continue;
      parts.add('${_label(e.key)}：${old.isEmpty ? '（空）' : old} → '
          '${e.value.isEmpty ? '（清空）' : e.value}');
    }
    if (parts.isNotEmpty) {
      preview.add('${f.name}\n    ${parts.join('；')}');
    }
  }
  if (preview.isEmpty) {
    moSnack(context, '这些文件的标签已经和要填的一样了');
    return;
  }

  final bool? ok = await showMoSheet<bool>(
    context,
    title: '批量改标签预览（${preview.length} 首）',
    children: <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 0, MoKit.pagePad, 4),
        child: Text(spec.summary(),
            style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
      ),
      for (final String line in preview.take(80))
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: MoKit.pagePad, vertical: 3),
          child: Text(line,
              style: TextStyle(fontSize: MoKit.fsBody, color: MoKit.text(context))),
        ),
      if (preview.length > 80)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: MoKit.pagePad, vertical: 3),
          child: Text('……还有 ${preview.length - 80} 首',
              style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
        ),
      Padding(
        padding: const EdgeInsets.all(MoKit.pagePad),
        child: MoButton('确认写入 ${preview.length} 首',
            onPressed: () => Navigator.of(context).pop(true)),
      ),
    ],
  );
  if (ok != true || !context.mounted) return;

  final tx = repo.tx;
  if (tx == null) {
    moSnack(context, '还没有准备好写盘通道');
    return;
  }
  final String batchId = 'batchedit-${DateTime.now().millisecondsSinceEpoch}';
  int done = 0;
  int failed = 0;
  index = 0;
  for (final VFile f in targets) {
    final Map<String, String> updates = spec.updatesFor(index++);
    if (updates.isEmpty) continue;
    final String err = await tx.apply(f, updates, batchId: batchId);
    if (err.isEmpty) {
      done++;
      repo.invalidate(f);
    } else {
      failed++;
    }
  }
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
