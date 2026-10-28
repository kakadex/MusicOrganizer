/// 文件名模板：按标签把文件改成「歌手 - 歌名」这类约定名。
///
/// 纯逻辑（不碰盘）：[render] 只做字符串拼装，清理规则在
/// `TextUtil.normalizeStemForCleanup`，两者分开才好单独测。
library;

import '../match/text_util.dart';
import '../model/tags.dart';

/// 模板渲染与文件名整形。
abstract final class NameTemplate {
  /// 常用预设（顺序即界面里的顺序）。
  static const List<String> presets = <String>[
    '{artist} - {title}',
    '{title} - {artist}',
    '{track}. {title}',
    '{artist} - {album} - {track}. {title}',
    '{title}',
  ];

  /// 默认模板。
  static const String fallback = '{artist} - {title}';

  /// 占位符说明（界面里直接显示）。
  static String help() =>
      '可用占位符：{artist} 艺人、{title} 标题、{album} 专辑、{year} 年份、'
      '{track} 音轨、{genre} 流派、{ext} 原扩展名。'
      '音轨可指定位数，如 {track:3} → 007。未知占位符按空处理。';

  /// 允许的占位符名（含 `{track:N}` 的位数写法）。
  static const Set<String> tokens = <String>{
    'artist', 'title', 'album', 'year', 'date', 'genre', 'track', 'ext',
  };

  /// 校验模板；合法返回 null，否则返回给人看的原因。
  ///
  /// 为什么必须在改名前校验：`{atrist}` 这种拼错会让渲染结果变成空串，
  /// 用户看到的是「按模板拼不出名字」，根本猜不到是自己拼错了。
  static String? validate(String? pattern) {
    final String p = (pattern ?? '').trim();
    if (p.isEmpty) return '模板不能为空';
    if (!p.contains('{')) return '至少要有一个占位符，例如 {artist}';
    final RegExp re = RegExp(r'\{([^{}]*)\}');
    for (final RegExpMatch m in re.allMatches(p)) {
      final String token = (m.group(1) ?? '').trim();
      final List<String> parts = token.split(':');
      final String name = parts.first.trim().toLowerCase();
      if (name.isEmpty) return '占位符不能为空';
      if (!tokens.contains(name)) return '不认识的占位符 {$name}';
      if (parts.length > 2) return '{$token} 写法不对，只支持 {track:3} 这种';
      if (parts.length == 2) {
        final int? width = int.tryParse(parts[1].trim());
        if (name != 'track') return '只有 {track} 可以指定位数';
        if (width == null || width < 1 || width > 4) {
          return '{track:$parts[1]} 的位数只能是 1~4';
        }
      }
    }
    // 去掉合法占位符后还剩花括号 → 括号没配对
    if (p.replaceAll(re, '').contains('{') || p.replaceAll(re, '').contains('}')) {
      return '占位符括号不配对';
    }
    return null;
  }

  /// 由一条标签记录构造字段表。
  static Map<String, String> fields(Tags? tags) {
    final Map<String, String> m = <String, String>{};
    if (tags == null) return m;
    m['artist'] = TextUtil.safeStr(tags.get('artist'));
    m['title'] = TextUtil.safeStr(tags.get('title'));
    m['album'] = TextUtil.safeStr(tags.get('album'));
    m['year'] = TextUtil.safeStr(tags.get('year'));
    m['date'] = TextUtil.safeStr(tags.get('year'));
    m['genre'] = TextUtil.safeStr(tags.get('genre'));
    m['track'] = TextUtil.safeStr(tags.get('track'));
    return m;
  }

  /// 音轨号补零：1 → 01；`3/12` 这种只取前一段；非数字原样返回。
  static String padTrack(String? value, [int width = 2]) {
    if (value == null) return '';
    String v = value.trim();
    final int slash = v.indexOf('/');
    if (slash > 0) v = v.substring(0, slash).trim();
    if (v.isEmpty) return '';
    for (int i = 0; i < v.length; i++) {
      final int c = v.codeUnitAt(i);
      if (c < 0x30 || c > 0x39) return v;
    }
    while (v.length < width) {
      v = '0$v';
    }
    return v;
  }

