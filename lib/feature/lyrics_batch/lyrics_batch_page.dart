/// 批量歌词：多源聚合 → `offerScore` 排序取最优 → 确认后写内嵌歌词 / 同名 .lrc。
///
/// 低置信（< 0.5）默认不勾选，避免把「同名不同版本」的歌词写进去；
/// 写盘走 `TagTransaction`（lyrics 字段），.lrc 作为附带文件单独写。
library;

import 'package:flutter/material.dart';

import '../../app/repo.dart';
import '../../app/ui_kit.dart';
import '../../core/match/local_query.dart';
import '../../core/model/lyric_hit.dart';
import '../../core/model/query.dart';
import '../../core/model/tags.dart';
import '../../core/model/task_control.dart';
import '../../core/model/vfile.dart';
import '../../core/scan/scanner.dart';
import '../../core/source/aggregator.dart';
import '../../core/tag/tag_io.dart';
import '../../core/task/task_center.dart';
import 'lyrics_confirm_sheet.dart';
import 'lyrics_lrc_writer.dart';
import 'lyrics_logic.dart';
import 'lyrics_row_tile.dart';

/// 批量歌词页面。
class LyricsBatchPage extends StatefulWidget {
  const LyricsBatchPage({super.key, required this.files});

  final List<VFile> files;

  @override
  State<LyricsBatchPage> createState() => _LyricsBatchPageState();
}

class _LyricsBatchPageState extends State<LyricsBatchPage> {
  late List<LyricRow> _rows;
  bool _fetching = false;
  bool _writing = false;
  bool _fetched = false;
  bool _writeLrc = false;

  @override
  void initState() {
    super.initState();
    _rows = widget.files.map(LyricRow.new).toList();
  }

