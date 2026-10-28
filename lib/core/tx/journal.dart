/// 标签事务日志（tag_journal.jsonl，2000 条上限）。
///
/// 简化：不做轮转，append 全量重写；保留近 2000 条。
library;

import 'dart:io';

import '../model/journal_entry.dart';
import 'journal_history.dart';

/// 当前时间串（yyyy-MM-dd HH:mm:ss），journal 记录与回滚共用。
String journalTimestamp() {
  final DateTime n = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${n.year}-${two(n.month)}-${two(n.day)} '
      '${two(n.hour)}:${two(n.minute)}:${two(n.second)}';
}

/// 标签事务日志（jsonl 存储）。
class Journal {
  Journal(this.file);

  /// jsonl 文件（appSupportDir/tag_journal.jsonl，由 Repo 注入）。
  final File file;

  /// 单文件 2000 条上限。
  static const int maxEntries = 2000;

  /// 内存缓存：启动后读一次磁盘，之后 append 走追加写，不再每次全量读写。
  List<JournalEntry>? _cache;
  bool _loaded = false;

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _cache = <JournalEntry>[];
    if (await file.exists()) {
      final List<String> lines = await file.readAsLines();
      for (final String line in lines) {
        final String t = line.trim();
        if (t.isEmpty) continue;
        try {
          _cache!.add(JournalEntry.fromJsonLine(t));
        } catch (_) {}
      }
    }
    _loaded = true;
  }

  /// 追加一条记录。常态下只追加一行 jsonl；只有超过 [maxEntries] 才整体重写修剪。
  Future<bool> append(JournalEntry entry) async {
    try {
      await _ensureLoaded();
      _cache!.add(entry);
      if (_cache!.length > maxEntries) {
        _cache!.removeRange(0, _cache!.length - maxEntries);
        await _rewriteAll();
      } else {
        // jsonl 天然追加友好：只写新这一行，避免批量写 500 首时 O(n²) 重写
        await file.writeAsString('${entry.toJsonLine()}\n',
            mode: FileMode.append, flush: true);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 全量重写（只在修剪或回滚时用）。
  Future<void> _rewriteAll() async {
    final StringBuffer sb = StringBuffer();
    for (final JournalEntry e in _cache!) {
      sb.writeln(e.toJsonLine());
    }
    await file.writeAsString(sb.toString(), flush: true);
  }

  /// 读出全部记录（坏行跳过）。
  Future<List<JournalEntry>> readAll() async {
    await _ensureLoaded();
    return <JournalEntry>[..._cache!];
  }

  /// 最近一个可撤销的 applied 记录。
  ///
  /// `targetId` 有两种语义，别混用：
  /// - **applied** 记录：写的是目标文件的 docId（与 `uri` 同值，取谁都行）；
  /// - **reverted** 记录：写的是**被撤销那条记录的 id**（不是文件 id）。
  /// 所以这里判断「是否已撤销」要用 `reverted.contains(e.id)`（拿 reverted 的
  /// targetId 去比对 applied 的 id），而不是拿 e.targetId 去比对。
  Future<JournalEntry?> findLastApplied() async {
    final List<JournalEntry> all = await readAll();
    final Set<String> reverted = <String>{};
    for (final JournalEntry e in all) {
      if (e.status == 'reverted' && e.targetId.isNotEmpty) reverted.add(e.targetId);
    }
    for (int i = all.length - 1; i >= 0; i--) {
      final JournalEntry e = all[i];
      if (e.status == 'applied' && !reverted.contains(e.id)) return e;
    }
    return null;
  }

  /// 某批次里还能撤销的记录（保持写入顺序）。
  Future<List<JournalEntry>> targets(String key) async {
    final List<JournalEntry> all = await readAll();
    return JournalHistory.targetsOf(all, key);
  }

  /// 可撤销的批次（按时间倒序，最多 [limit] 个）。
  Future<List<JournalBatch>> batches(int limit) async {
    return JournalHistory.build(await readAll(), limit);
  }

  /// 逆序回滚一个批次：对每条 target 调用 [revertOne]，成功则追加 reverted 记录。
  ///
  /// 返回 {成功数, 失败数, 总数}。
  Future<List<int>> revertBatch(String batchId,
      {required Future<bool> Function(JournalEntry) revertOne,
      bool Function(JournalEntry)? skip}) async {
    final List<JournalEntry> targets = await this.targets(batchId);
    int ok = 0;
    int failed = 0;
    int total = 0;
    for (int i = targets.length - 1; i >= 0; i--) {
      final JournalEntry e = targets[i];
      // 用户在预览里取消勾选的：既不回滚，也不计进成功 / 失败。
      if (skip != null && skip(e)) continue;
      total++;
      if (await revertOne(e)) {
        ok++;
        final JournalEntry rev = JournalEntry()
          ..id = '${DateTime.now().millisecondsSinceEpoch}-revert-${e.id}'
          ..timestamp = journalTimestamp()
          ..uri = e.uri
          ..name = e.name
          ..batchId = e.batchId
          ..status = 'reverted'
          ..targetId = e.id;
        await append(rev);
      } else {
        failed++;
      }
    }
    return <int>[ok, failed, total];
  }
}
