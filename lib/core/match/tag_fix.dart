/// 标签文本的本地批量修正。
///
/// 与联网匹配无关：只把已经写在文件里的文本整理干净 —— 去首尾空白、折叠多余
/// 空格、全角转半角、音轨号补零。纯函数，不读盘不写盘，便于离线回归。
///
/// 动作位可任意组合：[trim] / [spaces] / [width] / [padTrack]（音轨补零）；
/// 单值补零见 [track]。
library;

import '../model/tags.dart';

abstract final class TagFix {
  /// 去首尾空白。
  static const int trim = 1;

  /// 把连续空格 / 制表符折叠成一个空格。
  static const int spaces = 2;

  /// 全角字母数字标点转半角（汉字不动）。
  static const int width = 4;

  /// 音轨号补零：`1` → `01`，`1/12` → `01/12`。
  static const int padTrack = 8;

  /// 会被处理的字段（与标签编辑器里的六个候选字段一致）。
  static const List<String> fields = <String>[
    'title', 'artist', 'album', 'year', 'track', 'genre',
  ];

  /// 对一个值做指定修正；[ops] 为 0 或值本来就干净时返回原串。
  static String clean(String value, int ops) {
    if (value.isEmpty || ops == 0) return value;
    String s = value;
    if ((ops & width) != 0) s = fullToHalf(s);
    if ((ops & spaces) != 0) s = collapseSpaces(s);
    if ((ops & trim) != 0) s = s.trim();
    return s;
  }

  /// 音轨号补零。已是两位以上、或不是纯数字就原样返回；`1/12` 只处理分子。
  static String track(String value) {
    final String v = value.trim();
    if (v.isEmpty) return '';
    final int slash = v.indexOf('/');
    if (slash > 0) {
      return '${_pad(v.substring(0, slash).trim())}/'
          '${v.substring(slash + 1).trim()}';
    }
    return _pad(v);
  }

  /// 算出「这条标签需要改哪些字段」。
  ///
  /// 只返回真正变化的字段，没有变化时返回空 Map（调用方据此跳过写盘）。
  static Map<String, String> plan(Tags tags, int ops) {
    final Map<String, String> out = <String, String>{};
    for (final String f in fields) {
      final String old = tags.get(f);
      if (old.isEmpty) continue;
      final String now = f == 'track' ? _cleanAndTrack(old, ops) : clean(old, ops);
      if (now != old) out[f] = now;
    }
    return out;
  }

  /// 全角（FF01–FF5E、U+3000）转半角，其它字符（含汉字）原样保留。
  static String fullToHalf(String s) {
    final StringBuffer sb = StringBuffer();
    for (final int c in s.codeUnits) {
      if (c == 0x3000) {
        sb.writeCharCode(0x20);
      } else if (c >= 0xFF01 && c <= 0xFF5E) {
        sb.writeCharCode(c - 0xFEE0);
      } else {
        sb.writeCharCode(c);
      }
    }
    return sb.toString();
  }

  /// 连续空白（空格 / 制表符 / 全角空格）折叠成一个半角空格。
  static String collapseSpaces(String s) {
    final StringBuffer sb = StringBuffer();
    bool lastSpace = false;
    for (final int c in s.codeUnits) {
      final bool space = c == 0x20 || c == 0x09 || c == 0x3000;
      if (space) {
        if (!lastSpace) sb.writeCharCode(0x20);
        lastSpace = true;
      } else {
        sb.writeCharCode(c);
        lastSpace = false;
      }
    }
    return sb.toString();
  }

  static String _cleanAndTrack(String value, int ops) {
    String s = clean(value, ops & ~padTrack);
    if ((ops & padTrack) != 0) s = track(s);
    return s;
  }

  static String _pad(String num) {
    if (num.isEmpty) return num;
    for (final int c in num.codeUnits) {
      if (c < 0x30 || c > 0x39) return num; // "A1" / "0-9" 之类不碰
    }
    return num.length == 1 ? '0$num' : num;
  }
}
