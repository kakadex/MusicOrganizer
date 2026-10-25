/// 标签事务日志条目 —— 移植自旧 core/Journal.java 的 Entry（jsonl 序列化）。
///
/// 完整 Journal（文件读写 / 批次视图）在 T07 落位；这里先给出条目模型与
/// 单行 jsonl 的序列化 / 反序列化（复用 lib/core/json/json.dart）。
library;

import '../json/json.dart';

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

  /// 文件名（仅用于撤销历史列表展示；旧记录为空时由 T07 从 uri 推导）。
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
