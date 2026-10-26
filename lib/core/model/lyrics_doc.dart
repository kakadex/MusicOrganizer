/// 歌词文档模型。
///
/// 定义「行 = 时间戳 + 文本」的最小模型，并提供解析、清洗、合并翻译三件事。
/// 输出仍是标准 LRC（双语就是同一时间点两行）。
library;

/// 逐字音节（增强型 LRC 的 `<mm:ss.xx>字`，或 TTML 的 `<span>`）。
class LyricWord {
  LyricWord([this.timeMs = 0, String? text]) : text = text ?? '';

  int timeMs;
  String text;
}

/// 一行歌词。
class LyricLine {
  LyricLine([this.timeMs = 0, String? text]) : text = text ?? '';

  /// 毫秒。
  int timeMs;
  String text;

  /// 解析顺序（同一时间点多行时保持稳定）。
  int order = 0;

  /// 逐字时间；普通 LRC 为空表。
  final List<LyricWord> words = <LyricWord>[];
}

/// 歌词文档模型（纯 Dart）。
abstract final class LyricsDoc {
  /// 译文与原文时间点的最大容差（毫秒）。
  static const int translationToleranceMs = 150;

  /// `[mm:ss]` / `[mm:ss.xx]` / `[mm:ss.xxx]`，允许一行多个时间戳。
  static final RegExp _tsRe =
      RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');

  /// 增强型 LRC 的逐字时间戳：`<00:12.34>`。
  static final RegExp _wordRe =
      RegExp(r'<(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?>');

  /// 元信息行关键词：这些行如果没有时间戳，就不是歌词而是制作信息。
  static const List<String> _metaWords = <String>[
    '作词', '作曲', '编曲', '制作人', '监制', '出品', '发行', '混音', '母带', '录音',
    '和声', '吉他', '贝斯', '鼓', '键盘', '弦乐', '和声编写', '配唱', '词', '曲',
    '演唱', '原唱', '翻唱', '版权', '企划', '统筹', '录音室', '混音室', '母带室',
    '出品人', '音乐总监', '制作', '策划', '宣传', 'op', 'sp', 'lyricist', 'composer',
    'arranger', 'producer', 'mixed', 'mastered', 'recorded',
  ];

  /// 是不是「制作信息行」（调用方保证已去掉时间戳）。
  static bool isMetadataLine(String? raw) {
    if (raw == null) return false;
    final String s = raw.trim();
    if (s.isEmpty) return false;
    final String lower = s.toLowerCase();
    for (final String w in _metaWords) {
      if (!lower.startsWith(w)) continue;
      // 「作词：xxx」「作词 : xxx」「作词 xxx」都算；但「作曲家的眼泪」这种歌名不算
      if (s.length == w.length) return true;
      final String next = s[w.length];
      if (next == ':' || next == '：' || next == ' ' || next == '\t' ||
          next == '/' || next == '-' || next == '—') {
        return true;
      }
    }
    return false;
  }

  /// 解析成行（保持原文顺序；同一行多个时间戳会展开成多行）。
  static List<LyricLine> parse(String? lrc) {
    final List<LyricLine> out = <LyricLine>[];
    if (lrc == null || lrc.trim().isEmpty) return out;
    final String normalized =
        lrc.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    int order = 0;
    for (final String raw in normalized.split('\n')) {
      final List<int> stamps = <int>[];
      int lastEnd = 0;
      for (final Match m in _tsRe.allMatches(raw)) {
        stamps.add(_toMillis(m));
        lastEnd = m.end;
      }
      final String body = raw.substring(lastEnd);
      final List<LyricWord> words = <LyricWord>[];
      final String text =
          _stripWordTags(body, words, stamps.isEmpty ? 0 : stamps.first);
      if (stamps.isEmpty) continue;
      for (int si = 0; si < stamps.length; si++) {
        final LyricLine line = LyricLine(stamps[si], text);
        line.order = order++;
        // 逐字时间只挂第一个时间戳（多时间戳 = 整行重复，逐字表相同）
        if (si == 0 && words.isNotEmpty) line.words.addAll(words);
        out.add(line);
      }
    }
    return out;
  }

  /// 剥离 `<mm:ss.xx>` 逐字标记，返回纯文本，并把逐字时间填进 [words]。
  static String _stripWordTags(String body, List<LyricWord> words, int lineTime) {
    if (body.isEmpty) return '';
    final List<Match> list = _wordRe.allMatches(body).toList();
    if (list.isEmpty) return body.trim();
    final StringBuffer cur = StringBuffer();
    final StringBuffer plain = StringBuffer();
    int time = lineTime;
    int pos = 0;
    for (final Match m in list) {
      cur.write(body.substring(pos, m.start));
      if (cur.isNotEmpty) {
        words.add(LyricWord(time, cur.toString()));
        plain.write(cur.toString());
      }
      cur.clear();
      time = _toMillis(m);
      pos = m.end;
    }
    cur.write(body.substring(pos));
    if (cur.isNotEmpty) {
      words.add(LyricWord(time, cur.toString()));
      plain.write(cur.toString());
    }
    return plain.toString().trim();
  }

  /// 是否增强型 LRC（含逐字时间标记）。
  static bool isEnhanced(String? lrc) => lrc != null && _wordRe.hasMatch(lrc);

  /// 逐字音节总数（摘要 / 日志用）。
  static int wordCount(String? lrc) {
    int n = 0;
    for (final LyricLine line in parse(lrc)) {
      n += line.words.length;
    }
    return n;
  }