  /// 渲染模板；返回的是**完整文件名**（含扩展名）。字段全空时返回空串。
  static String render(String? pattern, Map<String, String> fields, String? ext) {
    final String p =
        (pattern == null || pattern.trim().isEmpty) ? fallback : pattern.trim();
    final Map<String, String> f = fields;
    String e = (ext ?? '').trim();
    if (e.isNotEmpty && !e.startsWith('.')) e = '.$e';

    final bool wantsExt = p.toLowerCase().contains('{ext}');
    final StringBuffer out = StringBuffer();
    int i = 0;
    while (i < p.length) {
      final String c = p[i];
      if (c == '{') {
        final int close = p.indexOf('}', i + 1);
        if (close < 0) {
          // 没闭合：原样保留，别把用户正在输入的内容吃掉
          out.write(p.substring(i));
          break;
        }
        out.write(_valueOf(p.substring(i + 1, close).trim(), f, e));
        i = close + 1;
      } else {
        out.write(c);
        i++;
      }
    }

    String name = tidy(out.toString());
    if (name.isEmpty) {
      // 字段全空：别硬补扩展名（会把 ".mp3" 变成 "mp3"）
      return '';
    }
    if (!wantsExt) {
      name = tidy('$name$e');
    }
    if (name.length > 90) {
      name = name.substring(0, 90).trim();
      // 截断后可能把扩展名切掉，补回去
      if (!wantsExt && e.isNotEmpty && !name.toLowerCase().endsWith(e.toLowerCase())) {
        if (name.length + e.length <= 90) {
          name = '$name$e';
        }
      }
    }
    return name;
  }

  static String _valueOf(String token, Map<String, String> f, String ext) {
    // 支持 {track:3}：位数只对音轨有意义（专辑号之类的字段还没纳入模型）
    final List<String> parts = token.split(':');
    final String name = parts.first.trim().toLowerCase();
    if (name == 'track') {
      final int width =
          parts.length == 2 ? (int.tryParse(parts[1].trim()) ?? 2) : 2;
      return padTrack(f['track'] ?? '', width.clamp(1, 4));
    }
    switch (name) {
      case 'artist':
        return f['artist'] ?? '';
      case 'title':
        return f['title'] ?? '';
      case 'album':
        return f['album'] ?? '';
      case 'year':
      case 'date':
        return f['year'] ?? '';
      case 'genre':
        return f['genre'] ?? '';
      case 'ext':
        return ext;
      default:
        return '';
    }
  }

  /// 去掉首尾空白/点、压缩连续空格、清理非法字符。
  static String tidy(String? raw) {
    if (raw == null) return '';
    String s = sanitize(raw);
    // 1. 字段缺失会留下「 - 」「. 」这类残渣：连续多段分隔符只留最后一个
    s = _collapseSeparators(s);
    // 2. 首尾的分隔符与空白
    s = s.replaceFirst(RegExp(r'^[\s\-_.·—–]+'), '');
    s = s.replaceFirst(RegExp(r'[\s\-_.·—–]+$'), '');
    // 3. 「晴天 -夜曲」这种一边没空格的横线补成「 - 」（T-N-T 这种不带空格的不动）
    s = s.replaceAll(RegExp(r'\s+-\s*|\s*-\s+'), ' - ');
    // 4. 压缩多余空白
    s = s.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
    return s;
  }

  /// 连续分隔符只保留最后一个：「周杰伦 -  - 晴天」→「周杰伦 - 晴天」。
  static String _collapseSeparators(String s) {
    final StringBuffer out = StringBuffer();
    int i = 0;
    while (i < s.length) {
      final String c = s[i];
      if (!_isSeparator(c)) {
        out.write(c);
        i++;
        continue;
      }
      int j = i + 1;
      bool another = false;
      while (j < s.length) {
        final String d = s[j];
        if (d == ' ') {
          j++;
          continue;
        }
        another = _isSeparator(d);
        break;
      }
      if (another) {
        i = j;
        continue;
      }
      out.write(c);
      i++;
    }
    return out.toString();
  }

  static bool _isSeparator(String c) =>
      c == '-' || c == '_' || c == '.' || c == '·' || c == '—' || c == '–';

  /// 非法字符替换成空格（不删，避免两个词粘一起），并压缩空格。
  static String sanitize(String? raw) {
    if (raw == null) return '';
    final StringBuffer sb = StringBuffer();
    for (int i = 0; i < raw.length; i++) {
      final String c = raw[i];
      if (c.codeUnitAt(0) < 0x20 || '\\/:*?"<>|'.contains(c)) {
        sb.write(' ');
      } else {
        sb.write(c);
      }
    }
    return sb.toString().replaceAll(RegExp(r'\s{2,}'), ' ').trim();
  }

  /// 冲突时的候选名：`名 (2).mp3`。
  static String withIndex(String name, int index) {
    if (name.isEmpty) return name;
    final int dot = name.lastIndexOf('.');
    final String stem = dot > 0 ? name.substring(0, dot) : name;
    final String ext = dot > 0 ? name.substring(dot) : '';
    return '$stem ($index)$ext';
  }
}
