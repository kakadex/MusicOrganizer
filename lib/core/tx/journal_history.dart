/// 写入历史的「批次视图」—— 移植自旧 core/JournalHistory.java（纯计算）。
///
/// Journal 是逐条流水，用户想撤销的单位是「一批」（批量打标签共用一个 batchId）。
/// 这里把扁平记录折叠成批次，并算出每批还能撤销的条目。
library;

import '../model/journal_entry.dart';

/// 一批可撤销的写入。
class JournalBatch {
  /// 批次键：有 batchId 用它，单条写入用 "one:" + id。
  String key = '';

  /// 该批最后一次写入时间（列表按它倒序）。
  String time = '';

  /// 还能撤销的条数。
  int count = 0;

  /// 该批总条数（含已撤销的）。
  int total = 0;

  /// 文件名样例，最多 3 个。
  final List<String> samples = <String>[];

  /// 是否为「非批量」的单条写入。
  bool single = false;

  String title() {
    String t = time;
    if (t.length >= 16) t = t.substring(5, 16);
    return '$t · $count${single ? ' 条' : ' 首'}';
  }

  String summary() {
    final StringBuffer sb = StringBuffer();
    for (int i = 0; i < samples.length; i++) {
      if (i > 0) sb.write('、');
      sb.write(samples[i]);
    }
    if (count > samples.length) sb.write(' 等 $count 个文件');
    if (total > count) sb.write(' · 其中 ${total - count} 已撤销');
    return sb.toString();
  }
}

/// 批次视图（纯 Dart）。
abstract final class JournalHistory {
  /// 批次键（单条写入自成一批）。
  static String keyOf(JournalEntry r) =>
      r.batchId.isNotEmpty ? r.batchId : 'one:${r.id}';

  /// 已被撤销的记录 id 集合（reverted 记录的 targetId 指向原记录）。
  static Set<String> revertedIds(List<JournalEntry> rows) {
    final Set<String> out = <String>{};
    for (final JournalEntry r in rows) {
      if (r.status == 'reverted' && r.targetId.isNotEmpty) out.add(r.targetId);
    }
    return out;
  }

  /// 折叠成批次列表，按最后写入时间倒序，最多 [limit] 个（只返回仍有可撤销条目的）。
  static List<JournalBatch> build(List<JournalEntry> rows, int limit) {
    final List<JournalBatch> out = <JournalBatch>[];
    if (rows.isEmpty) return out;
    final Set<String> reverted = revertedIds(rows);
    final Map<String, JournalBatch> map = <String, JournalBatch>{};
    final Map<String, Set<String>> seenPerBatch = <String, Set<String>>{};
    for (final JournalEntry r in rows) {
      if (r.status != 'applied') continue;
      final String key = keyOf(r);
      JournalBatch b = map.putIfAbsent(key, () {
        final JournalBatch nb = JournalBatch()
          ..key = key
          ..single = r.batchId.isEmpty
          ..time = r.timestamp;
        seenPerBatch[key] = <String>{};
        return nb;
      });
      b.total++;
      if (r.timestamp.compareTo(b.time) > 0) b.time = r.timestamp;
      if (reverted.contains(r.id)) continue;
      b.count++;
      String name = r.name;
      if (name.isEmpty) name = nameFromUri(r.uri);
      final Set<String> seen = seenPerBatch[key]!;
      if (name.isNotEmpty && seen.add(name) && b.samples.length < 3) {
        b.samples.add(name);
      }
    }
    for (final JournalBatch b in map.values) {
      if (b.count > 0) out.add(b);
    }
    out.sort((JournalBatch a, JournalBatch b) => b.time.compareTo(a.time));
    if (limit > 0 && out.length > limit) return out.sublist(0, limit);
    return out;
  }

  /// 某批次里还能撤销的记录（保持写入顺序，撤销时由调用方逆序处理）。
  static List<JournalEntry> targetsOf(List<JournalEntry> rows, String key) {
    final List<JournalEntry> out = <JournalEntry>[];
    if (key.isEmpty) return out;
    final Set<String> reverted = revertedIds(rows);
    for (final JournalEntry r in rows) {
      if (r.status != 'applied') continue;
      if (key != keyOf(r)) continue;
      if (reverted.contains(r.id)) continue;
      out.add(r);
    }
    return out;
  }

  /// 从 uri 里取文件名（解码 %xx，去掉 query）。
  static String nameFromUri(String uri) {
    String s = uri;
    final int q = s.indexOf('?');
    if (q >= 0) s = s.substring(0, q);
    final int slash = s.lastIndexOf('/');
    if (slash >= 0 && slash < s.length - 1) s = s.substring(slash + 1);
    try {
      s = Uri.decodeComponent(s);
    } catch (_) {}
    return s;
  }
}
