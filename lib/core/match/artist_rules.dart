/// 歌手返回合理性校验。
///
/// 七条校验：非空长度 / 含文字 / 不等于歌名 / 不等于原名 / 无非法字符 /
/// 非占位词 / 与候选一致。
library;

import 'name_parser.dart';
import 'text_util.dart';

final Set<String> _genericArtists = <String>{
  'unknown', 'unknownartist', 'n/a', 'na', 'none', 'null',
  '未知', '未知歌手', '未知艺术家', 'artist', '歌手', 'various', 'variousartists',
  'va', 'v.a.', '群星', '合辑', '华语群星', '群星合辑', '华语合辑',
  '网络歌手', '佚名', 'traditional', '未知专辑',
};

final RegExp _audioExtRe = RegExp(
    r'\.(?:mp3|flac|m4a|wav|ogg|aac|wma|ape|opus|lrc|krc|qrc|trc|srt)$',
    caseSensitive: false);
final RegExp _splitRe = RegExp(
    r'(?:、|·|・|/|＆|&|,|，|;|；|\+|\bfeat\.?\b|\bft\.?\b|\bwith\b)',
    caseSensitive: false);
final RegExp _mainSplitRe =
    RegExp(r'\bfeat\b|\bft\b|（|\(|\bwith\b', caseSensitive: false);
final RegExp _hasTextRe =
    RegExp(r'[A-Za-z\u4e00-\u9fff\u3040-\u30ff\uac00-\ud7af]');
final RegExp _urlRe = RegExp(r'https?://|www\.', caseSensitive: false);

/// 歌手返回合理性校验（纯 Dart）。
abstract final class ArtistRules {
  /// 候选归一：繁转简 + 去污染后缀 + 空白折叠 + 首尾 . _ 空格剥离。
  static String normalizeCandidate(String? text) {
    String v = TextUtil.toSimplified(text ?? '').trim();
    v = TextUtil.stripTrailingNumericSuffix(v);
    v = v.replaceAll(RegExp(r'\s+'), ' ').trim();
    return _trimEdge(v);
  }

  /// 期望歌手与返回歌手是否相容（相等 / 包含 / 分词交集 / 主体匹配 / 相似度）。
  static bool artistsCompatible(String expected, String returned) {
    final String exp = TextUtil.normCompare(TextUtil.toSimplified(expected));
    final String ret = TextUtil.normCompare(TextUtil.toSimplified(returned));
    if (exp.isEmpty || ret.isEmpty) return false;
    if (exp == ret) return true;
    if (exp.length >= 2 &&
        ret.length >= 2 &&
        (exp.contains(ret) || ret.contains(exp))) {
      return true;
    }
    final Set<String> a = <String>{..._artistTokens(expected)};
    for (final String t in _artistTokens(returned)) {
      if (a.contains(t)) return true;
    }
    final String expMain = _firstSegment(exp);
    final String retMain = _firstSegment(ret);
    if (expMain.isNotEmpty &&
        retMain.isNotEmpty &&
        (expMain.contains(retMain) || retMain.contains(expMain))) {
      return true;
    }
    return TextUtil.ratio(exp, ret) >= 0.80;
  }

  /// 歌手返回合理性校验（七条规则）。
  static bool isReasonableArtistReturn(String? artist, String? searchTitle,
      String? originalStem, String? expectedArtist) {
    final String text = normalizeCandidate(artist);
    if (text.isEmpty || text.length > 120) return false;
    if (!_hasTextRe.hasMatch(text)) return false;
    if (TextUtil.normCompare(text) ==
        TextUtil.normCompare(NameParser.stripNameNoise(searchTitle))) {
      return false;
    }
    final String cleanOriginal = NameParser.stripNameNoise(originalStem);
    if (TextUtil.normCompare(text) == TextUtil.normCompare(originalStem) ||
        TextUtil.normCompare(text) == TextUtil.normCompare(cleanOriginal)) {
      return false;
    }
    if (text.contains('<') ||
        text.contains('>') ||
        text.contains('"') ||
        text.contains('|') ||
        text.contains('?') ||
        text.contains('*') ||
        text.contains('\r') ||
        text.contains('\n') ||
        text.contains('\t') ||
        text.contains('\\') ||
        text.contains('/')) {
      return false;
    }
    if (_urlRe.hasMatch(text)) return false;
    for (final int c in text.codeUnits) {
      if (c < 32) return false;
    }
    if (_genericArtists.contains(TextUtil.normCompare(text))) return false;
    if (_audioExtRe.hasMatch(text.toLowerCase())) return false;
    int dash = 0;
    int under = 0;
    for (final int c in text.codeUnits) {
      if (c == 0x2D) {
        dash++;
      } else if (c == 0x5F) {
        under++;
      }
    }
    if (dash >= 4 || under >= 5) return false;
    if (expectedArtist != null && expectedArtist.trim().isNotEmpty) {
      return artistsCompatible(expectedArtist, text);
    }
    return true;
  }

  /// 是否是「占位歌手标签」（群星 / Various Artists / 未知 …）。
  static bool isGenericArtist(String? text) {
    final String key = TextUtil.normCompare(text ?? '');
    if (key.isEmpty) return true;
    return _genericArtists.contains(key) ||
        key == TextUtil.normCompare(TextUtil.unknownArtist) ||
        key == TextUtil.normCompare(TextUtil.unrecognizedDir);
  }

  /// 通用目录名：这些一级目录**不是歌手**，不能进「已知歌手目录」。
  static const Set<String> _genericFolders = <String>{
    'music', 'musics', 'audio', 'audios', 'sound', 'sounds', 'song', 'songs',
    'download', 'downloads', 'media', 'mymusic', 'musiclibrary',
    '音乐', '歌曲', '音频', '我的音乐', '音乐库', '本地音乐', '下载', '下载音乐',
    '新建文件夹', '未分类', '其他', '其它', '杂项', '合集', '专辑', 'album', 'albums',
  };

  /// 目录名是不是「通用容器名」（不是歌手）。
  static bool isGenericFolder(String? text) {
    final String key = TextUtil.normCompare(text ?? '');
    if (key.isEmpty) return true;
    return _genericFolders.contains(key);
  }

  /// 歌手目录的归一键：写法不同、实际同一艺人的名字要落到同一个目录。
  static String folderKey(String? text) {
    final String n = TextUtil.normCompare(TextUtil.toSimplified(text ?? ''));
    return n
        .replaceAll('&', 'and')
        .replaceAll('＆', 'and')
        .replaceAll('、', 'and')
        .replaceAll('，', 'and')
        .replaceAll(',', 'and')
        .replaceAll('+', 'and');
  }

  static String _trimEdge(String v) {
    int start = 0;
    int end = v.length;
    while (start < end && ' ._'.contains(v[start])) {
      start++;
    }
    while (end > start && ' ._'.contains(v[end - 1])) {
      end--;
    }
    return v.substring(start, end);
  }

  static List<String> _artistTokens(String text) {
    final String normalized =
        TextUtil.normCompare(TextUtil.toSimplified(text));
    final List<String> out = <String>[];
    if (normalized.isEmpty) return out;
    for (final String part in normalized.split(_splitRe)) {
      if (part.trim().isNotEmpty) out.add(part.trim());
    }
    return out;
  }

  static String _firstSegment(String s) {
    final List<String> parts = s.split(_mainSplitRe);
    return parts.isNotEmpty ? parts[0] : s;
  }
}
