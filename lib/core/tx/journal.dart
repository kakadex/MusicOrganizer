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

  /// 追加一条记录（全量重写）。
  Future<bool> append(JournalEntry entry) async {
    try {
      final List<JournalEntry> all = await readAll();
      all.add(entry);
      while (all.length > maxEntries) {
        all.removeAt(0);
      }
      final StringBuffer sb = StringBuffer();
      for (final JournalEntry e in all) {
        sb.writeln(e.toJsonLine());
      }
      await file.writeAsString(sb.toString(), flush: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 读出全部记录（坏行跳过）。
  Future<List<JournalEntry>> readAll() async {
    final List<JournalEntry> out = <JournalEntry>[];
    if (!await file.exists()) return out;
    final List<String> lines = await file.readAsLines();
    for (final String line in lines) {
      final String t = line.trim();
      if (t.isEmpty) continue;
      try {
        out.add(JournalEntry.fromJsonLine(t));
      } catch (_) {}
    }
    return out;
  }

  /// 最近一个可撤销的 applied 记录。
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
      {required Future<bool> Function(JournalEntry) revertOne}) async {
    final List<JournalEntry> targets = await this.targets(batchId);
    int ok = 0;
    int failed = 0;
    for (int i = targets.length - 1; i >= 0; i--) {
      final JournalEntry e = targets[i];
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
    return <int>[ok, failed, targets.length];
  }
}
