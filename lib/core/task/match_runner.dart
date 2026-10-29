/// 批量匹配链路 —— 移植自旧 ui/BatchActions + core/TagBatch 的编排部分。
///
/// 两段式，**中间一定隔一次用户确认**：
/// 1. [match]：并发读标签 → 聚合候选 → 打分 → 生成「旧值 → 新值」计划（不写盘）；
/// 2. [write]：把用户勾选后的计划串行写盘（每首走 [TagTransaction] 七步事务）。
///
/// 续跑两层：`MatchQueue` 记住「这首已经匹配出什么」，`BatchMemory` 记住「这首上次没命中」。
/// 两者的指纹都是 `docId + size + lastModified`，文件一变就自动作废。
library;

import 'dart:async';

import '../fs/file_store.dart';
import '../match/batch_memory.dart';
import '../match/match_queue.dart';
import '../match/name_parser.dart';
import '../match/tag_plan.dart';
import '../model/candidate.dart';
import '../model/query.dart';
import '../model/task_control.dart';
import '../model/tags.dart';
import '../model/vfile.dart';
import '../net/net.dart';
import '../scan/scanner.dart';
import '../source/aggregator.dart';
import '../source/tag_source.dart';
import '../tx/tag_transaction.dart';

/// 一次写盘的结果。
class WriteReport {
  WriteReport(this.written, this.failed, this.errors,
      {this.files = const <VFile>[]});

  final int written;
  final int failed;

  /// 写成功的文件：调用方拿它补读一次标签。
  ///
  /// 写盘后这些文件的缓存已被清空，但列表里的条目还是旧值——不重读的话，
  /// 刚补好标签的歌在列表里仍显示「无标签」，得手动重扫才更新。
  final List<VFile> files;

  /// 「文件名：原因」列表（最多留 50 条，避免几千首全失败时内存爆掉）。
  final List<String> errors;

  bool get ok => failed == 0;

  String summary() =>
      failed == 0 ? '已写入 $written 首' : '已写入 $written 首，失败 $failed 首';
}

/// 批量匹配 + 写盘编排。
class MatchRunner {
  MatchRunner({
    required this.store,
    required this.tx,
    this.queue,
    this.memory,
    this.chinese,
  });

  final FileStore store;
  final TagTransaction tx;

  /// 续跑队列（可空：不做续跑）。
  final MatchQueue? queue;

  /// 增量记忆（可空）。
  final BatchMemory? memory;

  /// 语种覆盖；null = 按标题/艺人自动判断。
  final bool? chinese;

  /// 本次匹配各源失败原因（源 key → 原因）；用于「一首都没命中」时判断是不是联网挂了。
  final Map<String, String> errors = <String, String>{};

  /// 一个批次共用一个 id，撤销时按整批回滚。
  String newBatchId() => 'match-${DateTime.now().millisecondsSinceEpoch}';

  /// 只做匹配、不写盘；返回逐文件计划（供预览界面展示与勾选）。
  ///
  /// [onPlan] 每算完一首就回调一次（界面可以边跑边显示），[control] 用于暂停/取消。
  Future<List<FilePlan>> match(
    List<VFile> files, {
    TaskControl? control,
    Map<String, int>? modes,
    bool overwrite = false,
    bool ignoreMemory = false,
    JsonFetcher? fetch,
    void Function(int done, int total, FilePlan plan)? onPlan,
  }) async {
    final int total = files.length;
    if (total == 0) return <FilePlan>[];

    int done = 0;
    final List<FilePlan?> slots = await Net.map<VFile, FilePlan>(
      files,
      Net.fileConcurrency(),
      control,
      (VFile f) async {
        // 暂停：在这里等，直到继续或取消（每首一个检查点）
        await _waitIfPaused(control);
        final FilePlan plan = await _matchOne(f, modes, overwrite, ignoreMemory, fetch);
        done++;
        control?.report(done, total, plan.file.name);
        onPlan?.call(done, total, plan);
        return plan;
      },
    );
    return slots.whereType<FilePlan>().toList();
  }

