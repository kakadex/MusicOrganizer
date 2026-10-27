/// 批量歌词：多源聚合 → `offerScore` 排序取最优 → 确认后写内嵌歌词 / 同名 .lrc。
///
/// 低置信（< 0.5）默认不勾选，避免把「同名不同版本」的歌词写进去；
/// 写盘走 `TagTransaction`（lyrics 字段），.lrc 作为附带文件单独写。
library;

import 'package:flutter/material.dart';

import '../../app/repo.dart';
import '../../app/ui_kit.dart';
import '../../core/match/local_query.dart';
import '../../core/model/query.dart';
import '../../core/model/tags.dart';
import '../../core/model/task_control.dart';
import '../../core/model/vfile.dart';
import '../../core/scan/scanner.dart';
import '../../core/source/aggregator.dart';
import '../../core/tag/tag_io.dart';
import '../../core/task/task_center.dart';
import '../../core/tx/write_preview.dart';
import '../common/write_confirm_sheet.dart';
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
  /// .lrc 在预览里的行键（不是标签字段，单独判断）。
  static const String _lrcKey = '__lrc';

  late List<LyricRow> _rows;
  bool _fetching = false;
  bool _writing = false;
  bool _fetched = false;
  bool _writeLrc = false;
  /// 歌词是否转简体（设置项可记忆，默认开）。
  bool _simplify = true;

  /// 是否合成双语（原文一行 + 译文一行；只有拿到译文的才生效）。
  bool _bilingual = true;

  @override
  void initState() {
    super.initState();
    _rows = widget.files.map(LyricRow.new).toList();
    _simplify = Repo.instance.settings.get<bool>('lyrics_simplify', fallback: true) ?? true;
    _bilingual =
        Repo.instance.settings.get<bool>('lyrics_bilingual', fallback: true) ?? true;
  }

  int get _selectedCount =>
      _rows.where((LyricRow r) => r.selected && r.choice != null).length;

  /// 当前取词 / 写盘用的控制器（关页时取消，避免后台空跑）。
  TaskControl? _control;

  @override
  void dispose() {
    // 关页时把任务停掉：否则循环会继续跑，下一轮还会摸已卸载的 State。
    if (_fetching || _writing) _control?.cancel();
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
          const SizedBox(width: 6),
          MoChip(
            label: '转简体',
            selected: _simplify,
            onTap: () {
              setState(() => _simplify = !_simplify);
              Repo.instance.setSetting('lyrics_simplify', _simplify);
            },
          ),
          const SizedBox(width: 6),
          MoChip(
            label: '双语',
            selected: _bilingual,
            onTap: () {
              setState(() => _bilingual = !_bilingual);
              Repo.instance.setSetting('lyrics_bilingual', _bilingual);
              for (final LyricRow r in _rows) {
                if (r.choice != null) r.choice!.bilingual = _bilingual;
              }
            },
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
    _control = control;
    final int total = _rows.length;
    int found = 0;
    // 累计各源失败原因（去重），用于「一首都没拿到」时判断是不是联网挂了。
    final Map<String, String> netErrors = <String, String>{};

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
      // 页面可能已经被返回键关掉：此时 setState 会因 State 已卸载而崩
      if (mounted) setState(() {});
      try {
        final Tags tags = await Scanner.readTags(store, row.file);
        final Query q = LocalQuery.forFile(row.file, tags);
        final LyricAggregateResult agg = await Aggregator.lyricCandidates(
            LocalQuery.lyric(q, album: tags.get('album')));
        netErrors.addAll(agg.errors);
        final LyricChoice? best = LyricPick.best(q, agg.hits);
        if (best != null) {
          best.simplify = _simplify;
          best.bilingual = _bilingual;
        }
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
    if (found == 0 && netErrors.isNotEmpty) {
      // 一首都没拿到、但联网源报了错 → 明确告诉用户是网络问题，而不是「没词」。
      final String why = netErrors.values.first;
      moSnack(context,
          '联网取词失败：$why。请检查网络连接或代理设置（设置 → 网络与并发）');
    } else {
      moSnack(context, '找到 $found 首歌词，确认后再写入');
    }
  }

  /// 歌词预览只显示头一行 + 行数，避免把整篇歌词铺进确认面板。
  static String _brief(String text) {
    final String t = text.trim();
    if (t.isEmpty) return '';
    final List<String> lines =
        t.split('\n').where((String s) => s.trim().isNotEmpty).toList();
    final String head = lines.isEmpty ? '' : lines.first.trim();
    return lines.length <= 1 ? head : '$head …（共 ${lines.length} 行）';
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

    // 统一预览：逐首列「原歌词 → 新歌词」，用户可整首 / 逐项勾选
    final List<WriteTarget> targets = plans.map((LyricPlan p) {
      final String old = (p.file.cachedTags?.get(Tags.lyrics) ?? '').trim();
      final List<WriteLine> lines = <WriteLine>[
        WriteLine(
          label: '内嵌歌词',
          oldText: _brief(old),
          newText: _brief(p.choice.text),
          key: Tags.lyrics,
          payload: p.choice.text,
        ),
      ];
      if (_writeLrc) {
        lines.add(WriteLine(
          label: '同名 .lrc',
          oldText: '（随内嵌歌词一起写）',
          newText: '写入 ${p.file.stem()}.lrc',
          key: _lrcKey,
        ));
      }
      return WriteTarget(
        docId: p.file.docId,
        name: p.file.name,
        path: Repo.instance.relPath(p.file),
        kind: WriteKind.lyrics,
        note: p.choice.note,
        lowConfidence: p.choice.low,
        risky: old.isNotEmpty,
        lines: lines,
        data: p,
      );
    }).toList();

    final List<WriteTarget>? picked = await WriteConfirmSheet.show(
      context,
      title: '确认写入歌词',
      subtitle: '取消勾选的曲目不会被写入',
      targets: targets,
      commitLabel: '写入歌词',
      unit: '首',
      verb: '写入',
      expandAll: true,
    );
    if (!mounted || picked == null || picked.isEmpty) return;
    await _write(picked);
  }

  Future<void> _write(List<WriteTarget> picked) async {
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

    for (final WriteTarget t in picked) {
      if (control?.isCancelled() ?? false) break;
      await _waitIfPaused(control);
      final LyricPlan? plan = t.data as LyricPlan?;
      if (plan == null) continue;
      final String text = plan.choice.text;
      final bool wantLrc = _writeLrc &&
          t.lines.any((WriteLine l) => l.key == _lrcKey && l.selected && l.changed);
      final String err = await tx.apply(
        plan.file,
        <String, String>{'lyrics': text},
        batchId: batchId,
      );
      if (err.isEmpty) {
        inlineOk++;
        repo.invalidate(plan.file);
        String lrcErr = '';
        if (wantLrc) {
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
                : (wantLrc ? '已写入内嵌歌词与 .lrc' : '已写入内嵌歌词'));
      } else {
        failed++;
        _setStatus(plan.file, '写入失败：$err');
      }
      done++;
      control?.report(done, picked.length, plan.file.name);
      if (mounted) setState(() {});
    }

    TaskCenter.finish();
    await repo.loadMeta(only: picked
        .map((WriteTarget t) => t.data)
        .whereType<LyricPlan>()
        .map((LyricPlan p) => p.file));
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
