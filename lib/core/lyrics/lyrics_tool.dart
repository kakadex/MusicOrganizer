/// 歌词清洗：统一格式、去空行、去元信息、去时间轴、规范化时间轴、去重复行。
///
/// 纯逻辑（不碰盘）。写盘仍走事务层。
library;

/// 歌词清洗动作位（界面勾选项与这里的常量一一对应）。
abstract final class LyricsTool {
  /// 删空行。
  static const int opEmpty = 1;

  /// 去头部元信息（`[ti:]` `[ar:]` `[offset:]` 这类）。
  static const int opHeader = 2;

  /// 去时间轴，只留纯文本。
  static const int opTimestamp = 4;

  /// 规范化时间轴（`[1:2.3]` → `[01:02.30]`）。
  static const int opNormalize = 8;

  /// 去完全重复的行。
  static const int opDedupe = 16;

  /// 时间轴：`[mm:ss]` / `[mm:ss.xx]` / `[mm:ss.xxx]`。
  static final RegExp _timeTag =
      RegExp(r'\[(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\]');

  /// LRC 头部元信息。
  static final RegExp _headerTag = RegExp(
      r'\[(ti|ar|al|au|by|offset|re|ve|length|tool|encoding)\s*:[^\]]*\]',
      caseSensitive: false);

  /// 统一换行、去掉 UTF-8 BOM、行尾空格。
  static String normalize(String? text) {
    if (text == null || text.isEmpty) return '';
    String s = text;
    if (s.startsWith('﻿')) {
      s = s.substring(1);
    }
    s = s.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final List<String> lines = s.split('\n');
    final List<String> out = <String>[];
    for (final String line in lines) {
      out.add(line.replaceFirst(RegExp(r'[ \t]+$'), ''));
    }
    return out.join('\n');
  }

  /// 删空行（只含空白也算空）。
  static String stripEmptyLines(String? text) {
    final String s = normalize(text);
    if (s.isEmpty) return '';
    final List<String> out = <String>[];
    for (final String line in s.split('\n')) {
      if (line.trim().isEmpty) continue;
      out.add(line);
    }
    return out.join('\n');
  }

  /// 去掉 `[ti:][ar:][al:][by:][offset:]` 这类头部元信息（整行都是标签的才删）。
  static String stripHeaders(String? text) {
    final String s = normalize(text);
    if (s.isEmpty) return '';
    final List<String> out = <String>[];
    for (final String line in s.split('\n')) {
      final String rest = line.replaceAll(_headerTag, '').trim();
      if (rest.isEmpty) continue; // 整行都是元信息 → 丢掉
      out.add(line);
    }
    return out.join('\n');
  }

  /// 去掉时间轴，只留纯文本。
  static String stripTimestamps(String? text) {
    final String s = stripEmptyLines(text);
    if (s.isEmpty) return '';
    final List<String> out = <String>[];
    for (final String line in s.split('\n')) {
      final String plain = line.replaceAll(_timeTag, '').trim();
      if (plain.isEmpty) continue;
      out.add(plain);
    }
    return out.join('\n');
  }

  /// 时间轴规范化：`[1:2.3]` → `[01:02.30]`，`[00:05]` → `[00:05.00]`。
  static String normalizeTimestamps(String? text) {
    final String s = normalize(text);
    if (s.isEmpty) return '';
    final List<String> out = <String>[];
    for (final String line in s.split('\n')) {
      out.add(_normalizeLineTags(line));
    }
    return out.join('\n');
  }

  /// 去掉完全重复的行（多源合并 / 二次抓取常见）。
  static String dedupeLines(String? text) {
    final String s = normalize(text);
    if (s.isEmpty) return '';
    final Set<String> seen = <String>{};
    final List<String> out = <String>[];
    for (final String line in s.split('\n')) {
      if (line.trim().isEmpty) continue;
      if (!seen.add(line)) continue;
      out.add(line);
    }
    return out.join('\n');
  }

  /// 按动作位组合处理。
  static String apply(String? text, int ops) {
    String s = text ?? '';
    if (ops & opEmpty != 0) s = stripEmptyLines(s);
    if (ops & opHeader != 0) s = stripHeaders(s);
    if (ops & opDedupe != 0) s = dedupeLines(s);
    if (ops & opTimestamp != 0) s = stripTimestamps(s);
    if (ops & opNormalize != 0) s = normalizeTimestamps(s);
    return s;
  }

  static String _normalizeLineTags(String line) {
    return line.replaceAllMapped(_timeTag, (Match m) {
      final int ms = _toMillis(m.group(1)!, m.group(2)!, m.group(3));
      return _formatTag(ms);
    });
  }

  static int _toMillis(String min, String sec, String? frac) {
    int m = int.tryParse(min) ?? 0;
    int s = int.tryParse(sec) ?? 0;
    int f = 0;
    if (frac != null && frac.isNotEmpty) {
      final int v = int.tryParse(frac) ?? 0;
      // 1 位 → 百毫秒，2 位 → 十毫秒，3 位 → 毫秒
      if (frac.length == 1) {
        f = v * 100;
      } else if (frac.length == 2) {
        f = v * 10;
      } else {
        f = v;
      }
    }
    return m * 60000 + s * 1000 + f;
  }

  /// 统一格式的时间轴：`[mm:ss.xx]`。
  static String _formatTag(int ms) {
    final int totalSec = ms ~/ 1000;
    final int min = totalSec ~/ 60;
    final int sec = totalSec % 60;
    final int cs = (ms % 1000) ~/ 10;
    return '[${_pad(min, 2)}:${_pad(sec, 2)}.${_pad(cs, 2)}]';
  }

  static String _pad(int value, int width) {
    String s = value < 0 ? '0' : '$value';
    while (s.length < width) {
      s = '0$s';
    }
    return s;
  }
}
