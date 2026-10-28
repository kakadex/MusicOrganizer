/// 搜索输入解析。
///
/// 把一行文本变成「词 + 字段条件 + 大小条件」；未知前缀按普通词处理。
library;

import '../match/text_util.dart';

/// 搜索查询（纯 Dart）。
class SearchQuery {
  SearchQuery._(this.source);

  /// 支持的字段名。
  static const List<String> knownFields = <String>[
    'title', 'artist', 'albumArtist', 'album', 'genre', 'comment', 'lyrics',
    'path', 'ext', 'year',
  ];

  /// 别名（中文 / 英文）→ 规范字段名。
  static const Map<String, String> aliases = <String, String>{
    'title': 'title', '标题': 'title', '歌名': 'title', '曲名': 'title', 'name': 'title',
    'artist': 'artist', '艺术家': 'artist', '歌手': 'artist', '艺人': 'artist', 'singer': 'artist',
    'album': 'album', '专辑': 'album', '唱片': 'album',
    'albumartist': 'albumArtist', '专辑艺术家': 'albumArtist', '专辑艺人': 'albumArtist',
    'genre': 'genre', '流派': 'genre', '风格': 'genre', '类型': 'genre',
    'comment': 'comment', '注释': 'comment', '备注': 'comment',
    'lyrics': 'lyrics', '歌词': 'lyrics', 'lrc': 'lyrics',
    'path': 'path', '路径': 'path', '目录': 'path', 'dir': 'path', 'folder': 'path',
    'ext': 'ext', '后缀': 'ext', '格式': 'ext', '扩展名': 'ext', 'type': 'ext',
    'year': 'year', '年份': 'year', '年代': 'year', 'date': 'year',
    'size': 'size', '大小': 'size', '体积': 'size',
  };

  /// 归一后的检索词（用于匹配）。
  final List<String> terms = <String>[];

  /// 原始检索词（界面高亮用）。
  final List<String> raw = <String>[];

  /// 字段条件：字段名 → 归一后的值。
  final Map<String, String> fields = <String, String>{};

  /// 大小下限 / 上限，-1 表示不限。
  int minSize = -1;
  int maxSize = -1;

  /// 原始输入。
  final String source;

  bool get isEmpty => terms.isEmpty && fields.isEmpty && minSize < 0 && maxSize < 0;

  bool get hasFieldFilter => fields.isNotEmpty;

  static SearchQuery parse(String? rawText) {
    final SearchQuery q = SearchQuery._(rawText ?? '');
    if (rawText == null) return q;
    for (final String token in tokenize(rawText)) {
      final String t = token.trim();
      if (t.isEmpty) continue;
      final int colon = t.indexOf(':');
      if (colon > 0 && colon < t.length - 1) {
        final String prefix = t.substring(0, colon).toLowerCase();
        final String? field = aliases[prefix];
        final String value = t.substring(colon + 1).trim();
        if (field != null && value.isNotEmpty) {
          if (field == 'size') {
            q._applySize(value);
          } else {
            q.fields[field] = norm(value);
          }
          continue;
        }
      }
      q.terms.add(norm(t));
      q.raw.add(t);
    }
    return q;
  }

  void _applySize(String value) {
    String v = value.trim().toLowerCase();
    String op = '';
    if (v.startsWith('>=') ||
        v.startsWith('<=') ||
        v.startsWith('>') ||
        v.startsWith('<') ||
        v.startsWith('=')) {
      int i = 0;
      while (i < v.length &&
          (v[i] == '>' || v[i] == '<' || v[i] == '=')) {
        i++;
      }
      op = v.substring(0, i);
      v = v.substring(i).trim();
    }
    final int bytes = parseBytes(v);
    if (bytes < 0) return;
    if (op == '>') {
      minSize = bytes + 1;
    } else if (op == '>=') {
      minSize = bytes;
    } else if (op == '<') {
      maxSize = bytes - 1;
    } else if (op == '<=') {
      maxSize = bytes;
    } else {
      minSize = (bytes * 0.9).floor();
      maxSize = (bytes * 1.1).floor();
    }
  }

  /// "10m" / "1.5g" / "800k" / "4096" → 字节；解析失败返回 -1。
  static int parseBytes(String v) {
    if (v.isEmpty) return -1;
    final String last = v[v.length - 1].toLowerCase();
    int unit = 1;
    String num = v;
    if (last == 'k' || last == 'm' || last == 'g' || last == 'b') {
      num = v.substring(0, v.length - 1);
      if (last == 'k') {
        unit = 1024;
      } else if (last == 'm') {
        unit = 1024 * 1024;
      } else if (last == 'g') {
        unit = 1024 * 1024 * 1024;
      }
    }
    final double? d = double.tryParse(num);
    if (d == null || d < 0) return -1;
    return (d * unit).floor();
  }

  /// 按空白切词，支持双引号（含中文引号）把带空格的内容并成一个词。
  static List<String> tokenize(String text) {
    final List<String> out = <String>[];
    final StringBuffer cur = StringBuffer();
    bool quoted = false;
    for (final int c in text.codeUnits) {
      if (c == 0x22 || c == 0x201C || c == 0x201D) {
        quoted = !quoted;
        continue;
      }
      if (!quoted && (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D)) {
        if (cur.isNotEmpty) {
          out.add(cur.toString());
          cur.clear();
        }
        continue;
      }
      cur.writeCharCode(c);
    }
    if (cur.isNotEmpty) out.add(cur.toString());
    return out;
  }

  /// 归一：繁转简 + 只保留字母数字（去空格/标点/括号）+ 小写。
  static String norm(String? s) {
    if (s == null) return '';
    final String simplified = TextUtil.toSimplified(s).toLowerCase();
    final StringBuffer sb = StringBuffer();
    for (final int c in simplified.codeUnits) {
      if (_isLetterOrDigit(c)) sb.writeCharCode(c);
    }
    return sb.toString();
  }

  /// 描述当前查询。
  String describe() {
    final StringBuffer sb = StringBuffer();
    for (final String t in raw) {
      if (sb.isNotEmpty) sb.write(' ');
      sb.write(t);
    }
    for (final MapEntry<String, String> e in fields.entries) {
      if (sb.isNotEmpty) sb.write(' ');
      sb.write('${e.key}:${e.value}');
    }
    if (minSize >= 0) sb.write(' size>=$minSize');
    if (maxSize >= 0) sb.write(' size<=$maxSize');
    return sb.toString().trim();
  }

  static bool _isLetterOrDigit(int c) =>
      (c >= 0x30 && c <= 0x39) ||
      (c >= 0x41 && c <= 0x5A) ||
      (c >= 0x61 && c <= 0x7A) ||
      (c >= 0x4E00 && c <= 0x9FFF) ||
      (c >= 0x3040 && c <= 0x30FF) ||
      (c >= 0xAC00 && c <= 0xD7AF);
}
