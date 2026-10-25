import 'package:flutter/material.dart';

import '../../app/repo.dart';
import '../../app/ui_kit.dart';
import '../../core/cleanup/junk.dart';
import '../../core/dedupe/duplicates.dart';
import '../../core/match/tag_fix.dart';
import '../../core/model/duplicate_group.dart';
import '../../core/model/tags.dart';
import '../../core/model/task_control.dart';
import '../../core/model/vfile.dart';
import '../../core/organize/organizer.dart';
import '../../core/scan/scanner.dart';
import '../../core/task/task_center.dart';
import '../../core/tx/tag_transaction.dart';
import '../covers/covers_page.dart';
import '../library/preview_sheet.dart';
import '../lyrics_batch/lyrics_batch_page.dart';

/// 整理页：**三张任务卡**（扫描与整理 / 批量处理 / 清理），而不是一长串平铺按钮。
///
/// 危险动作（移动、删除）一律「先出计划 → 用户确认 → 再执行」。
class OrganizePage extends StatefulWidget {
  const OrganizePage({super.key});

  @override
  State<OrganizePage> createState() => _OrganizePageState();
}

class _OrganizePageState extends State<OrganizePage> {
  bool _busy = false;
  String _status = '';

  Repo get _repo => Repo.instance;

  @override
  Widget build(BuildContext context) {
    // 曲库页授权 / 扫描完成后要立刻反映到这里，所以页面自己监听 Repo。
    return ListenableBuilder(
      listenable: _repo,
      builder: (BuildContext context, Widget? _) => _body(context),
    );
  }

  Widget _body(BuildContext context) {
    final int audio = _repo.audioFiles().length;
    return Column(
      children: <Widget>[
        PageHeader(title: '整理', subtitle: _repo.hasRoot ? '$audio 首 · ${_status.isEmpty ? '待整理' : _status}' : '还没有选择曲库目录'),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 16),
            children: <Widget>[
              _scanCard(audio),
              _tagCard(),
              _cleanCard(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _scanCard(int audio) {
    final int unorganized = _repo.audioFiles().where((VFile f) {
      final rel = f.relativePath(_repo.root?.rootDocId ?? '');
      return !rel.contains('/');
    }).length;
    return SectionCard(
      title: '扫描与整理',
      subtitle: _repo.hasRoot ? '$audio 首 · 待归类 $unorganized 首' : '先选一个曲库目录',
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(child: MoButton('扫描统计', primary: false, onPressed: _busy ? null : _rescan)),
            const SizedBox(width: 8),
            Expanded(child: MoButton('自动整理', busy: _busy, onPressed: _busy ? null : _organize)),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '自动整理只做三件事：按「歌手 / 专辑」算目标目录、给出移动计划、你确认后才动文件。'
          '同名文件一律跳过，绝不覆盖。',
          style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context)),
        ),
      ],
    );
  }

  Widget _tagCard() {
    final List<VFile> files = _repo.audioFiles();
    return SectionCard(
      title: '批量处理',
      subtitle: '对当前曲库的全部曲目执行（可在曲库页只选几首）',
      children: <Widget>[
        MoTile(
          title: '清理标签文本',
          subtitle: '去多余空格 / 全角转半角 / 音轨号补零',
          icon: Icons.cleaning_services_outlined,
          onTap: files.isEmpty ? null : () => _tidy(files),
        ),
        MoTile(
          title: '批量补封面',
          subtitle: '多源取图，逐首写入内嵌封面',
          icon: Icons.image_outlined,
          onTap: files.isEmpty
              ? null
              : () => _push(CoversPage(files: files)),
        ),
        MoTile(
          title: '批量补歌词',
          subtitle: '五源并发，按打分取最优；低置信默认不勾选',
          icon: Icons.lyrics_outlined,
          onTap: files.isEmpty
              ? null
              : () => _push(LyricsBatchPage(files: files)),
        ),
      ],
    );
  }

  Widget _cleanCard() {
    final List<VFile> all = _repo.files;
    int junk = 0;
    for (final VFile f in all) {
      if (Junk.isJunk(f)) junk++;
    }
    return SectionCard(
      title: '清理与查重',
      subtitle: '只看不改，列出来再决定',
      children: <Widget>[
        MoTile(
          title: '文件名查重',
          subtitle: '相似度分组，标出「疑似」，默认不勾选',
          icon: Icons.copy_all_outlined,
          onTap: all.isEmpty ? null : () => _dedupe(all),
        ),
        MoTile(
          title: '垃圾文件',
          subtitle: junk == 0 ? '没有发现' : '发现 $junk 个（.bak / Thumbs.db / 0 字节…）',
          icon: Icons.delete_outline,
          onTap: junk == 0 ? null : () => _junk(all),
        ),
      ],
    );
  }

