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
import '../../core/model/task_control.dart';
import '../../core/model/vfile.dart';
import '../../core/scan/scanner.dart';
import '../../core/tag/tag_io.dart';
import '../../core/task/task_center.dart';
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
  // 已有任务在跑就别插队：批量删除本身会挂成任务，两个任务抢通道会互相拖死。
  if (TaskCenter.isBusy()) {
    moSnack(context, '已有任务在跑，先等它结束');
    return;
  }

  // 整批挂到任务中心：全选几百首时，「检查封面 / 歌词」本身就要跑一会儿，
  // 界面不给反馈的话用户会以为点空了（用户实测反馈：单首能删、全选没反应）。
  final RunningTask? task = TaskCenter.start('删除全部封面、标签、歌词');
  final TaskControl? ctl = task?.control;
  try {
    final List<WriteTarget> plans = await _plan(store, targets, ctl);
    if (!context.mounted) return;
    await _confirmAndRun(context, repo, plans, targets.length);
  } finally {
    TaskCenter.finish();
  }
}

/// 逐首列出要清掉的封面 / 字段 / 歌词。**单首出错只跳过它自己**，不能因为
/// 一个目录读不出来就让几百首的整批操作「什么都没发生」。
Future<List<WriteTarget>> _plan(
    FileStore store, List<VFile> targets, TaskControl? ctl) async {
  // 同名 .lrc 先按目录一次性找出来：逐首 locate 会对每首 stat + 列一遍父目录，
  // 900 首就是上千次跨进程查询，安卓上会长时间没反应。
  final Set<String> withLrc = await LrcSidecar.withSidecar(store, targets);
  final List<WriteTarget> plans = <WriteTarget>[];
  for (int i = 0; i < targets.length; i++) {
    if (ctl?.isCancelled() ?? false) break;
    final VFile f = targets[i];
    if (i % 20 == 0) ctl?.report(i, targets.length, '正在检查 ${f.name}');
    try {
      final WriteTarget? plan = await _planOne(store, f, withLrc.contains(f.docId));
      if (plan != null) plans.add(plan);
    } catch (_) {
      // 单个文件读不出来（授权抖动 / 刚刚被删）：跳过，继续看下一首
    }
  }
  return plans;
}

/// 单首的计划；没有可删的内容返回 null。
Future<WriteTarget?> _planOne(FileStore store, VFile f, bool hasLrc) async {
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
  if (hasLrc) {
    lines.add(WriteLine(
      label: '歌词文件',
      oldText: LrcSidecar.nameFor(f),
      newText: '',
      key: LrcSidecar.journalKey,
    ));
  }
  if (lines.isEmpty) return null; // 这首没有可删的
  return WriteTarget(
    docId: f.docId,
    name: f.name,
    path: Repo.instance.relPath(f),
    kind: WriteKind.tag,
    risky: true,
    lines: lines,
    file: f,
  );
}

/// 弹确认面板，然后逐首写盘（带进度，可停止）。
Future<void> _confirmAndRun(
    BuildContext context, Repo repo, List<WriteTarget> plans, int chosen) async {
  if (!context.mounted) return;
  if (plans.isEmpty) {
    moSnack(context, '选中的文件没有封面、标签或歌词可删');
    return;
  }

  final int nothing = chosen - plans.length;
  final List<WriteTarget>? picked = await WriteConfirmSheet.show(
    context,
    title: '删除全部封面、标签、歌词',
    subtitle: nothing > 0
        ? '逐首列出要清空的封面、字段与歌词，可取消勾选不想删的项；'
            '另外 $nothing 首本来就没有可删的内容，不列在这里'
        : '逐首列出要清空的封面、字段与歌词，可取消勾选不想删的项',
    warning: '封面、标签、内嵌歌词与同名 .lrc 会一并删除；'
        '撤销可还原标签与歌词，封面删掉后只能重新选图',
    targets: plans,
    commitLabel: '删除',
    unit: '首',
    verb: '删除',
    // 几百首时全部展开会一口气建出几千行卡片：超过 20 首默认折叠，想看细节再点开
    expandAll: plans.length <= 20,
  );
  if (picked == null || picked.isEmpty || !context.mounted) return;

  final tx = repo.tx;
  if (tx == null) {
    moSnack(context, '还没有准备好写盘通道');
    return;
  }
  final String batchId = 'clearall-${DateTime.now().millisecondsSinceEpoch}';
  final TaskControl? ctl = TaskCenter.control();
  int done = 0;
  int failed = 0;
  bool stopped = false;
  final List<VFile> touched = <VFile>[];
  for (int i = 0; i < picked.length; i++) {
    // 底部任务条的「停止」：每首开始前看一次，不再无声地继续跑几百首
    if (ctl?.isCancelled() ?? false) {
      stopped = true;
      break;
    }
    final WriteTarget t = picked[i];
    ctl?.report(i, picked.length, '正在清除 ${t.name}');
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
  final String head = stopped ? '已停止，已清除 $done 首' : '已清除 $done 首';
  moSnack(context, '$head${failed > 0 ? '，失败 $failed 首' : ''}',
      actionLabel: done == 0 ? null : '撤销',
      onAction: () async {
        final int? n = await undoBatchWithPreview(context, batchId: batchId);
        if (n != null && context.mounted) moSnack(context, '已撤销 $n 处');
      });
}
