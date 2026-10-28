/// 归类目录模板：把「歌手 / 专辑」这种规则做成可配置的占位符串。
///
/// 只负责算出**目录路径**，不碰文件名——改名风险比搬目录大得多，
/// 两者要分开做。
library;

import '../model/tags.dart';

/// 一套目录规则。
class FolderTemplate {
  const FolderTemplate({required this.name, required this.pattern});

  /// 展示名（整理页里给用户选的就是它）。
  final String name;

  /// 模板本体：用 `/` 分层，支持 [fields] 里的占位符。
  final String pattern;

  /// 单段目录名长度上限（与 Organizer 保持一致）。
  static const int maxSegment = 60;

  /// 内置模板。**第一套是默认规则**（按歌手归位）。
  ///
  /// 只保留这两套：层级越少越好找，多一套「按年代」「按专辑打头」的规则
  /// 只会让人多犹豫一次，实际用起来和这两套没有本质区别。
  static const List<FolderTemplate> builtin = <FolderTemplate>[
    FolderTemplate(name: '歌手', pattern: '{artist}'),
    FolderTemplate(name: '歌手 / 专辑', pattern: '{artist}/{album}'),
  ];

  /// 可用占位符。
  static const Map<String, String> fields = <String, String>{
    'artist': '歌手',
    'album': '专辑',
    'year': '年代',
    'genre': '流派',
    'title': '歌名',
  };

  /// 合法字符里不允许出现的（与文件名规则一致）。
  static const String _illegal = '/\\:*?"<>|';

  /// 校验模板；合法返回 null，否则返回给人看的原因。
  static String? validate(String pattern) {
    final String p = pattern.trim();
    if (p.isEmpty) return '模板不能为空';
    final RegExp placeholder = RegExp(r'\{([a-zA-Z_]+)\}');
    final Iterable<RegExpMatch> matches = placeholder.allMatches(p);
    if (matches.isEmpty) return '至少要有一个占位符，例如 {artist}';
    for (final RegExpMatch m in matches) {
      final String key = m.group(1)!;
      if (!fields.containsKey(key)) {
        return '不认识的占位符 {$key}，可用：${fields.keys.map((String k) => '{$k}').join(' ')}';
      }
    }
    // 去掉占位符后还剩花括号 → 拼写有问题（如 {artist）
    if (p.replaceAll(placeholder, '').contains('{') ||
        p.replaceAll(placeholder, '').contains('}')) {
      return '占位符括号不配对';
    }
    final List<String> segs =
        p.split('/').where((String s) => s.trim().isNotEmpty).toList();
    if (segs.isEmpty) return '模板不能只由 / 组成';
    if (segs.length > 3) return '层级不要超过 3 层，太深反而难找';
    return null;
  }

  /// 按模板算目录路径（`/` 连接）。返回空串表示这套规则下归不了类。
  ///
  /// 空值处理：某一层里的占位符取到空串，就**整层丢掉**——宁可比预期少一层，
  /// 也不要造出空目录名或 `//`。
  String apply(Tags? tags, {String artist = '', String album = ''}) {
    final Map<String, String> values = <String, String>{
      'artist': artist.isNotEmpty ? artist : (tags?.get('artist') ?? ''),
      'album': album.isNotEmpty ? album : (tags?.get('album') ?? ''),
      'year': tags?.get('year') ?? '',
      'genre': tags?.get('genre') ?? '',
      'title': tags?.get('title') ?? '',
    };
    final List<String> out = <String>[];
    for (final String raw in pattern.split('/')) {
      final String seg = raw.trim();
      if (seg.isEmpty) continue;
      bool empty = false;
      final String filled = seg.replaceAllMapped(
        RegExp(r'\{([a-zA-Z_]+)\}'),
        (Match m) {
          final String v = (values[m.group(1)!] ?? '').trim();
          if (v.isEmpty) empty = true;
          return v;
        },
      );
      if (empty) continue;
      final String clean = _segment(filled);
      if (clean.isEmpty) continue;
      out.add(clean);
    }
    return out.join('/');
  }

  /// 折叠空白、替换非法字符、去首尾点与空格、超长截断。
  static String _segment(String raw) {
    final StringBuffer sb = StringBuffer();
    for (final int c in raw.trim().codeUnits) {
      final bool bad = c < 0x20 || _illegal.codeUnits.contains(c);
      sb.writeCharCode(bad ? 0x20 : c);
    }
    String s = sb.toString().replaceAll(RegExp(r'\s{2,}'), ' ').trim();
    s = s.replaceAll(RegExp(r'^[. ]+'), '').replaceAll(RegExp(r'[. ]+$'), '');
    if (s == '.' || s == '..') return '';
    if (s.length > maxSegment) s = s.substring(0, maxSegment).trim();
    return s;
  }

  /// 按 pattern 找内置模板；找不到就用它现造一个（自定义模板）。
  static FolderTemplate of(String pattern) {
    final String p = pattern.trim();
    for (final FolderTemplate t in builtin) {
      if (t.pattern == p) return t;
    }
    return FolderTemplate(name: p, pattern: p);
  }
}
