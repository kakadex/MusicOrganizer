/// 标签事务日志条目 的 Entry（jsonl 序列化）。
///
/// 完整 Journal（文件读写 / 批次视图）在 ；这里先给出条目模型与
/// 单行 jsonl 的序列化 / 反序列化（复用 lib/core/json/json.dart）。
library;

import '../json/json.dart';

/// 写盘操作类型（记进 [JournalEntry.op]，撤销历史按它区分来源）。
abstract final class JournalOp {
  /// 改标签（用户手动 / 批量匹配的常规写入）。
  static const String tags = 'tags';

  /// 修乱码：编码是**猜**出来的，可能误判，撤销时要能单独挑出来。
  static const String encoding = 'encoding';

  /// 写内嵌歌词。
  static const String lyrics = 'lyrics';

  /// 写 / 删同名 `.lrc`。
  static const String lrc = 'lrc';

  /// 写封面。
  static const String cover = 'cover';

  /// 清空标签（批量删除）。
  static const String clear = 'clear';

  /// 展示名。
  static String label(String op) => switch (op) {
        encoding => '修乱码',
        lyrics => '写歌词',
        lrc => '歌词文件',
        cover => '写封面',
        clear => '清空标签',
        _ => '改标签',
      };
}

/// 一条标签写盘事务记录。
class JournalEntry {
  String id = '';
  String timestamp = '';
  String uri = '';
  String batchId = '';
  Map<String, String> before = <String, String>{};
  Map<String, String> after = <String, String>{};
  String status = 'applied';
  String targetId = '';

  /// 这次写盘是**干什么**（[JournalOp] 之一）。
  ///
  /// 没有它，撤销历史里「改标签」和「修乱码」长得一模一样；而后者是**猜测**
  /// ——修错了要能一眼挑出来单独回退，不能和用户自己改的混在一起。
  /// 旧记录没有这个字段，读出为空时按 [JournalOp.tags] 处理。
  String op = JournalOp.tags;

  /// 文件名（仅用于撤销历史列表展示；旧记录为空时从 uri 推导）。
  String name = '';

  /// 序列化为单行 jsonl。
  String toJsonLine() {
    return '{"id":${Json.quote(id)},'
        '"timestamp":${Json.quote(timestamp)},'
        '"uri":${Json.quote(uri)},'
        '"batchId":${Json.quote(batchId)},'
        '"before":${_mapJson(before)},'
        '"after":${_mapJson(after)},'
        '"status":${Json.quote(status)},'
        '"targetId":${Json.quote(targetId)},'
        '"op":${Json.quote(op)},'
        '"name":${Json.quote(name)}}';
  }

  /// 从单行 jsonl 解析；坏行返回字段全空的条目。
  static JournalEntry fromJsonLine(String line) {
    final JournalEntry e = JournalEntry();
    final Object? o = Json.parseOrNull(line);
    if (o is Map) {
      final Map<String, Object?> m = o.cast<String, Object?>();
      e.id = _str(m['id']);
      e.timestamp = _str(m['timestamp']);
      e.uri = _str(m['uri']);
      e.batchId = _str(m['batchId']);
      e.status = _str(m['status']).isEmpty ? 'applied' : _str(m['status']);
      e.targetId = _str(m['targetId']);
      final String op = _str(m['op']);
      e.op = op.isEmpty ? JournalOp.tags : op;
      e.name = _str(m['name']);
      e.before = _mapOf(m['before']);
      e.after = _mapOf(m['after']);
    }
    return e;
  }

  static String _mapJson(Map<String, String> m) {
    final Iterable<String> parts = m.entries
        .map((MapEntry<String, String> e) => '${Json.quote(e.key)}:${Json.quote(e.value)}');
    return '{${parts.join(',')}}';
  }

  static String _str(Object? v) => v == null ? '' : '$v';

  static Map<String, String> _mapOf(Object? v) {
    final Map<String, String> out = <String, String>{};
    if (v is Map) {
      for (final MapEntry<dynamic, dynamic> e in v.entries) {
        out['${e.key}'] = e.value == null ? '' : '${e.value}';
      }
    }
    return out;
  }
}
