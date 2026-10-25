/// 封面批量：按候选封面地址下载，逐首写内嵌封面。
///
/// 全程走 `TagTransaction`（封面字节），写完逐首 [Repo.invalidate]；
/// 封面变更不进 journal（回滚只回字段），所以这里在内存里记下「写之前那张」，
/// 任务结束后可以一键恢复。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app/repo.dart';
import '../../app/ui_kit.dart';
import '../../core/match/local_query.dart';
import '../../core/model/query.dart';
import '../../core/model/tags.dart';
import '../../core/model/task_control.dart';
import '../../core/model/vfile.dart';
import '../../core/net/http_client.dart';
import '../../core/scan/scanner.dart';
import '../../core/source/aggregator.dart';
import '../../core/tag/tag_io.dart';
import '../../core/task/task_center.dart';
import 'covers_logic.dart';
import 'covers_progress.dart';

/// 封面批量页面。
class CoversPage extends StatefulWidget {
  const CoversPage({super.key, required this.files});

  final List<VFile> files;

  @override
  State<CoversPage> createState() => _CoversPageState();
}

class _CoversPageState extends State<CoversPage> {
  static const int _maxDownloadBytes = 8 * 1024 * 1024;

  late List<CoverJob> _jobs;
  final List<CoverUndo> _undo = <CoverUndo>[];
  bool _busy = false;
  bool _done = false;
  int _written = 0;
  int _failed = 0;
  int _skipped = 0;
  int _noCover = 0;

