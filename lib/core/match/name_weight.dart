/// 文件名权重。
///
/// 权重 0%：只信已有标签；100%：只信文件名；50% 为分界线（>=50 以文件名为准）。
library;

import 'text_util.dart';

/// 文件名 / 标签取舍决策（纯 Dart）。
abstract final class NameWeight {
  /// 默认权重（百分比）：文件名作为弱信号，主要仍以已有标签为准。
  static const int defaultPercent = 20;

  static const int minPercent = 0;
  static const int maxPercent = 100;

  /// 把任意权重收敛到 [0,1]。
  static double clamp(double weight) {
    if (weight.isNaN) return fromPercent(defaultPercent);
    if (weight < 0) return 0;
    if (weight > 1) return 1;
    return weight;
  }

  /// 百分比（0~100）转权重（0~1）。
  static double fromPercent(int percent) {
    int p = percent;
    if (p < minPercent) p = minPercent;
    if (p > maxPercent) p = maxPercent;
    return p / 100.0;
  }

  /// 是否以文件名为主（>= 50%）。
  static bool preferFilename(double weight) => clamp(weight) >= 0.5;

  /// 按权重选出主用值；两边都为空返回 ""。
  static String pick(String? filenameValue, String? tagValue, double weight) {
    final String f = _trim(filenameValue);
    final String t = _trim(tagValue);
    if (preferFilename(weight)) return f.isEmpty ? t : f;
    return t.isEmpty ? f : t;
  }

  /// 与主用值相反的次要值；与主用值相同（或为空）时返回 ""。
  static String pickSecondary(String? filenameValue, String? tagValue, double weight) {
    final String f = _trim(filenameValue);
    final String t = _trim(tagValue);
    final String primary = pick(f, t, weight);
    final String secondary = preferFilename(weight) ? t : f;
    if (secondary.isEmpty) return '';
    if (TextUtil.normCompare(secondary) == TextUtil.normCompare(primary)) return '';
    return secondary;
  }

  static String _trim(String? value) => value == null ? '' : value.trim();
}
