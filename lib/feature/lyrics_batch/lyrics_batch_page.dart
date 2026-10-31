/// 批量歌词：多源聚合 → `offerScore` 排序取最优 → 确认后写内嵌歌词 / 同名 .lrc。
///
/// 低置信（< 0.5）默认不勾选，避免把「同名不同版本」的歌词写进去；
/// 写盘走 `TagTransaction`（lyrics 字段 + 同名 .lrc 一起进同一个事务）。
library;

import 'package:flutter/material.dart';

import '../../app/repo.dart';
import '../../app/ui_kit.dart';
import '../../core/match/local_query.dart';
import '../../core/match/match_queue.dart';
import '../../core/model/query.dart';
import '../../core/model/lyric_hit.dart';
import '../../core/model/tags.dart';
import '../../core/model/task_control.dart';
import '../../core/model/vfile.dart';
import '../../core/net/net.dart';
import '../../core/scan/scanner.dart';
import '../../core/source/aggregator.dart';
import '../../core/source/source_registry.dart';
import '../../core/tag/tag_io.dart';
import '../../core/task/task_center.dart';
import '../../core/tx/lrc_sidecar.dart';
import '../../core/tx/write_preview.dart';
import '../common/write_confirm_sheet.dart';
import 'lyrics_candidate_sheet.dart';
import 'lyrics_logic.dart';
import 'lyrics_row_tile.dart';

/// 批量歌词页面。
class LyricsBatchPage extends StatefulWidget {
  const LyricsBatchPage({super.key, required this.files});

  final List<VFile> files;

  /// 测试用：替换真实的取词通道，好统计「到底联网查了几首」。
  /// 生产环境保持 null，走 [Aggregator.lyricCandidates]。
  @visibleForTesting
  static Future<LyricAggregateResult> Function(Object query)? debugLyricFetcher;

  @override
  State<LyricsBatchPage> createState() => _LyricsBatchPageState();
}

class _LyricsBatchPageState extends State<LyricsBatchPage> {
  /// .lrc 在预览里的行键（不是标签字段，单独判断；与事务日志用同一个键）。
  static const String _lrcKey = LrcSidecar.journalKey;

  late List<LyricRow> _rows;
  bool _fetching = false;
  bool _writing = false;
  bool _fetched = false;
  bool _writeLrc = false;
  /// 歌词是否转简体（设置项可记忆，默认开）。
  bool _simplify = true;

  /// 是否合成双语（原文一行 + 译文一行；只有拿到译文的才生效）。
  bool _bilingual = true;

  /// 续跑队列（记住「哪首查到了什么、还没写」）。
  MatchQueue? _queue;

  /// 从上次中断处恢复出来的条数（界面显示「继续上次 N 首」）。
  int _resumed = 0;

  /// 用户点了「重新开始」：清掉续跑进度，这一轮全部重新联网查。
  bool _restarted = false;

  /// 本次会话**真的取过词**（跑完过一轮）。
  ///
  /// 不能拿 `_fetched` 判断：续跑进来时 `_fetched` 也会被置 true（界面要显示
  /// 「找到 N 首」），于是按钮变成「重新获取」，用户一点就把续跑清掉了。
  bool _fetchedThisSession = false;

  Future<void> _restart() async {
    _queue?.clear();
    if (!mounted) return;
    setState(() {
      _restarted = true;
      _resumed = 0;
      _fetched = false;
      _fetchedThisSession = false;
      for (final LyricRow row in _rows) {
        row.forgetResume();
        row.reset();
      }
    });
    await _fetchAll();
  }

  @override
  void initState() {
    super.initState();
    _rows = widget.files.map(LyricRow.new).toList();
    _simplify = Repo.instance.settings.get<bool>('lyrics_simplify', fallback: true) ?? true;
    _bilingual =
        Repo.instance.settings.get<bool>('lyrics_bilingual', fallback: true) ?? true;
    _queue = Repo.instance.lyricsQueue;
    _resume();
  }

  /// 接上上次没写完的那批：指纹（大小 + 修改时间）一致的才认，
  /// 文件被换过就当场作废，不拿旧歌词冒充。
  void _resume() {
    final MatchQueue? q = _queue;
    if (q == null) return;
    int n = 0;
    for (final LyricRow row in _rows) {
      final MatchItem? item = q.take(_keyOf(row.file), row.file.size,
          row.file.lastModified);
      if (item == null) continue;
      final String text = item.field('text', '');
      if (text.isEmpty) continue;
      final LyricHit hit = LyricHit()
        ..title = item.field('title', row.file.stem())
        ..artist = item.field('artist', '')
        ..source = item.field('source', '')
        ..synced = text;
      final double score = double.tryParse(item.field('score', '')) ?? 1.0;
      final LyricChoice c = LyricChoice(hit: hit, score: score)
        ..simplify = _simplify
        ..bilingual = _bilingual;
      row.candidates = <LyricChoice>[c];
      row.choice = c;
      row.selected = !c.low;
      row.status = '上次查到的歌词（未写入）';
      row.resumed = true;
      n++;
    }
    if (n > 0) {
      _resumed = n;
      _fetched = true;
    }
  }