  @override
  void initState() {
    super.initState();
    _jobs = widget.files.map(CoverJob.new).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: <Widget>[
            PageHeader(
              title: '封面批量',
              subtitle: _subtitle(),
              actions: <Widget>[
                if (Navigator.of(context).canPop())
                  IconButton(
                    tooltip: '返回',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: Icon(Icons.arrow_back,
                        size: 20, color: MoKit.text(context)),
                  ),
              ],
            ),
            Expanded(child: _body()),
            if (_jobs.isNotEmpty) _startBar(),
            const TaskBar(),
          ],
        ),
      ),
    );
  }

  String _subtitle() {
    if (_jobs.isEmpty) return '没有曲目';
    if (_busy) return '正在处理 ${_jobs.length} 首';
    if (!_done) return '${_jobs.length} 首 · 只补在线封面，不改标签';
    return '写入 $_written · 无封面 $_noCover · 跳过 $_skipped · 失败 $_failed';
  }

  Widget _body() {
    if (_jobs.isEmpty) {
      return const EmptyState(
        icon: Icons.image_not_supported,
        text: '没有可处理的曲目',
        hint: '先在音乐库里选中曲目再进来',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 12),
      itemCount: _jobs.length,
      itemBuilder: (BuildContext c, int i) => _row(_jobs[i]),
    );
  }

  Widget _row(CoverJob job) => CoverJobRow(job: job);

  Widget _startBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 8, MoKit.pagePad, 10),
      color: MoKit.card(context),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              _done && _undo.isNotEmpty ? '可撤销本次写入的 ${_undo.length} 首' : '',
              style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context)),
            ),
          ),
          if (_done && _undo.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: MoButton('撤销', primary: false, onPressed: _undoAll),
            ),
          MoButton(_done ? '再跑一次' : '开始补封面',
              busy: _busy, onPressed: _busy ? null : _run),
        ],
      ),
    );
  }

  Future<void> _run() async {
    final Repo repo = Repo.instance;
    final store = repo.store;
    final tx = repo.tx;
    if (store == null || tx == null) {
      moSnack(context, '还没有准备好文件访问');
      return;
    }
    if (TaskCenter.isBusy()) {
      moSnack(context, '已有任务在跑，先等它结束');
      return;
    }
    setState(() {
      _busy = true;
      _done = false;
      _written = 0;
      _failed = 0;
      _skipped = 0;
      _noCover = 0;
      _undo.clear();
      for (final CoverJob job in _jobs) {
        job.reset();
      }
    });

    final running = TaskCenter.start('补封面');
    final control = running?.control;
    final String batchId = 'covers-${DateTime.now().millisecondsSinceEpoch}';
    final int total = _jobs.length;

    for (int i = 0; i < total; i++) {
      if (control?.isCancelled() ?? false) break;
      await _waitIfPaused(control);
      final CoverJob job = _jobs[i];
      control?.report(i, total, job.file.name);
      if (!TagIO.canWrite(job.file.ext())) {
        _skipped++;
        _update(job, CoverPhase.skipped, '跳过：${job.file.ext()} 不支持写标签');
        control?.report(i + 1, total, job.file.name);
        continue;
      }
      _update(job, CoverPhase.working, '查找在线封面…');
      try {
        final Tags tags = await Scanner.readTags(store, job.file);
        final Query q = LocalQuery.forFile(job.file, tags);
        final AggregateResult agg = await Aggregator.tagCandidates(
            q, chinese: LocalQuery.chinese(q));
        final String url = CoverPick.urlOf(agg.candidates);
        if (url.isEmpty) {
          _noCover++;
          _update(job, CoverPhase.noCover, '没有带封面的候选');
          control?.report(i + 1, total, job.file.name);
          continue;
        }
        _update(job, CoverPhase.working, '下载封面…');
        final Uint8List? bytes = await Http.getBytes(
            url, null, null, Http.readTimeoutOverseasMs, _maxDownloadBytes);
        if (bytes == null || !CoverPick.looksLikeImage(bytes)) {
          _failed++;
          _update(job, CoverPhase.failed,
              bytes == null ? '下载失败' : '返回的不是图片');
          control?.report(i + 1, total, job.file.name);
          continue;
        }
        final Uint8List? previous = await Scanner.readCover(store, job.file);
        _update(job, CoverPhase.working, '写入封面…');
        final String err = await tx.apply(
          job.file,
          const <String, String>{},
          cover: bytes,
          batchId: batchId,
        );
        if (err.isEmpty) {
          _written++;
          repo.invalidate(job.file);
          _undo.add(CoverUndo(job.file, previous));
          _update(job, CoverPhase.written, '已写入内嵌封面');
        } else {
          _failed++;
          _update(job, CoverPhase.failed, err);
        }
      } catch (e) {
        _failed++;
        _update(job, CoverPhase.failed, '出错：$e');
      }
      control?.report(i + 1, total, job.file.name);
    }

    TaskCenter.finish();
    // 写完刷新这些文件的元数据（封面标记 / 列表封面都要重新读）
    await repo.loadMeta(only: _jobs.map((CoverJob j) => j.file));
    if (!mounted) return;
    setState(() {
      _busy = false;
      _done = true;
    });
    final String summary = '写入 $_written 首，无封面 $_noCover 首，'
        '跳过 $_skipped 首，失败 $_failed 首';
    moSnack(context, summary,
        actionLabel: _written == 0 ? null : '撤销', onAction: _undoAll);
  }

  void _update(CoverJob job, CoverPhase phase, String note) {
    if (!mounted) return;
    setState(() {
      job.phase = phase;
      job.note = note;
    });
  }

  Future<void> _undoAll() async {
    final Repo repo = Repo.instance;
    final tx = repo.tx;
    if (tx == null || _undo.isEmpty || TaskCenter.isBusy()) return;
    setState(() => _busy = true);
    TaskCenter.start('撤销封面');
    int restored = 0;
    for (final CoverUndo item in List<CoverUndo>.of(_undo)) {
      final String err = await tx.apply(item.file, const <String, String>{},
          cover: item.previous ?? Uint8List(0));
      if (err.isEmpty) {
        restored++;
        repo.invalidate(item.file);
      }
    }
    TaskCenter.finish();
    await repo.loadMeta(only: _undo.map((CoverUndo u) => u.file));
    if (!mounted) return;
    setState(() {
      _busy = false;
      _undo.clear();
      _written = 0;
      _done = false;
      for (final CoverJob job in _jobs) {
        if (job.phase == CoverPhase.written) job.reset();
      }
    });
    moSnack(context, '已恢复 $restored 首的封面');
  }

  Future<void> _waitIfPaused(TaskControl? control) async {
    while (control != null && control.isPaused() && !control.isCancelled()) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
  }
}
