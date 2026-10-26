/// 文件名解析。
///
/// strip_name_noise / split_artist_title（居中分隔符优先、双向识别）/ 候选生成。
library;

import 'text_util.dart';

/// 分隔符（连字符家族，含前后空白）。
final RegExp _dashRe = RegExp(r'\s*(?:-|–|—|－|~|～)\s*');

/// 一次拆分：左半、右半、风格。
class NameSplit {
  const NameSplit(this.left, this.right, this.style);

  final String left;
  final String right;
  final String style;
}

/// 文件名候选：artist 可能为空。
class NameCandidate {
  const NameCandidate(this.artist, this.title, this.style);

  final String? artist;
  final String title;
  final String style;

  @override
  bool operator ==(Object other) {
    if (other is! NameCandidate) return false;
    final String a = TextUtil.normCompare(artist ?? '');
    final String b = TextUtil.normCompare(other.artist ?? '');
    return a == b &&
        TextUtil.normCompare(title) == TextUtil.normCompare(other.title);
  }

  @override
  int get hashCode =>
      TextUtil.normCompare(title).hashCode * 31 +
      TextUtil.normCompare(artist ?? '').hashCode;
}

/// 文件名解析（纯 Dart）。
abstract final class NameParser {
  /// 去污染后缀 + 轨道前缀 + 首尾书名号/方括号。
  static String stripNameNoise(String? stem) {
    String text =
        TextUtil.stripTrailingNumericSuffix(stem == null ? '' : stem.trim());
    text = TextUtil.stripTrackPrefix(text).trim();
    if (text.length >= 2 &&
        ((text[0] == '[' && text[text.length - 1] == ']') ||
            (text[0] == '《' && text[text.length - 1] == '》'))) {
      text = text.substring(1, text.length - 1).trim();
    }
    return text;
  }

  /// 拆分为 (左, 右, 风格)。居中分隔符优先；无分隔符返回 null。
  static NameSplit? splitArtistTitle(String stem) {
    final String text = stripNameNoise(stem);
    final List<Match> ranges = _dashRe.allMatches(text).toList();
    if (ranges.isEmpty) return null;
    final double center = text.length / 2.0;
    Match? chosen;
    double best = double.negativeInfinity;
    for (final Match r in ranges) {
      final String left = text.substring(0, r.start).trim();
      final String right = text.substring(r.end).trim();
      if (left.isEmpty || right.isEmpty) continue;
      final double score = -((r.start + r.end) / 2.0 - center).abs();
      if (score > best) {
        best = score;
        chosen = r;
      }
    }
    if (chosen == null) return null;
    final bool spaced = RegExp(r'\s[-–—－~～]\s').hasMatch(text);
    return NameSplit(
      text.substring(0, chosen.start).trim(),
      text.substring(chosen.end).trim(),
      spaced ? 'F1' : 'F3',
    );
  }

  /// 文件名候选：有分隔符时给出双向两个候选，否则单段歌名。
  static List<NameCandidate> nameCandidates(String stem) {
    final String normalized = stripNameNoise(stem);
    final List<NameCandidate> out = <NameCandidate>[];
    if (normalized.isEmpty) return out;
    final NameSplit? split = splitArtistTitle(stem);
    if (split != null) {
      final String reverse = split.style == 'F1' ? 'F2' : 'F4';
      out.add(NameCandidate(split.left, split.right, split.style));
      out.add(NameCandidate(split.right, split.left, reverse));
    } else {
      out.add(NameCandidate(null, normalized, 'F5/F6'));
    }
    return out;
  }

  /// 文件名解析结果 → (artist, title) 对，供聚合器与歌词匹配使用。
  static List<List<String>> candidatePairs(String stem) {
    final List<List<String>> pairs = <List<String>>[];
    for (final NameCandidate c in nameCandidates(stem)) {
      final String artist = c.artist == null ? '' : c.artist!.trim();
      final String title = c.title.trim();
      if (title.isNotEmpty && !_containsPair(pairs, artist, title)) {
        pairs.add(<String>[artist, title]);
      }
    }
    return pairs;
  }

  static bool _containsPair(
      List<List<String>> pairs, String artist, String title) {
    for (final List<String> p in pairs) {
      if (p[0] == artist && p[1] == title) return true;
    }
    return false;
  }
}