  /// 把任意歌词文本归一成标准 LRC。TTML 归一在  Ttml 后接入，目前原样返回。
  static String normalizeFormat(String? raw) => raw ?? '';

  /// 有时间轴的行数。
  static int timedLineCount(String? lrc) => parse(lrc).length;

  /// 清洗：去掉无时间戳的制作信息行与空行，保留全部时间轴行。
  static String clean(String? lrc) {
    if (lrc == null) return '';
    final Map<int, String> byTime = <int, String>{};
    for (final LyricLine line in parse(lrc)) {
      byTime.putIfAbsent(line.timeMs, () => line.text);
    }
    final String normalized =
        lrc.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final bool hasTimed = byTime.isNotEmpty;
    if (!hasTimed) {
      final StringBuffer plain = StringBuffer();
      for (final String raw in normalized.split('\n')) {
        final String s = raw.trim();
        if (s.isEmpty || isMetadataLine(s)) continue;
        plain.write(s);
        plain.write('\n');
      }
      return plain.toString();
    }
    final StringBuffer sb = StringBuffer();
    for (final MapEntry<int, String> e in byTime.entries) {
      sb.write(format(e.key));
      sb.write(e.value);
      sb.write('\n');
    }
    return sb.toString();
  }

  /// 把译文按时间点插到原文行后面，生成双语 LRC（毫秒最近邻，容差 150ms）。
  static String mergeTranslation(String? original, String? translation) {
    final String base = clean(original);
    final List<LyricLine> trans = parse(translation);
    if (trans.isEmpty) return base;
    final List<LyricLine> orig = parse(original);
    if (orig.isEmpty) return base;
    final Map<int, String> transByTime = <int, String>{};
    for (final LyricLine t in trans) {
      if (t.text.isEmpty || isMetadataLine(t.text)) continue;
      transByTime.putIfAbsent(t.timeMs, () => t.text);
    }
    if (transByTime.isEmpty) return base;
    final List<int> keys = transByTime.keys.toList()..sort();
    final StringBuffer sb = StringBuffer();
    for (final LyricLine line in orig) {
      sb.write(format(line.timeMs));
      sb.write(line.text);
      sb.write('\n');
      final int nearest = _nearest(keys, line.timeMs);
      if (nearest < 0) continue;
      final String? tr = transByTime[nearest];
      if (tr == null || tr == line.text) continue; // 纯音乐占位行不重复
      sb.write(format(line.timeMs));
      sb.write(tr);
      sb.write('\n');
    }
    return sb.toString();
  }

  /// 翻译行数（合并结果里与原文成对存在的行数）。
  static int translationLineCount(String merged) {
    final List<LyricLine> lines = parse(merged);
    int pairs = 0;
    for (int i = 1; i < lines.length; i++) {
      if (lines[i].timeMs == lines[i - 1].timeMs) pairs++;
    }
    return pairs;
  }

  /// 毫秒 → `[mm:ss.xx]`。
  static String format(int timeMs) {
    final int ms = timeMs < 0 ? 0 : timeMs;
    final int totalSec = ms ~/ 1000;
    final int min = totalSec ~/ 60;
    final int sec = totalSec % 60;
    final int cs = (ms % 1000) ~/ 10;
    return '[${min.toString().padLeft(2, '0')}:'
        '${sec.toString().padLeft(2, '0')}.'
        '${cs.toString().padLeft(2, '0')}]';
  }

  /// 按时间排序后的行（预览里显示前几行用）。
  static List<LyricLine> sorted(String? lrc) {
    final List<LyricLine> lines = parse(lrc);
    lines.sort((LyricLine a, LyricLine b) {
      final int c = a.timeMs.compareTo(b.timeMs);
      return c != 0 ? c : a.order.compareTo(b.order);
    });
    return lines;
  }

  /// 摘要：「58 行 · 含译文 52 行」。
  static String summary(String content) {
    final int total = timedLineCount(content);
    final int trans = translationLineCount(content);
    if (total == 0) return '纯文本（无时间轴）';
    return '$total 行${trans > 0 ? ' · 含译文 $trans 行' : ''}';
  }

  static int _toMillis(Match m) {
    final int minutes = int.parse(m.group(1)!);
    final int seconds = int.parse(m.group(2)!);
    final String? frac = m.group(3);
    int millis = 0;
    if (frac != null) {
      if (frac.length == 1) {
        millis = int.parse(frac) * 100;
      } else if (frac.length == 2) {
        millis = int.parse(frac) * 10;
      } else {
        millis = int.parse(frac);
      }
    }
    return minutes * 60000 + seconds * 1000 + millis;
  }

  static int _nearest(List<int> sorted, int target) {
    if (sorted.isEmpty) return -1;
    final int idx = _binarySearch(sorted, target);
    if (idx >= 0) return sorted[idx];
    final int insert = -idx - 1;
    int best = -1;
    int bestDiff = 0x7FFFFFFFFFFFFFFF;
    if (insert < sorted.length) {
      best = sorted[insert];
      bestDiff = (best - target).abs();
    }
    if (insert - 1 >= 0) {
      final int prev = sorted[insert - 1];
      final int diff = (prev - target).abs();
      if (diff < bestDiff) best = prev;
    }
    if (best < 0 || (best - target).abs() > translationToleranceMs) return -1;
    return best;
  }

  static int _binarySearch(List<int> a, int target) {
    int lo = 0;
    int hi = a.length - 1;
    while (lo <= hi) {
      final int mid = (lo + hi) >> 1;
      if (a[mid] == target) return mid;
      if (a[mid] < target) {
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return -lo - 1;
  }
}