  int get _selectedCount =>
      _rows.where((LyricRow r) => r.selected && r.choice != null).length;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: <Widget>[
            PageHeader(
              title: '批量歌词',
              subtitle: _subtitle(),
              actions: <Widget>[
                if (Navigator.of(context).canPop())
                  IconButton(
                    tooltip: '返回',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: Icon(Icons.arrow_back,
                        size: 20, color: MoKit.text(context)),
                  ),
                MoButton(_fetched ? '重新获取' : '获取歌词',
                    busy: _fetching, onPressed: _fetching || _writing ? null : _fetchAll),
              ],
            ),
            Expanded(child: _body()),
            if (_rows.isNotEmpty) _bottomBar(),
            const TaskBar(),
          ],
        ),
      ),
    );
  }

  String _subtitle() {
    if (_rows.isEmpty) return '没有曲目';
    if (_fetching) return '正在搜索 ${_rows.length} 首';
    if (_writing) return '正在写入 $_selectedCount 首';
    if (!_fetched) return '${_rows.length} 首 · 多源取词，先确认再写';
    final int found = _rows.where((LyricRow r) => r.choice != null).length;
    final int low = _rows.where((LyricRow r) => r.choice?.low ?? false).length;
    return '找到 $found 首${low > 0 ? '（低置信 $low 首默认不勾选）' : ''}';
  }

  Widget _body() {
    if (_rows.isEmpty) {
      return const EmptyState(
        icon: Icons.lyrics_outlined,
        text: '没有可处理的曲目',
        hint: '先在音乐库里选中曲目再进来',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 12),
      itemCount: _rows.length,
      itemBuilder: (BuildContext c, int i) => _row(_rows[i]),
    );
  }

  Widget _row(LyricRow row) {
    return LyricRowTile(
      row: row,
      onTap: row.choice == null
          ? null
          : () => setState(() => row.selected = !row.selected),
    );
  }

  Widget _bottomBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 8, MoKit.pagePad, 10),
      color: MoKit.card(context),
      child: Row(
        children: <Widget>[
          MoChip(
            label: '同时写同名 .lrc',
            selected: _writeLrc,
            onTap: () => setState(() => _writeLrc = !_writeLrc),
          ),
          const Spacer(),
          MoButton('写入 $_selectedCount 首',
              busy: _writing,
              onPressed: _selectedCount == 0 || _writing || _fetching
                  ? null
                  : _confirmWrite),
        ],
      ),
    );
  }

  Future<void> _fetchAll() async {
    final store = Repo.instance.store;
    if (store == null) {
      moSnack(context, '还没有准备好文件访问');
      return;
    }
    if (TaskCenter.isBusy()) {
      moSnack(context, '已有任务在跑，先等它结束');
      return;
    }
    setState(() {
      _fetching = true;
      _fetched = false;
      for (final LyricRow row in _rows) {
        row.reset();
      }
    });

    final running = TaskCenter.start('取歌词');
    final control = running?.control;
    final int total = _rows.length;
    int found = 0;

    for (int i = 0; i < total; i++) {
      if (control?.isCancelled() ?? false) break;
      await _waitIfPaused(control);
      final LyricRow row = _rows[i];
      control?.report(i, total, row.file.name);
      if (!TagIO.canWriteLyrics(row.file.ext())) {
        row.status = '跳过：${row.file.ext()} 不支持内嵌歌词';
        control?.report(i + 1, total, row.file.name);
        if (mounted) setState(() {});
        continue;
      }
      row.status = '搜索歌词…';
      setState(() {});
      try {
        final Tags tags = await Scanner.readTags(store, row.file);
        final Query q = LocalQuery.forFile(row.file, tags);
        final List<LyricHit> hits = await Aggregator.lyricCandidates(
            LocalQuery.lyric(q, album: tags.get('album')));
        final LyricChoice? best = LyricPick.best(q, hits);
        row.choice = best;
        row.selected = best != null && !best.low;
        row.status = best == null
            ? '没有合格歌词'
            : (best.low ? '低置信，默认不勾选' : '已选中');
        if (best != null) found++;
      } catch (e) {
        row.status = '搜索失败：$e';
      }
      control?.report(i + 1, total, row.file.name);
      if (mounted) setState(() {});
    }

    TaskCenter.finish();
    if (!mounted) return;
    setState(() {
      _fetching = false;
      _fetched = true;
    });
    moSnack(context, '找到 $found 首歌词，确认后再写入');
  }

  Future<void> _confirmWrite() async {
    final List<LyricPlan> plans = <LyricPlan>[
      for (final LyricRow row in _rows)
        if (row.selected && row.choice != null && row.choice!.text.isNotEmpty)
          LyricPlan(file: row.file, choice: row.choice!),
    ];
    if (plans.isEmpty) {
      moSnack(context, '没有勾选可写入的歌词');
      return;
    }
    final bool? ok = await LyricsConfirmSheet.show(context,
        plans: plans, writeLrc: _writeLrc);
    if (ok != true || !mounted) return;
    await _write(plans);
  }

  Future<void> _write(List<LyricPlan> plans) async {
    final Repo repo = Repo.instance;
    final store = repo.store;
    final tx = repo.tx;
    if (store == null || tx == null) {
      moSnack(context, '还没有准备好写盘通道');
      return;
    }
    setState(() => _writing = true);
    final running = TaskCenter.start('写入歌词');
    final control = running?.control;
    final String batchId = 'lyrics-${DateTime.now().millisecondsSinceEpoch}';
    int inlineOk = 0;
    int lrcOk = 0;
    int failed = 0;
    int done = 0;

    for (final LyricPlan plan in plans) {
      if (control?.isCancelled() ?? false) break;
      await _waitIfPaused(control);
      final String text = plan.choice.text;
      final String err = await tx.apply(
        plan.file,
        <String, String>{'lyrics': text},
        batchId: batchId,
      );
      if (err.isEmpty) {
        inlineOk++;
        repo.invalidate(plan.file);
        String lrcErr = '';
        if (_writeLrc) {
          lrcErr = await LyricLrcWriter.write(store, plan.file, text);
          if (lrcErr.isEmpty) {
            lrcOk++;
          } else {
            failed++;
          }
        }
        _setStatus(
            plan.file,
            lrcErr.isNotEmpty
                ? '歌词已写入，.lrc 失败：$lrcErr'
                : (_writeLrc ? '已写入内嵌歌词与 .lrc' : '已写入内嵌歌词'));
      } else {
        failed++;
        _setStatus(plan.file, '写入失败：$err');
      }
      done++;
      control?.report(done, plans.length, plan.file.name);
      if (mounted) setState(() {});
    }

    TaskCenter.finish();
    await repo.loadMeta(only: plans.map((LyricPlan p) => p.file));
    if (!mounted) return;
    setState(() => _writing = false);
    final String summary = '内嵌歌词 $inlineOk 首'
        '${_writeLrc ? '，.lrc $lrcOk 个' : ''}${failed > 0 ? '，失败 $failed 处' : ''}';
    moSnack(context, summary);
  }

  void _setStatus(VFile file, String status) {
    for (final LyricRow row in _rows) {
      if (row.file.docId == file.docId) {
        row.status = status;
        break;
      }
    }
  }

  Future<void> _waitIfPaused(TaskControl? control) async {
    while (control != null && control.isPaused() && !control.isCancelled()) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
  }
}