  /// 续跑用的键：有 docId 用它，没有（比如刚扫到还没登记）退回文件名。
  static String _keyOf(VFile f) => f.docId.isNotEmpty ? f.docId : f.name;

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
                if (_resumed > 0 && !_restarted)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: MoButton('重新开始',
                        primary: false,
                        onPressed: _fetching || _writing ? null : _restart),
                  ),
                MoButton(_fetchedThisSession ? '重新获取' : '获取歌词',
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
    // 续跑：上次查到但没来得及写的，进来就摆在列表里，不用再等一轮联网
    if (_resumed > 0 && !_restarted) {
      return '继续上次 $_resumed/${_rows.length} 首（已查到，待确认写入）';
    }
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
      onSwitch: row.canSwitch ? () => _switchCandidate(row) : null,
    );
  }

  /// 换一条候选：选完保留「转简体 / 双语」开关，并自动勾选。
  Future<void> _switchCandidate(LyricRow row) async {
    final LyricChoice? picked =
        await LyricCandidateSheet.show(context, row.candidates);
    if (!mounted || picked == null) return;
    setState(() {
      picked.simplify = _simplify;
      picked.bilingual = _bilingual;
      row.choice = picked;
      row.selected = true;
      row.status = picked.low ? '低置信（手动选的）' : '已选中';
    });
  }

  Widget _bottomBar() {
    // 安卓的系统导航栏盖在应用最底部：不躲开的话「写入 N 首」会被压住
    // （用户 2026-10-31 实测）。桌面端 bottomInset = 0，行为不变。
    final double bottomInset = MediaQuery.of(context).padding.bottom;
    return Container(
      padding: EdgeInsets.fromLTRB(
          MoKit.pagePad, 8, MoKit.pagePad, 10 + bottomInset),
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
    // 「重新获取」要清掉续跑重新联网；首次「获取歌词」保留续跑、跳过已查到的。
    // 判断依据是「本次会话真的取过词」，不是 `_fetched`（续跑也会把它置 true）。
    final bool rerun = _fetchedThisSession;
    setState(() {
      _fetching = true;
      _fetched = false;
      for (final LyricRow row in _rows) {
        if (rerun) {
          // 重新获取：续跑标记与旧候选一起清掉，逐首重查
          row.forgetResume();
          row.reset();
        } else if (!row.resumed) {
          // 首次获取的非续跑行：清掉上一次的残留状态
          row.reset();
        }
        // 续跑行（resumed && !rerun）：**不能 reset**，否则候选被清空，
        // 下面「跳过联网」的条件就命不中，等于白续跑
      }
    });

    final running = TaskCenter.start('取歌词');
    final control = running?.control;
    _control = control;
    final int total = _rows.length;
    int found = 0;
    // 累计各源失败原因（去重），用于「一首都没拿到」时判断是不是联网挂了。
    final Map<String, String> netErrors = <String, String>{};

    try {
      // 文件级并发取词：500 首串行要半小时以上，这里按 Net.fileConcurrency 压到几分钟
      await Net.mapIndexed<LyricRow, void>(
          _rows, Net.fileConcurrency(), control, (int i, LyricRow row) async {
        if (control?.isCancelled() ?? false) return;
        await _waitIfPaused(control);
        control?.report(i, total, row.file.name);
        if (!TagIO.canWriteLyrics(row.file.ext())) {
          row.status = '跳过：${row.file.ext()} 不支持内嵌歌词';
          control?.report(i + 1, total, row.file.name);
          if (mounted) setState(() {});
          return;
        }
        // 上次已经查到过的：直接用，不再联网（省时间也省源的配额）
        if (row.resumed && row.choice != null) {
          found++;
          control?.report(i + 1, total, row.file.name);
          if (mounted) setState(() {});
          return;
        }
        row.status = '搜索歌词…';
        // 页面可能已经被返回键关掉：此时 setState 会因 State 已卸载而崩
        if (mounted) setState(() {});
        try {
          final Tags tags = await Scanner.readTags(store, row.file);
          // 读到的标签写回文件对象：预览要拿它显示「原歌词 → 新歌词」，
          // 否则 cachedTags 一直是 null，旧值永远显示为空
          // cacheMeta 会把封面/歌词标记一起重置，这里显式把原值带上
          row.file.cacheMeta(tags,
              cover: row.file.cachedHasCover,
              lyrics: row.file.cachedHasLyrics ||
                  tags.get(Tags.lyrics).trim().isNotEmpty,
              durationMs: row.file.cachedDurationMs,
              bitrateKbps: row.file.cachedBitrateKbps);
          final Query q = LocalQuery.forFile(row.file, tags);
          final lq = LocalQuery.lyric(q, album: tags.get('album'));
          final LyricAggregateResult agg =
              LyricsBatchPage.debugLyricFetcher != null
                  ? await LyricsBatchPage.debugLyricFetcher!(lq)
              : await Aggregator.lyricCandidates(lq);
          netErrors.addAll(agg.errors);
          // 保留全部候选：机器只按「像不像同一首歌」打分，同名不同版本
          // （现场版 / remix / 翻唱）经常挨在一起，让用户自己挑更靠谱。
          final List<LyricChoice> ranked = LyricPick.rank(q, agg.hits);
          for (final LyricChoice c in ranked) {
            c.simplify = _simplify;
            c.bilingual = _bilingual;
          }
          final LyricChoice? best = ranked.isEmpty ? null : ranked.first;
          row.candidates = ranked;
          row.choice = best;
          row.selected = best != null && !best.low;
          row.status = best == null
              ? '没有合格歌词'
              : (best.low ? '低置信，默认不勾选' : '已选中');
          if (best != null) {
            found++;
            // 记进度：这一首「查到什么、还没写」。下次进来可以直接接着写，
            // 不用再查一遍（进程被杀、用户点停止都靠它续上）。
            _queue?.put(
              _keyOf(row.file),
              row.file.size,
              row.file.lastModified,
              <String, String>{
                'text': best.text,
                'title': best.hit.title,
                'artist': best.hit.artist,
                'source': best.hit.source,
                'score': '${best.score}',
              },
            );
          }
        } catch (e) {
          row.status = '搜索失败：$e';
        }
        control?.report(i + 1, total, row.file.name);
        if (mounted) setState(() {});
      });
    } finally {
      TaskCenter.finish();
    }
    if (!mounted) return;
    setState(() {
      _fetching = false;
      _fetched = true;
      _fetchedThisSession = true;
    });
    final int enabled = SourceRegistry.lyrics().length;
    final bool allDown = enabled > 0 && netErrors.length >= enabled;
    if (found == 0 && allDown) {
      // 所有启用的源都报错，才能说是网络问题；只有一家挂了别让用户去改代理
      final String why = netErrors.values.first;
      moSnack(context,
          '联网取词失败：$why。请检查网络连接或代理设置（设置 → 网络与并发）');
    } else if (found == 0 && netErrors.isNotEmpty) {
      moSnack(context,
          '没有找到合格歌词（${netErrors.length}/$enabled 个源不可用，其余源没返回结果）');
    } else {
      moSnack(context, '找到 $found 首歌词，确认后再写入');
    }
  }

  /// 歌词预览只显示头一行 + 行数，避免把整篇歌词铺进确认面板。
  static String _brief(String text) => LyricPick.brief(text, maxLines: 1);

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
    // 低置信是「机器觉得可能不是同一首歌」：默认不勾选已经挡掉一大半，
    // 但用户主动勾上时仍要再问一次——写进文件的歌词覆盖掉原来的，退回来很麻烦
    final int low = picked
        .where((WriteTarget t) => t.lowConfidence)
        .length;
    if (low > 0) {
      final bool? go = await showDialog<bool>(
        context: context,
        builder: (BuildContext ctx) => AlertDialog(
          title: Text('有 $low 首是低置信歌词'),
          content: const Text(
              '这些歌词与曲目的匹配度偏低（多半是同名不同版本：现场版 / remix / 翻唱）。\n\n'
              '写入会覆盖文件里原有的歌词，确定要写吗？'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('先不写'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('照写'),
            ),
          ],
        ),
      );
      if (go != true) return;
    }
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

    try {
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
          // .lrc 一起进事务：写失败会连音频一起还原，撤销也一起退
          lrcText: wantLrc ? text : null,
        );
        if (err.isEmpty) {
          inlineOk++;
          repo.invalidate(plan.file);
          if (wantLrc) lrcOk++;
          // 这首已经落地：从续跑队列里收尾，下次进来不再当成「没写完」
          _queue?.mark(_keyOf(plan.file), MatchQueue.written);
          _setStatus(
              plan.file, wantLrc ? '已写入内嵌歌词与 .lrc' : '已写入内嵌歌词');
        } else {
          failed++;
          // 失败的不丢：留着下次重试（指纹变了会自动作废）
          _queue?.mark(_keyOf(plan.file), MatchQueue.failed);
          _setStatus(plan.file, '写入失败：$err');
        }
        done++;
        control?.report(done, picked.length, plan.file.name);
        if (mounted) setState(() {});
      }
    } finally {
      TaskCenter.finish();
    }
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
