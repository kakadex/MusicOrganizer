import 'package:flutter/material.dart';

import '../../app/repo.dart';
import '../../app/ui_kit.dart';
import '../../core/cleanup/junk.dart';
import '../../core/dedupe/content_reader.dart';
import '../../core/dedupe/duplicates.dart';
import '../../core/fs/file_store.dart';
import '../../core/match/tag_fix.dart';
import '../../core/match/text_util.dart';
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
    final FileStore? store = _repo.store;
    // 第一遍：只比文件名（不读标签，秒出）。把「同名但文件名没写艺人」的候选挑出来，
    // 读它们内嵌标签里的艺人，用来区分翻唱 / 重名 —— 与 Java 版一致，避免把不同歌手的
    // 同名歌曲误判为重复。
    List<DuplicateGroup> groups = Duplicates.find(files);
    if (!mounted) return;
    if (groups.isNotEmpty) {
      final Map<String, VFile> byDoc = <String, VFile>{};
      for (final VFile f in files) {
        byDoc[f.docId] = f;
      }
      final Set<String> need = <String>{};
      for (final DuplicateGroup g in groups) {
        for (final DuplicateItem it in g.files) {
          if (DuplicateGroup.artistKeyOf(it.file.stem()).isEmpty) {
            need.add(it.file.docId);
          }
        }
      }
      if (need.isNotEmpty) {
        final Map<String, String> artistMap = <String, String>{};
        await _readTagArtists(byDoc, need, artistMap);
        if (!mounted) return;
        groups = Duplicates.find(files,
            tagArtist: (VFile f) => artistMap[f.docId] ?? '');
      }
    }
    // 第二遍：拿不准的组去比对内容（大小 + 首尾各 64KB）。文件名只给线索，内容才给结论：
    // 内容对不上的说明只是名字像（不同版本 / 翻唱），不是重复。
    if (groups.isNotEmpty && store != null) {
      setState(() => _busy = true);
      await Duplicates.verifyContent(groups, (VFile f) => ContentReader.sample(store, f));
      if (!mounted) return;
      setState(() => _busy = false);
    }
    if (groups.isEmpty) {
      moSnack(context, '没有发现相似文件名');
      return;
    }
    // 内容不同的组不算重复：单列出来，免得把别人的歌当成重复删了。
    final List<DuplicateGroup> dups = groups
        .where((DuplicateGroup g) => g.content != DuplicateGroup.contentDiff)
        .toList();
    final List<DuplicateGroup> lookalikes = groups
        .where((DuplicateGroup g) => g.content == DuplicateGroup.contentDiff)
        .toList();
    if (dups.isEmpty && lookalikes.isEmpty) {
      moSnack(context, '没有发现重复文件');
      return;
    }
    // 默认勾选：确证重复里「不是建议保留那份」的；疑似与「内容不同」的一律不勾
    // （查重是提示，误删不可逆）。
    final Map<String, bool> picked = <String, bool>{};
    for (final DuplicateGroup g in dups) {
      final int keep = DuplicateGroup.recommendKeep(g);
      for (int i = 0; i < g.files.length; i++) {
        final DuplicateItem it = g.files[i];
        picked[it.file.docId] = i != keep &&
            !g.suspect &&
            g.content != DuplicateGroup.contentDiff;
      }
    }
    for (final DuplicateGroup g in lookalikes) {
      for (final DuplicateItem it in g.files) {
        picked[it.file.docId] = false;
      }
    }
    int pickedCount() => picked.values.where((bool b) => b).length;

    final bool? go = await showMoSheet<bool>(
      context,
      title: dups.isEmpty
          ? '没有发现重复文件'
          : '重复 ${dups.length} 组'
              '${lookalikes.isEmpty ? '' : ' · 另有 ${lookalikes.length} 组只是名字像'}',
      children: <Widget>[
        StatefulBuilder(builder: (BuildContext ctx, StateSetter setSheet) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (dups.isNotEmpty)
                Padding(
                  padding:
                      const EdgeInsets.fromLTRB(MoKit.pagePad, 0, MoKit.pagePad, 4),
                  child: Text('大小与首尾各 64KB 一致，确认为同一份文件：',
                      style: TextStyle(
                          fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
                ),
              for (final DuplicateGroup g in dups.take(50))
                _dupGroup(g, false, picked, setSheet),
              if (lookalikes.isNotEmpty) ...<Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      MoKit.pagePad, 14, MoKit.pagePad, 4),
                  child: Text('只是名字像，内容对不上，不是重复（不勾选）：',
                      style: TextStyle(
                          fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
                ),
                for (final DuplicateGroup g in lookalikes.take(50))
                  _dupGroup(g, true, picked, setSheet),
              ],
              Padding(
                padding: const EdgeInsets.all(MoKit.pagePad),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text('已勾选 ${pickedCount()} 个（每组至少留一个）',
                          style: TextStyle(
                              fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
                    ),
                    MoButton('删除勾选的 ${pickedCount()} 个',
                        primary: false,
                        onPressed: pickedCount() == 0
                            ? null
                            : () => Navigator.of(ctx).pop(true)),
                  ],
                ),
              ),
            ],
          );
        }),
      ],
    );
    if (go != true) return;
    if (!mounted) return;
    // 校验：每组至少留一个，别把唯一一份删了
    for (final DuplicateGroup g in groups) {
      int remain = 0;
      for (final DuplicateItem it in g.files) {
        if (picked[it.file.docId] != true) remain++;
      }
      if (remain == 0) {
        moSnack(context, '有整组都被勾上了，每组至少要留一个 —— 取消后重试');
        return;
      }
    }
    int ok = 0;
    int fail = 0;
    for (final DuplicateGroup g in groups) {
      for (final DuplicateItem it in g.files) {
        if (picked[it.file.docId] != true) continue;
        if (await _repo.store!.delete(it.file)) {
          ok++;
        } else {
          fail++;
        }
      }
    }
    if (!mounted) return;
    await _repo.rescan();
    if (!mounted) return;
    moSnack(context, '已删除 $ok 个${fail > 0 ? '，失败 $fail 个' : ''}');
  }

  /// 查重结果里的一组。[lookalike] 为 true 表示「名字像但内容不同」。
  Widget _dupGroup(DuplicateGroup g, bool lookalike, Map<String, bool> picked,
      StateSetter setSheet) {
    final Color tag = lookalike ? MoKit.sub(context) : MoKit.ok(context);
    final int keep = DuplicateGroup.recommendKeep(g);
    return Padding(
      padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 6, MoKit.pagePad, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                margin: const EdgeInsets.only(right: 6),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                    color: tag.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(6)),
                child: Text(lookalike ? '内容不同' : '内容一致',
                    style: TextStyle(fontSize: 10, color: tag)),
              ),
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
              Expanded(
                child: Text('${g.files.length} 个文件 · 相似度 ${(g.score * 100).round()}%',
                    style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
              ),
            ],
          ),
          for (int i = 0; i < g.files.length; i++)
            _dupFileRow(g, i, keep, picked, setSheet),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(lookalike
                ? '首尾采样对不上 —— 不是同一份内容（可能是不同版本或别人的翻唱）。'
                : '重复占用约 ${TextUtil.formatSize(g.wastedBytes())}',
                style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
          ),
        ],
      ),
    );
  }

  /// 组里的一行（带勾选框）。
  Widget _dupFileRow(DuplicateGroup g, int index, int keep,
      Map<String, bool> picked, StateSetter setSheet) {
    final DuplicateItem it = g.files[index];
    final bool isKeep = index == keep;
    final bool on = picked[it.file.docId] == true;
    return Row(
      children: <Widget>[
        SizedBox(
          width: 28,
          height: 28,
          child: Checkbox(
            value: on,
            onChanged: (bool? v) =>
                setSheet(() => picked[it.file.docId] = v == true),
            visualDensity: VisualDensity.compact,
          ),
        ),
        Expanded(
          child: Text('${it.relative}'
              '${it.size > 0 ? '（${TextUtil.formatSize(it.size)}）' : ''}'
              '${isKeep ? '  · 建议保留' : ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: MoKit.fsBody, color: MoKit.text(context))),
        ),
      ],
    );
  }

  /// 给候选文件补读内嵌标签艺人（只限 [docIds]，带缓存、限并发 8），让查重能用艺人区分
  /// 翻唱 / 重名。结果写进 [out]（docId → 原始艺人串，由 [Duplicates.find] 归一）。
  Future<void> _readTagArtists(Map<String, VFile> byDoc, Set<String> docIds,
      Map<String, String> out) async {
    final List<VFile> targets = docIds
        .where((String id) => byDoc.containsKey(id))
        .map((String id) => byDoc[id]!)
        .toList();
    const int k = 8;
    for (int i = 0; i < targets.length; i += k) {
      final int end = i + k < targets.length ? i + k : targets.length;
      final List<VFile> batch = targets.sublist(i, end);
      await Future.wait(batch.map((VFile f) async {
        try {
          final Tags t = await Scanner.readTags(_repo.store!, f);
          final String a = t.get('artist').trim();
          if (a.isNotEmpty) out[f.docId] = a;
        } catch (_) {
          // 读不到就当没有艺人，退回文件名 + 时长判定
        }
      }));
    }
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

  /// 批量清理标签文本（只改真需要改的字段）。
  ///
  /// **两步**：先逐首算出「哪些字段要改、改成什么」并出预览（旧值 → 新值），
  /// 用户确认后才写盘（写盘走事务）。这是本项目的硬约束——
  /// 任何写入 / 改动都必须先预览再写，清理标签也不例外。
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
    // 第一遍：只算计划，不写盘。
    final List<_TidyItem> items = <_TidyItem>[];
    int i = 0;
    for (final VFile f in files) {
      if (control?.isCancelled() ?? false) break;
      i++;
      control?.report(i, files.length, f.name);
      final Tags tags = await Scanner.readTags(_repo.store!, f);
      final Map<String, String> plan = TagFix.plan(tags, ops);
      if (plan.isEmpty) continue;
      final List<_TidyChange> changes = <_TidyChange>[];
      for (final MapEntry<String, String> e in plan.entries) {
        changes.add(_TidyChange(e.key, tags.get(e.key), e.value));
      }
      items.add(_TidyItem(f, changes));
    }
    TaskCenter.finish();
    if (!mounted) return;
    setState(() => _busy = false);
    if (items.isEmpty) {
      moSnack(context, '没有需要清理的标签');
      return;
    }
    // 预览确认：逐首展开旧值 → 新值。
    final bool? go = await showMoSheet<bool>(
      context,
      title: '清理预览（${items.length} 首）',
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 0, MoKit.pagePad, 8),
          child: Text(
            '仅做本地文本整理：去首尾空白 / 折叠多余空格 / 全角转半角 / 音轨号补零。'
            '确认后才写盘，可撤销。',
            style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context)),
          ),
        ),
        for (final _TidyItem it in items.take(80)) _tidyPreviewRow(it),
        Padding(
          padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 10, MoKit.pagePad, 8),
          child: MoButton('执行清理（${items.length} 首）',
              onPressed: () => Navigator.of(context).pop(true)),
        ),
      ],
    );
    if (go != true) return;

    // 第二遍：确认后才写盘。
    setState(() => _busy = true);
    final RunningTask? wTask = TaskCenter.start('写入清理');
    final TaskControl? wControl = wTask?.control;
    final String batchId = 'tidy-${DateTime.now().millisecondsSinceEpoch}';
    int changed = 0;
    int failed = 0;
    int done = 0;
    for (final _TidyItem it in items) {
      if (wControl?.isCancelled() ?? false) break;
      final Map<String, String> plan = <String, String>{
        for (final _TidyChange c in it.changes) c.field: c.newValue
      };
      final String err = await tx.apply(it.file, plan, record: true, batchId: batchId);
      if (err.isEmpty) {
        changed++;
        _repo.invalidate(it.file);
      } else {
        failed++;
      }
      done++;
      wControl?.report(done, items.length, it.file.name);
    }
    TaskCenter.finish();
    if (!mounted) return;
    setState(() => _busy = false);
    moSnack(context, '改动 $changed 首，失败 $failed 首',
        actionLabel: changed == 0 ? null : '撤销',
        onAction: () async {
          final int n = await undoBatch(batchId);
          if (mounted) moSnack(context, '已撤销 $n 处');
        });
  }

  /// 预览里一首歌的改动清单。
  Widget _tidyPreviewRow(_TidyItem it) {
    return Container(
      margin: const EdgeInsets.fromLTRB(MoKit.pagePad, 0, MoKit.pagePad, 8),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: MoKit.card(context),
        borderRadius: BorderRadius.circular(MoKit.radiusRow),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(it.file.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: MoKit.fsBody,
                  fontWeight: FontWeight.w500,
                  color: MoKit.text(context))),
          const SizedBox(height: 4),
          for (final _TidyChange c in it.changes)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text.rich(TextSpan(children: <TextSpan>[
                TextSpan(
                    text: '${_tidyFieldName(c.field)}：',
                    style: TextStyle(
                        fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
                TextSpan(
                    text: c.oldValue.isEmpty ? '（空）' : c.oldValue,
                    style: TextStyle(
                        fontSize: MoKit.fsBody, color: MoKit.faint(context))),
                TextSpan(
                    text: '  →  ',
                    style: TextStyle(
                        fontSize: MoKit.fsBody, color: MoKit.faint(context))),
                TextSpan(
                    text: c.newValue,
                    style: TextStyle(
                        fontSize: MoKit.fsBody,
                        fontWeight: FontWeight.w500,
                        color: MoKit.text(context))),
              ])),
            ),
        ],
      ),
    );
  }

  String _tidyFieldName(String key) {
    switch (key) {
      case 'title':
        return '标题';
      case 'artist':
        return '歌手';
      case 'album':
        return '专辑';
      case 'year':
        return '年份';
      case 'track':
        return '音轨';
      case 'genre':
        return '流派';
      default:
        return key;
    }
  }
}

/// 清理预览：一首歌 + 它的字段改动。
class _TidyItem {
  const _TidyItem(this.file, this.changes);

  final VFile file;
  final List<_TidyChange> changes;
}

/// 单个字段的旧值 → 新值。
class _TidyChange {
  const _TidyChange(this.field, this.oldValue, this.newValue);

  final String field;
  final String oldValue;
  final String newValue;
}
