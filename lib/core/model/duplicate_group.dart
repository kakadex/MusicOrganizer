/// 文件名查重（模型与纯逻辑部分）。
///
/// 完整分组算法（UnionFind + bigram 倒排，find()）在 ；这里先给出
/// DuplicateGroup / DuplicateItem 模型与归一键、建议保留、摘要等纯逻辑。
library;

import '../match/name_parser.dart';
import '../match/text_util.dart';
import 'vfile.dart';

/// 查重组里的一个文件条目。
class DuplicateItem {
  DuplicateItem(this.file, this.relative, this.size, this.duration);

  final VFile file;
  final String relative;
  final int size;
  double? duration;
}

/// 一组相似文件。
class DuplicateGroup {
  DuplicateGroup(this.key);

  final List<DuplicateItem> files = <DuplicateItem>[];
  final String key;

  /// 组内最高相似度（1.0 表示归一后完全相同）。
  double score = 1.0;

  /// 疑似：相似度落在 [0.90, 0.95) 或靠包含度命中但读不到时长。
  bool suspect = false;

  /// 内容核验结果（[contentUnknown] / [contentSame] / [contentDiff]）。
  int content = DuplicateGroup.contentUnknown;

  /// 这一组最多能省多少空间（全部删掉只剩一个）。
  int wastedBytes() {
    int total = 0;
    for (final DuplicateItem it in files) {
      total += it.size;
    }
    final int keep = DuplicateGroup.recommendKeep(this);
    final int keepSize = keep >= 0 ? files[keep].size : 0;
    final int v = total - keepSize;
    return v < 0 ? 0 : v;
  }

  /// 「确证」档门槛。
  static const double highConfidence = 0.95;

  static const int contentUnknown = 0;
  static const int contentSame = 1;
  static const int contentDiff = 2;

  static final RegExp _copySuffixRe = RegExp(
      r'(?:\s*[（(]\s*\d+\s*[)）]|\s*[-_ ]\s*(?:副本|拷贝|copy|複製|复制)\s*\d*)*$',
      caseSensitive: false);
  static final RegExp _copyMarkRe = RegExp(
      r'[（(]\s*\d+\s*[)）]|[-_ ]\s*(?:副本|拷贝|copy|複製|复制)\s*\d*\s*$',
      caseSensitive: false);

  /// 只留字母数字的归一键。
  static String normalizeDuplicateKey(String? stem) {
    String text = TextUtil.stripTrailingNumericSuffix(stem ?? '');
    text = TextUtil.toSimplified(text).toLowerCase();
    text = text.replaceFirst(_copySuffixRe, '');
    text = text.replaceAll(RegExp(r'\s+'), '');
    final StringBuffer sb = StringBuffer();
    for (final int c in text.codeUnits) {
      if (_isLetterOrDigit(c)) sb.writeCharCode(c);
    }
    return sb.toString();
  }

  /// 只留歌名的归一键（「陈奕迅-十年」→「十年」）。
  static String titleKeyOf(String? stem) {
    final String s = stem ?? '';
    final NameSplit? split = NameParser.splitArtistTitle(s);
    final String title =
        split == null ? NameParser.stripNameNoise(s) : split.right;
    return normalizeDuplicateKey(title);
  }

  /// 只留艺人的归一键；解析不出艺人时返回空串。
  static String artistKeyOf(String? stem) {
    final NameSplit? split = NameParser.splitArtistTitle(stem ?? '');
    return split == null ? '' : normalizeDuplicateKey(split.left);
  }

  /// 建议保留哪一个（-1 表示没有明显更优的）。
  static int recommendKeep(DuplicateGroup? group) {
    if (group == null || group.files.isEmpty) return -1;
    int best = 0;
    double bestScore = -1;
    int maxSize = 1;
    for (final DuplicateItem it in group.files) {
      if (it.size > maxSize) maxSize = it.size;
    }
    for (int i = 0; i < group.files.length; i++) {
      final DuplicateItem it = group.files[i];
      double score = 0;
      if (!_copyMarkRe.hasMatch(it.file.stem())) score += 1.0;
      score += 0.40 * (it.size / maxSize);
      final double ratio = it.relative.length / 120.0;
      score -= 0.20 * (ratio > 1.0 ? 1.0 : ratio);
      if (score > bestScore) {
        bestScore = score;
        best = i;
      }
    }
    return best;
  }

  /// 内容核验结果的一句话说明；未核验返回空串。
  static String contentLabel(DuplicateGroup? group) {
    if (group == null) return '';
    if (group.content == contentSame) return '内容一致（首尾采样相同）';
    if (group.content == contentDiff) return '内容不同（只是名字像）';
    return '';
  }

  /// 摘要文案：「3 组 · 5 个多余文件 · 约 12.3 MB」。
  static String summary(List<DuplicateGroup>? groups) {
    if (groups == null || groups.isEmpty) return '没有发现相似文件';
    int wasted = 0;
    int extra = 0;
    int suspect = 0;
    int verified = 0;
    int differs = 0;
    for (final DuplicateGroup g in groups) {
      final int n = g.files.length - 1;
      extra += n > 0 ? n : 0;
      wasted += g.wastedBytes();
      if (g.suspect) suspect++;
      if (g.content == contentSame) {
        verified++;
      } else if (g.content == contentDiff) {
        differs++;
      }
    }
    final String head = suspect > 0
        ? '${groups.length} 组（其中 $suspect 组疑似）'
        : '${groups.length} 组';
    String tail = '';
    if (verified > 0) tail += ' · $verified 组已核验内容一致';
    if (differs > 0) tail += ' · $differs 组名字像但内容不同';
    return '$head · $extra 个多余文件 · 约 ${TextUtil.formatSize(wasted)}$tail';
  }

  /// 组内时长概览：「4:35 / 1:55 · 相差 2:40」；全都读不到时返回空串。
  static String durationSummary(DuplicateGroup? group) {
    if (group == null || group.files.isEmpty) return '';
    final StringBuffer text = StringBuffer();
    double min = double.infinity;
    double max = -1;
    for (final DuplicateItem it in group.files) {
      final double? d = it.duration;
      if (d == null || d <= 0) continue;
      final String one = TextUtil.formatDuration(d);
      if (one.isEmpty) continue;
      if (text.isNotEmpty) text.write(' / ');
      text.write(one);
      if (d < min) min = d;
      if (d > max) max = d;
    }
    if (text.isEmpty) return '';
    if (max > min) {
      final int diff = (max - min).round();
      if (diff >= 1) {
        text.write(' · 相差 ${TextUtil.formatDuration(diff.toDouble())}');
      }
    }
    int known = 0;
    for (final DuplicateItem it in group.files) {
      if (it.duration != null && it.duration! > 0) known++;
    }
    if (known < group.files.length) text.write('（部分未知）');
    return text.toString();
  }

  static bool _isLetterOrDigit(int c) {
    return (c >= 0x30 && c <= 0x39) ||
        (c >= 0x41 && c <= 0x5A) ||
        (c >= 0x61 && c <= 0x7A) ||
        (c >= 0x4E00 && c <= 0x9FFF) ||
        (c >= 0x3040 && c <= 0x30FF) ||
        (c >= 0xAC00 && c <= 0xD7AF);
  }
}