  Future<FilePlan> _matchOne(
    VFile f,
    Map<String, int>? modes,
    bool overwrite,
    bool ignoreMemory,
    JsonFetcher? fetch,
  ) async {
    final Tags before = await Scanner.readTags(store, f);

    // ① 记忆里写着「上次没命中」且文件没变 → 直接跳过，别浪费一次联网
    if (!ignoreMemory &&
        memory != null &&
        memory!.statusOf(f.docId, f.size, f.lastModified) == BatchMemory.noHit) {
      return TagPlan.buildFor(file: f, before: before, modes: modes, overwrite: overwrite)
        ..note = '上次无命中（已记忆，跳过联网）';
    }

    // ② 队列里有这一首的中间结果且文件没变 → 续跑，不再问网络
    if (queue != null) {
      final MatchItem? cached = queue!.take(f.docId, f.size, f.lastModified);
      if (cached != null) {
        final Candidate c = Candidate()
          ..title = cached.field('title', '')
          ..artist = cached.field('artist', '')
          ..album = cached.field('album', '')
          ..year = cached.field('year', '')
          ..track = cached.field('track', '')
          ..genre = cached.field('genre', '')
          ..source = cached.field('source', '')
          ..confidence = double.tryParse(cached.field('confidence', '0')) ?? 0;
        final FilePlan plan =
            TagPlan.buildFor(file: f, before: before, candidate: c, modes: modes, overwrite: overwrite);
        plan.note = '续跑：${plan.note}';
        return plan;
      }
    }

    final Query q = Query()
      ..filenameCandidates = NameParser.candidatePairs(f.stem())
      ..embeddedTags = before.toMap()
      ..localDuration = f.cachedDurationMs > 0 ? f.cachedDurationMs / 1000.0 : null;

    final AggregateResult agg =
        await Aggregator.tagCandidates(q, chinese: chinese, fetch: fetch);
    if (agg.errors.isNotEmpty) errors.addAll(agg.errors);

    Candidate? best = agg.candidates.isEmpty ? null : agg.candidates.first;
    String looseNote = '';
    bool loose = false;
    if (best == null) {
      // 严格匹配一首都没有时，再放宽一次：允许「同一首歌的另一个录音版本」
      // （现场 / 合辑剪辑 / 转码被截断，时长能差几十秒）。这类结果不当自动命中，
      // 标成低置信 + 说明，交给预览页的人确认。不这么做的话，4:17 的《一无所有》
      // 永远匹配不到 5:43 的专辑版（差 86 秒），批量里只能一直显示「没有命中」。
      final AggregateResult alt =
          await Aggregator.tagCandidates(q, chinese: chinese, fetch: fetch, verify: false);
      if (alt.errors.isNotEmpty) errors.addAll(alt.errors);
      best = _looseBest(alt.candidates);
      if (best != null) {
        loose = true;
        looseNote = _looseNote(q.localDuration, best);
      }
    }

    if (best == null) {
      if (memory != null) {
        memory!.record(f.docId, f.size, f.lastModified, BatchMemory.noHit);
      }
      return TagPlan.buildFor(file: f, before: before, modes: modes, overwrite: overwrite)
        ..note = '没有命中';
    }

    if (queue != null) {
      queue!.put(f.docId, f.size, f.lastModified, <String, String>{
        'title': best.title,
        'artist': best.artist,
        'album': best.album,
        'year': best.year,
        'track': best.track,
        'genre': best.genre,
        'source': best.source,
        'confidence': '${best.confidence}',
      });
      if (memory != null) {
        // 这里只是「查到了候选」，用户可能取消写入：
        // 记 done 会让这首歌在下次被 shouldSkip 永久跳过
        memory!.record(f.docId, f.size, f.lastModified, BatchMemory.matched);
      }
    }
    final FilePlan plan = TagPlan.buildFor(
      file: f,
      before: before,
      candidate: best,
      modes: modes,
      overwrite: overwrite,
      note: loose ? looseNote : null,
      lowConfidence: loose ? true : null,
    );
    // 兜底命中的「另一个录音版本」不默认勾选：让人看一眼「时长差多少秒」
    // 再决定写不写，避免批量一路回车把不同版本的专辑信息盖到正确标签上。
    if (loose) plan.selected = false;
    return plan;
  }

  /// 宽松候选里挑一个「够像」的：标题 / 艺人已由 [scoreDetail] 验证过，
  /// 这里只挡住分数接近淘汰线的噪声，避免把不相干的歌塞进预览。
  static Candidate? _looseBest(List<Candidate> candidates) {
    for (final Candidate c in candidates) {
      if (c.matchScore >= looseMinScore) return c;
    }
    return null;
  }

  /// 兜底候选的最低分。标题完全一致 + 艺人完全一致、只丢时长分时约 0.71，
  /// 取 0.55 能容下「缺艺人」这类信息不全的情况，又挡住靠时长凑分的噪声。
  static const double looseMinScore = 0.55;

  /// 兜底命中时写在预览行上的说明。
  static String _looseNote(double? local, Candidate c) {
    final double? d = c.duration;
    if (local != null && local > 0 && d != null && d > 0) {
      final int diff = (local - d).abs().round();
      return '时长差 $diff 秒（可能是现场 / 剪辑 / 转码版本），建议确认';
    }
    return '时长对不上（可能是另一个录音版本），建议确认';
  }

  /// 串行写盘（写盘一律不许并发：同一批里两首可能落在同一目录，并发写会把事务的备份搅乱）。
  Future<WriteReport> write(
    List<FilePlan> plans, {
    TaskControl? control,
    String? batchId,
  }) async {
    final List<FilePlan> todo = TagPlan.onlySelected(plans);
    final String bid = batchId ?? newBatchId();
    int written = 0;
    int failed = 0;
    final List<String> errors = <String>[];
    final List<VFile> okFiles = <VFile>[];
    int done = 0;

    for (final FilePlan p in todo) {
      if (control?.isCancelled() ?? false) break;
      await _waitIfPaused(control);
      final Map<String, String> updates = p.toUpdates();
      if (updates.isEmpty) continue;
      final String err =
          await tx.apply(p.file, updates, record: true, batchId: bid);
      if (err.isEmpty) {
        written++;
        Scanner.invalidate(p.file);
        okFiles.add(p.file);
        queue?.mark(p.file.docId, MatchQueue.written);
      } else {
        failed++;
        if (errors.length < 50) errors.add('${p.file.name}：$err');
        queue?.mark(p.file.docId, MatchQueue.failed);
      }
      done++;
      control?.report(done, todo.length, p.file.name);
    }
    queue?.clearFinished();
    return WriteReport(written, failed, errors, files: okFiles);
  }

  /// 暂停时等在这里（每 120ms 看一次），取消则立刻返回。
  static Future<void> _waitIfPaused(TaskControl? control) async {
    if (control == null) return;
    while (control.isPaused() && !control.isCancelled()) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
  }
}
