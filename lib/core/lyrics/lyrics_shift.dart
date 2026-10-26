/// 歌词时间轴整体偏移。
///
/// 常见场景：歌词来自别的版本，整体快/慢半秒到一秒；或者自己唱的录音比歌词早。
/// 把**所有时间戳**（行首 `[mm:ss.xx]` 与逐字 `<mm:ss.xx>`）统一加减同一个毫秒数。
///
/// 几条约定：
/// - 只动真正的数字时间戳，`[ar:歌手]`、`[ti:标题]` 这类元信息原样保留；
/// - 偏移后小于 0 的钳到 0（负时间播放器不认）；
/// - 保留原来的小数位数（两位就还是两位）；
/// - 一行多个时间戳（同一句重复出现）全部一起偏移。
library;

/// 歌词时间轴偏移（纯逻辑）。
abstract final class LyricsShift {
  /// 只匹配「数字时间戳」：方括号是行时间，尖括号是逐字时间。
  static final RegExp _stamp =
      RegExp(r'([\[<])(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?([\]>])');

  /// 偏移全部时间戳；[deltaMs] 为正表示整体往后推。
  static String shift(String? lrc, int deltaMs) {
    if (lrc == null || lrc.isEmpty || deltaMs == 0) return lrc ?? '';
    return lrc.replaceAllMapped(_stamp, (Match m) => _format(m, deltaMs));
  }

  /// 有多少个时间戳（判断值不值得偏移、界面提示用）。
  static int count(String? lrc) {
    if (lrc == null || lrc.isEmpty) return 0;
    return _stamp.allMatches(lrc).length;
  }

  /// 第一个时间戳（毫秒），没有返回 -1。
  static int firstStamp(String? lrc) {
    if (lrc == null || lrc.isEmpty) return -1;
    final Match? m = _stamp.firstMatch(lrc);
    if (m == null) return -1;
    return _millisOf(m);
  }

  /// 最后一个时间戳（毫秒），没有返回 -1。
  static int lastStamp(String? lrc) {
    if (lrc == null || lrc.isEmpty) return -1;
    final List<Match> all = _stamp.allMatches(lrc).toList();
    if (all.isEmpty) return -1;
    return _millisOf(all.last);
  }

  /// 偏移后是不是所有时间戳都变成 0（整首歌都挤到 0 秒，播放器会认不出来）。
  static bool collapsesToZero(String? lrc, int deltaMs) {
    if (lrc == null || lrc.isEmpty) return false;
    final List<Match> all = _stamp.allMatches(lrc).toList();
    if (all.isEmpty) return false;
    for (final Match m in all) {
      if (_millisOf(m) + deltaMs > 0) return false;
    }
    return true;
  }

  static int _millisOf(Match m) {
    final int min = int.tryParse(m.group(2)!) ?? 0;
    final int sec = int.tryParse(m.group(3)!) ?? 0;
    final String? frac = m.group(4);
    int ms = 0;
    if (frac != null && frac.isNotEmpty) {
      final int v = int.tryParse(frac) ?? 0;
      if (frac.length == 1) {
        ms = v * 100;
      } else if (frac.length == 2) {
        ms = v * 10;
      } else {
        ms = v;
      }
    }
    return min * 60000 + sec * 1000 + ms;
  }

  static String _format(Match m, int deltaMs) {
    int t = _millisOf(m) + deltaMs;
    if (t < 0) t = 0;
    final int totalSec = t ~/ 1000;
    final int min = totalSec ~/ 60;
    final int sec = totalSec % 60;
    final int ms = t % 1000;
    final String? frac = m.group(4);
    final StringBuffer out = StringBuffer();
    out.write(m.group(1));
    out.write(_pad(min, 2));
    out.write(':');
    out.write(_pad(sec, 2));
    if (frac != null && frac.isNotEmpty) {
      out.write('.');
      if (frac.length == 1) {
        out.write(ms ~/ 100);
      } else if (frac.length == 2) {
        out.write(_pad(ms ~/ 10, 2));
      } else {
        out.write(_pad(ms, 3));
      }
    }
    out.write(m.group(5));
    return out.toString();
  }

  static String _pad(int value, int width) {
    String s = value < 0 ? '0' : '$value';
    while (s.length < width) {
      s = '0$s';
    }
    return s;
  }
}
