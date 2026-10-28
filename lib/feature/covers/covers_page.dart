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
import '../../core/match/match_queue.dart';
import '../../core/net/net.dart';
import '../../core/model/journal_entry.dart' show JournalOp;
import '../../core/model/query.dart';
import '../../core/model/tags.dart';
import '../../core/model/task_control.dart';
import '../../core/model/vfile.dart';
import '../../core/net/http_client.dart';
import '../../core/scan/scanner.dart';
import '../../core/source/aggregator.dart';
import '../../core/tag/tag_io.dart';
import '../../core/task/task_center.dart';
import '../../core/tx/write_preview.dart';
import '../common/write_confirm_sheet.dart';
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

  /// 封面在预览里的行键（不是标签字段，单独取字节）。
  static const String _coverKey = '__cover';

  late List<CoverJob> _jobs;
  final List<CoverUndo> _undo = <CoverUndo>[];
  bool _busy = false;
  bool _done = false;
  int _written = 0;
  int _failed = 0;
  int _skipped = 0;
  int _noCover = 0;

  /// 当前任务控制器：退出页面时取消，避免关页后还在后台跑。
  TaskControl? _control;

  /// 续跑队列（记住「哪首查到了封面地址、还没写」）。
  MatchQueue? _queue;

  /// 从上次中断处恢复出来的条数。
  int _resumed = 0;

  /// 用户点了「重新开始」：清掉续跑进度，这一轮全部重新查。
  bool _restarted = false;

  @override
  void initState() {
    super.initState();
    _jobs = widget.files.map(CoverJob.new).toList();
    _queue = Repo.instance.coverQueue;
    _resume();
  }

  /// 接上上次没写完的那批：指纹一致才认，文件被换过就当场作废。
  void _resume() {
    final MatchQueue? q = _queue;
    if (q == null) return;
    int n = 0;
    for (final CoverJob job in _jobs) {
      final MatchItem? item =
          q.take(_keyOf(job.file), job.file.size, job.file.lastModified);
      if (item == null) continue;
      final String url = item.field('url', '');
      if (url.isEmpty) continue;
      job.resumeUrl = url;
      job.resumed = true;
      job.note = '上次查到的封面（未写入）';
      n++;
    }
    _resumed = n;
  }

  /// 续跑用的键：有 docId 用它，没有就退回文件名。
  static String _keyOf(VFile f) => f.docId.isNotEmpty ? f.docId : f.name;

  @override
  void dispose() {
    if (_busy) _control?.cancel();
    super.dispose();
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
    // 续跑：上次查到但没写完的，进来就是「待确认」，不用再等一轮联网
    if (_resumed > 0 && !_restarted) {
      return '继续上次 $_resumed/${_jobs.length} 首（已查到，待确认写入）';
    }
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
          if (_resumed > 0 && !_restarted)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: MoButton('重新开始', primary: false, onPressed: _busy ? null : _restart),
            ),
          MoButton(_done ? '再跑一次' : '开始补封面',
              busy: _busy, onPressed: _busy ? null : _run),
        ],
      ),
    );
  }

  /// 丢掉上次的进度，这一轮全部重新联网查。
  Future<void> _restart() async {
    _queue?.clear();
    if (!mounted) return;
    setState(() {
      _restarted = true;
      _resumed = 0;
      _done = false;
      for (final CoverJob job in _jobs) {
        job.forgetResume();
        job.reset();
      }
    });
    await _run();
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
    // 「再跑一次」（_done 已为 true）要清掉续跑地址重新联网；
    // 首次「开始补封面」要保留续跑地址，接着上次跳过已查到的。
    final bool rerun = _done;
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
        if (rerun) job.forgetResume();
      }
    });

    final running = TaskCenter.start('查找封面');
    _control = running?.control;
    final control = running?.control;
    final int total = _jobs.length;

    // ① 先把所有封面抓到内存（这一步不动盘）。
    // 用文件级并发（默认 3）跑：500 首串行要 20-40 分钟，这里压到几分钟。
    try {
      await Net.mapIndexed<CoverJob, void>(
          _jobs, Net.fileConcurrency(), control, (int i, CoverJob job) async {
        if (control?.isCancelled() ?? false) return;
        await _waitIfPaused(control);
        control?.report(i, total, job.file.name);
        if (!TagIO.canWrite(job.file.ext())) {
          _skipped++;
          _update(job, CoverPhase.skipped, '跳过：${job.file.ext()} 不支持写标签');
          control?.report(i + 1, total, job.file.name);
          return;
        }
        _update(job, CoverPhase.working, '查找在线封面…');
        try {
          // 上次已经查到过地址的：直接用，不再联网问一遍（省时间也省配额）
          String url = job.resumeUrl;
          if (url.isEmpty) {
            final Tags tags = await Scanner.readTags(store, job.file);
            final Query q = LocalQuery.forFile(job.file, tags);
            final AggregateResult agg = await Aggregator.tagCandidates(
                q, chinese: LocalQuery.chinese(q));
            url = CoverPick.urlOf(agg.candidates);
            if (url.isNotEmpty) {
              _queue?.put(
                _keyOf(job.file),
                job.file.size,
                job.file.lastModified,
                <String, String>{'url': url},
              );
            }
          }
          if (url.isEmpty) {
            _noCover++;
            _update(job, CoverPhase.noCover, '没有带封面的候选');
            control?.report(i + 1, total, job.file.name);
            return;
          }
          _update(job, CoverPhase.working, '下载封面…');
          final Uint8List? bytes = await Http.getBytes(
              url, null, null, Http.readTimeoutOverseasMs, _maxDownloadBytes);
          if (bytes == null || !CoverPick.looksLikeImage(bytes)) {
            _failed++;
            _update(job, CoverPhase.failed,
                bytes == null ? '下载失败' : '返回的不是图片');
            control?.report(i + 1, total, job.file.name);
            return;
          }
          job.pendingBytes = bytes;
          job.previousBytes = await Scanner.readCover(store, job.file);
          _update(
              job,
              CoverPhase.ready,
              '待确认：${(bytes.lengthInBytes / 1024).round()} KB'
                  '${job.previousBytes == null ? '' : '（将覆盖已有封面）'}');
        } catch (e) {
          _failed++;
          _update(job, CoverPhase.failed, '出错：$e');
        }
        control?.report(i + 1, total, job.file.name);
      });
    } finally {
      TaskCenter.finish();
    }
    if (!mounted) return;
    setState(() => _busy = false);

    // ② 预览：让用户逐首决定写不写
    final List<CoverJob> ready = _jobs
        .where((CoverJob j) => j.phase == CoverPhase.ready && j.pendingBytes != null)
        .toList();
    if (ready.isEmpty) {
      setState(() => _done = true);
      moSnack(context,
          '没有可写入的封面（无封面 $_noCover 首，跳过 $_skipped 首，失败 $_failed 首）');
      return;
    }
    final List<WriteTarget> targets = ready.map((CoverJob j) {
      final bool overwriting = j.previousBytes != null && j.previousBytes!.isNotEmpty;
      return WriteTarget(
        docId: j.file.docId,
        name: j.file.name,
        path: repo.relPath(j.file),
        kind: WriteKind.cover,
        note: '${(j.pendingBytes!.lengthInBytes / 1024).round()} KB'
            '${overwriting ? ' · 将覆盖已有封面' : ''}',
        risky: overwriting,
        lines: <WriteLine>[
          WriteLine(
            label: '封面',
            oldText: overwriting ? '已有封面' : '（空）',
            newText: '在线封面 ${(j.pendingBytes!.lengthInBytes / 1024).round()} KB',
            key: _coverKey,
            payload: j.pendingBytes,
          ),
        ],
        data: j,
      );
    }).toList();

    final List<WriteTarget>? picked = await WriteConfirmSheet.show(
      context,
      title: '确认写入封面',
      subtitle: '共找到 ${ready.length} 张封面，勾选要写入的曲目',
      targets: targets,
      commitLabel: '写入封面',
      unit: '首',
      verb: '写入',
      expandAll: true,
    );
    if (!mounted || picked == null || picked.isEmpty) {
      setState(() => _done = true);
      for (final CoverJob j in ready) {
        j.pendingBytes = null;
      }
      return;
    }

    // ③ 只写勾中的那些
    final String batchId = 'covers-${DateTime.now().millisecondsSinceEpoch}';
    setState(() => _busy = true);
    final TaskControl? wc = TaskCenter.start('写入封面')?.control;
    _control = wc;
    final int wt = picked.length;
    int wi = 0;
    try {
      for (final WriteTarget t in picked) {
        final CoverJob? j = t.data as CoverJob?;
        if (j == null) continue;
        wc?.report(wi, wt, j.file.name);
        final String err = await tx.apply(
          j.file,
          const <String, String>{},
          cover: j.pendingBytes,
          batchId: batchId,
          op: JournalOp.cover,
        );
        if (err.isEmpty) {
          _written++;
          repo.invalidate(j.file);
          _undo.add(CoverUndo(j.file, j.previousBytes));
          // 落地了：从续跑队列收尾，下次进来不再当成「没写完」
          _queue?.mark(_keyOf(j.file), MatchQueue.written);
          _update(j, CoverPhase.written, '已写入内嵌封面');
        } else {
          _failed++;
          // 失败的留着下次重试（指纹变了会自动作废）
          _queue?.mark(_keyOf(j.file), MatchQueue.failed);
          _update(j, CoverPhase.failed, err);
        }
        j.pendingBytes = null;
        wi++;
        wc?.report(wi, wt, j.file.name);
      }
    } finally {
      TaskCenter.finish();
    }

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
    try {
      for (final CoverUndo item in List<CoverUndo>.of(_undo)) {
        final String err = await tx.apply(item.file, const <String, String>{},
            cover: item.previous ?? Uint8List(0));
        if (err.isEmpty) {
          restored++;
          repo.invalidate(item.file);
        }
      }
    } finally {
      TaskCenter.finish();
    }
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
