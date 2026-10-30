/// 标签繁转简：算出每首歌需要改哪些字段（纯逻辑，不碰盘）。
///
/// 单独放一层是为了能脱离界面单测：界面只负责「读标签 → 问一次 → 走事务写回」。
library;

import '../lyrics/zh.dart';
import '../model/tags.dart';

/// 标签繁转简的计划。
abstract final class TagZh {
  /// 参与转换的键：常规字段 + 内嵌歌词（歌词不在 [Tags.keys] 里，单独加）。
  static List<String> get fields => <String>[...Tags.keys, Tags.lyrics];

  /// 返回「字段 → 转成简体后的值」，只包含真的会变的字段。
  ///
  /// 空字段跳过：空值转换还是空值，不该出现在预览里。
  static Map<String, String> changes(Tags tags) {
    final Map<String, String> out = <String, String>{};
    for (final String k in fields) {
      final String old = tags.get(k);
      if (old.trim().isEmpty) continue;
      final String now = Zh.toSimplified(old);
      if (now != old) out[k] = now;
    }
    return out;
  }

  /// 有没有需要改的字段。
  static bool hasChange(Tags tags) => changes(tags).isNotEmpty;
}
