/// 删除选中文件的全部封面、标签与歌词（内嵌歌词 + 同名 `.lrc`）。
///
/// 硬规矩：先预览（逐首列出要清掉的封面 / 字段 / 歌词），确认后才写盘；写盘走事务层，
/// 「撤销」可还原标签与 `.lrc`（同进同退）。**封面删掉就回不来了**——撤销日志只存
/// 字段文本，存不下封面图片本身，预览里必须如实说明。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app/cover_cache.dart';
import '../../app/repo.dart';
import '../../app/ui_kit.dart';
import '../../core/fs/file_store.dart';
import '../../core/model/journal_entry.dart' show JournalOp;
import '../../core/model/tags.dart';
import '../../core/model/vfile.dart';
import '../../core/scan/scanner.dart';
import '../../core/tag/tag_io.dart';
import '../../core/tx/lrc_sidecar.dart';
import '../../core/tx/write_preview.dart';
import '../common/write_confirm_sheet.dart';
import '../history/undo_flow.dart';

/// 封面在预览里的行键（不是真标签字段，写盘时单独取出来，与编辑器同一个约定）。
const String _coverKey = '__cover';

/// 打开「删除全部封面、标签和歌词」流程。[files] 是选中的曲目。
Future<void> runClearAllTags(BuildContext context, List<VFile> files) async {
  final Repo repo = Repo.instance;
  if (files.isEmpty) return;
  final FileStore? store = repo.store;
  if (store == null) {
    moSnack(context, '还没有选择曲库目录');
    return;
  }

  // 只处理可写格式。
  final List<VFile> targets = files
      .where((VFile f) => !f.dir && TagIO.canWrite(f.ext()))
      .toList();
  if (targets.isEmpty) {
    moSnack(context, '选中的文件都不支持写标签');
    return;
  }

  // 逐首读标签 + 探测同名 .lrc，列出要清的非空字段。
  final List<WriteTarget> plans = <WriteTarget>[];
  for (final VFile f in targets) {
    Tags tags;
    try {
      tags = f.cachedTags ?? await Scanner.readTags(store, f);
    } catch (_) {
      tags = Tags();
    }
    final List<WriteLine> lines = <WriteLine>[];
    // 封面不在 Tags.keys 里，得单独探一下（命中库索引缓存时不碰磁盘）
    if (await Scanner.hasCover(store, f)) {
      lines.add(WriteLine(
        label: '封面',
        oldText: '有内嵌封面',
        newText: '（删除）',
        key: _coverKey,
      ));
    }
    for (final String k in Tags.keys) {
      final String v = tags.get(k).trim();
      if (v.isEmpty) continue;
      lines.add(WriteLine(
        label: Tags.labels[k] ?? k,
        oldText: v,
        newText: '',
        key: k,
      ));
    }
    final String lyr = tags.get(Tags.lyrics).trim();
    if (lyr.isNotEmpty) {
      lines.add(WriteLine(
        label: Tags.labels[Tags.lyrics] ?? Tags.lyrics,
        oldText: lyr,
        newText: '',
        key: Tags.lyrics,
      ));
    }
    final bool hasLrc = (await LrcSidecar.locate(store, f)) != null;
    if (hasLrc) {
      lines.add(WriteLine(
        label: '歌词文件',
        oldText: LrcSidecar.nameFor(f),
        newText: '',
        key: LrcSidecar.journalKey,
      ));
    }
    if (lines.isEmpty) continue; // 这首没有可删的
    plans.add(WriteTarget(
      docId: f.docId,
      name: f.name,
      path: repo.relPath(f),
      kind: WriteKind.tag,
      risky: true,
      lines: lines,
      file: f,
    ));
  }

  if (!context.mounted) return;
  if (plans.isEmpty) {
    moSnack(context, '选中的文件没有封面、标签或歌词可删');
    return;
  }

  final List<WriteTarget>? picked = await WriteConfirmSheet.show(
    context,
    title: '删除全部封面、标签、歌词',
    subtitle: '逐首列出要清空的封面、字段与歌词，可取消勾选不想删的项',
    warning: '封面、标签、内嵌歌词与同名 .lrc 会一并删除；'
        '撤销可还原标签与歌词，封面删掉后只能重新选图',
    targets: plans,
    commitLabel: '删除',
    unit: '首',
    verb: '删除',
    expandAll: true,
  );
  if (picked == null || picked.isEmpty || !context.mounted) return;

  final tx = repo.tx;
  if (tx == null) {
    moSnack(context, '还没有准备好写盘通道');
    return;
  }
  final String batchId = 'clearall-${DateTime.now().millisecondsSinceEpoch}';
  int done = 0;
  int failed = 0;
  final List<VFile> touched = <VFile>[];
  for (final WriteTarget t in picked) {
    final VFile? f = t.file as VFile?;
    if (f == null) continue;
    final Map<String, String> updates = <String, String>{};
    bool removeLrc = false;
    bool removeCover = false;
    for (final WriteLine l in t.lines) {
      if (!l.selected || !l.changed) continue;
      final String? k = l.key;
      if (k == null || k.isEmpty) continue;
      if (k == _coverKey) {
        removeCover = true;
      } else if (k == LrcSidecar.journalKey) {
        removeLrc = true;
      } else {
        updates[k] = '';
      }
    }
    if (updates.isEmpty && !removeLrc && !removeCover) continue;
    final String err = await tx.apply(f, updates,
        batchId: batchId,
        cover: removeCover ? Uint8List(0) : null,
        removeLrc: removeLrc,
        op: JournalOp.clear);
    if (err.isEmpty) {
      done++;
      repo.invalidate(f);
      touched.add(f);
    } else {
      failed++;
    }
  }
  // 写盘后 invalidate 会清掉标签缓存，但**封面的内存缓存不会自己失效**：
  // 不手动清，列表里这些歌会继续显示刚删掉的那张图（标签已经刷新，只有封面
  // 停在旧状态），看着像没删成功。编辑器保存后也是这么清的。
  if (touched.isNotEmpty) {
    CoverCache.instance.clear();
    await repo.loadMeta(only: touched);
  }
  if (!context.mounted) return;
  moSnack(context, '已清除 $done 首${failed > 0 ? '，失败 $failed 首' : ''}',
      actionLabel: done == 0 ? null : '撤销',
      onAction: () async {
        final int? n = await undoBatchWithPreview(context, batchId: batchId);
        if (n != null && context.mounted) moSnack(context, '已撤销 $n 处');
      });
}