  void _push(Widget page) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (BuildContext _) => page),
    );
  }

  Future<void> _rescan() async {
    setState(() {
      _busy = true;
      _status = '正在扫描…';
    });
    final ScanOutcome out = await _repo.rescan();
    if (!mounted) return;
    if (out.ok) await _repo.loadMeta();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = out.ok ? '' : out.error;
    });
    moSnack(context, out.summary());
  }

  Future<void> _organize() async {
    final String rootId = _repo.root?.rootDocId ?? '';
    if (rootId.isEmpty) {
      moSnack(context, '先选一个曲库目录');
      return;
    }
    final List<VFile> files = _repo.audioFiles();
    if (files.isEmpty) {
      moSnack(context, '曲库里还没有曲目');
      return;
    }
    final List<MovePlan> plans =
        Organizer.plan(files, rootDocId: rootId, onlyUnorganized: true);
    if (plans.isEmpty) {
      moSnack(context, '没有需要归位的曲目');
      return;
    }
    final int conflicts = plans.where((MovePlan p) => p.conflict).length;

    final bool? go = await showMoSheet<bool>(
      context,
      title: '整理计划（${plans.length} 首）',
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: MoKit.pagePad),
          child: Text(
            conflicts > 0
                ? '其中 $conflicts 首目标位置已有同名文件，会跳过（不覆盖）。'
                : '目标位置没有同名文件，可以安全执行。',
            style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context)),
          ),
        ),
        for (final MovePlan p in plans.take(60))
          Padding(
            padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 8, MoKit.pagePad, 0),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text('${p.file.name}  →  ${p.targetPath}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: MoKit.fsCaption,
                          color: p.conflict ? MoKit.warn(context) : MoKit.text(context))),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(MoKit.pagePad),
          child: MoButton('执行移动（${plans.length} 首）', onPressed: () => Navigator.of(context).pop(true)),
        ),
      ],
    );
    if (go != true) return;

    setState(() => _busy = true);
    final RunningTask? task = TaskCenter.start('自动整理');
    final TaskControl? control = task?.control;
    final OrganizeResult r = await Organizer.execute(_repo.store!, plans,
        onProgress: (int done, int total) => control?.report(done, total, '移动中'),
        cancel: control);
    TaskCenter.finish();
    if (!mounted) return;
    setState(() => _busy = false);
    if (r.ok > 0) await _repo.rescan();
    if (!mounted) return;
    moSnack(context, r.summary());
  }

  Future<void> _dedupe(List<VFile> files) async {
    final List<DuplicateGroup> groups = Duplicates.find(files);
    if (!mounted) return;
    if (groups.isEmpty) {
      moSnack(context, '没有发现相似文件名');
      return;
    }
    await showMoSheet<void>(
      context,
      title: '疑似重复 ${groups.length} 组',
      children: <Widget>[
        for (final DuplicateGroup g in groups.take(50))
          Padding(
            padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 6, MoKit.pagePad, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    if (g.suspect)
                      Container(
                        margin: const EdgeInsets.only(right: 6),
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                            color: MoKit.warn(context).withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(6)),
                        child: Text('疑似',
                            style: TextStyle(fontSize: 10, color: MoKit.warn(context))),
                      ),
                    Text('${g.files.length} 个文件',
                        style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
                  ],
                ),
                for (final DuplicateItem item in g.files)
                  Text('· ${item.relative}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: MoKit.fsBody, color: MoKit.text(context))),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _junk(List<VFile> all) async {
    final List<VFile> junk = all.where(Junk.isJunk).toList();
    final bool? go = await showMoSheet<bool>(
      context,
      title: '垃圾文件 ${junk.length} 个',
      children: <Widget>[
        for (final VFile f in junk.take(80))
          Padding(
            padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 6, MoKit.pagePad, 0),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(f.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: MoKit.fsBody, color: MoKit.text(context))),
                ),
                Text(Junk.reasonOf(f),
                    style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(MoKit.pagePad),
          child: MoButton('删除这 ${junk.length} 个文件', primary: false,
              onPressed: () => Navigator.of(context).pop(true)),
        ),
      ],
    );
    if (go != true) return;
    int ok = 0;
    for (final VFile f in junk) {
      if (await _repo.store!.delete(f)) ok++;
    }
    if (!mounted) return;
    await _repo.rescan();
    if (!mounted) return;
    moSnack(context, '已删除 $ok 个');
  }

  /// 批量清理标签文本（只改真需要改的字段，写入走事务）。
  Future<void> _tidy(List<VFile> files) async {
    setState(() => _busy = true);
    final RunningTask? task = TaskCenter.start('清理标签文本');
    final TaskControl? control = task?.control;
    final TagTransaction? tx = _repo.tx;
    if (tx == null) {
      TaskCenter.finish();
      setState(() => _busy = false);
      return;
    }
    const int ops = TagFix.trim | TagFix.spaces | TagFix.width | TagFix.padTrack;
    final String batchId = 'tidy-${DateTime.now().millisecondsSinceEpoch}';
    int changed = 0;
    int skipped = 0;
    int failed = 0;
    int i = 0;
    for (final VFile f in files) {
      if (control?.isCancelled() ?? false) break;
      i++;
      control?.report(i, files.length, f.name);
      final Tags tags = await Scanner.readTags(_repo.store!, f);
      final Map<String, String> plan = TagFix.plan(tags, ops);
      if (plan.isEmpty) {
        skipped++;
        continue;
      }
      final String err = await tx.apply(f, plan, record: true, batchId: batchId);
      if (err.isEmpty) {
        changed++;
        _repo.invalidate(f);
      } else {
        failed++;
      }
    }
    TaskCenter.finish();
    if (!mounted) return;
    setState(() => _busy = false);
    moSnack(context, '改动 $changed 首，无需改动 $skipped 首，失败 $failed 首',
        actionLabel: changed == 0 ? null : '撤销',
        onAction: () async {
          final int n = await undoBatch(batchId);
          if (mounted) moSnack(context, '已撤销 $n 处');
        });
  }
}
