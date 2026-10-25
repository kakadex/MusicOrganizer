/// 数据源优先级与候选排序（T10a）—— 移植自旧 core/SourceRank.java。
///
/// **为什么国内源在前**：中文歌的标题 / 艺人 / 专辑在国内站是母语录入，
/// 海外库里同一首歌常是罗马字或英文译名，照抄下来就把标签写坏了。
/// 海外源仍然保留 —— 冷门外语歌、国内站点没收的曲目还得靠它们。
///
/// **为什么不把国内源无条件排最前**：置信度明显更高时（差 > [cnPreferBand]）
/// 仍按置信度排，否则「国内源给了个错同名歌」会硬压掉海外源的正确结果。
library;

/// 源优先级与排序（纯 Dart）。
abstract final class SourceRank {
  /// 优先级顺序（中文曲目）：下标越小越靠前。
  ///
  /// 国内五家按召回质量排：网易（字段最全，有 publishTime 年份）→ QQ（有 index_album 音轨）
  /// → 酷狗 → 酷我 → 咪咕（只用来补流派）；海外三家：MusicBrainz 作为锚点仍在 Deezer/iTunes 之前。
  static const List<String> order = <String>[
    'netease', 'qqmusic', 'kugou', 'kuwo', 'migu',
    'musicbrainz', 'deezer', 'itunes',
  ];

  /// 优先级顺序（外文曲目）：海外三家在前、国内五家在后。
  static const List<String> orderOverseasFirst = <String>[
    'musicbrainz', 'deezer', 'itunes',
    'netease', 'qqmusic', 'kugou', 'kuwo', 'migu',
  ];

  /// 国内源的个数（前 5 个）。
  static const int chineseCount = 5;

  /// 中文曲目下「国内源优先」的置信度宽容带。
  ///
  /// 各源基数不同：MusicBrainz 0.85 / Deezer·iTunes 0.75，国内五家统一 0.60。
  /// 若只比绝对置信度，0.85 的外文译名会永远压过 0.60 的中文原名，
  /// 顺序表里的「国内优先」根本触发不了。给 0.30 的宽容带：
  /// 只要 |差| ≤ 0.30，国内源即压过海外源；差得更多仍按置信度，避免错配。
  static const double cnPreferBand = 0.30;

  /// 置信度容差：差在这个范围内的两个候选视为「持平」。
  ///
  /// 各源置信度来自不同算法，0.8031 与 0.8025 之间没有意义；
  /// 但直接比浮点会让海外源偶然领先，结果同一张专辑里有的写中文名有的写罗马字。
  static const double tolerance = 0.001;

  /// 吸收浮点误差的极小余量。
  static const double epsilon = 1e-9;

  /// 按优先级排列的源列表（副本，调用方随便改）。
  static List<String> ordered({bool chinese = true}) =>
      List<String>.of(chinese ? order : orderOverseasFirst);

  /// 源优先级（中文曲目语义：国内优先）；未登记的源排最后。
  static int priority(String? source) {
    if (source == null) return order.length;
    final int at = order.indexOf(source);
    return at < 0 ? order.length : at;
  }

  /// 源在指定语种顺序表里的下标；未登记排最后。
  static int rankIndex(String? source, bool chinese) {
    final List<String> list = chinese ? order : orderOverseasFirst;
    if (source == null) return list.length;
    final int at = list.indexOf(source);
    return at < 0 ? list.length : at;
  }

  /// 是否国内源（网易 / QQ / 酷狗 / 酷我 / 咪咕）。
  static bool isChinese(String? source) => priority(source) < chineseCount;

  /// 源的展示名（日志与「低置信」提示用）。
  static String label(String? source) {
    switch (source) {
      case 'netease':
        return '网易云';
      case 'qqmusic':
        return 'QQ 音乐';
      case 'kugou':
        return '酷狗';
      case 'kuwo':
        return '酷我';
      case 'migu':
        return '咪咕';
      case 'musicbrainz':
        return 'MusicBrainz';
      case 'deezer':
        return 'Deezer';
      case 'itunes':
        return 'iTunes';
      default:
        return source ?? '';
    }
  }

  /// 比较两个候选。
  ///
  /// 负值表示 a 排在 b 前面（与 [Comparator] 约定一致）。
  static int compare(String sourceA, double confidenceA,
      String sourceB, double confidenceB,
      {bool chinese = true}) {
    final double diff = confidenceA - confidenceB;
    if (chinese) {
      final bool aCn = isChinese(sourceA);
      final bool bCn = isChinese(sourceB);
      if (aCn != bCn && diff.abs() <= cnPreferBand) {
        return aCn ? -1 : 1;
      }
    }
    // +epsilon：0.9000 - 0.9010 在 double 里是 -0.0010000000000000009，
    // 正好卡在边界上会被误判成「明显不同」，加个极小余量吸收浮点误差
    if (diff.abs() > tolerance + epsilon) {
      return diff > 0 ? -1 : 1;
    }
    final int pa = rankIndex(sourceA, chinese);
    final int pb = rankIndex(sourceB, chinese);
    if (pa != pb) return pa - pb;
    if (diff > 0) return -1;
    return diff < 0 ? 1 : 0;
  }
}
