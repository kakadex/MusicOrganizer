/// 批量标签的「这个字段要不要写」判定。
///
/// 字段级三态策略：
/// - disabled   不写：这个字段永远不动；
/// - supplement 只补空：已有值不动（默认），避免把用户整理好的标签越改越乱；
/// - overwrite  覆盖：候选值与当前值不同就写。
///
/// 旧的「两态」语义（是否整体覆盖）通过 [defaultModes] 兼容。
library;

import 'text_util.dart';

/// 三态策略与字段标签（纯 Dart）。
abstract final class TagFill {
  static const int disabled = 0;
  static const int supplement = 1;
  static const int overwrite = 2;

  /// 在线候选能提供的字段（comment 永远不自动写，容易盖掉用户备注）。
  static const List<String> candidateFields = <String>[
    'title', 'artist', 'albumArtist', 'album', 'year', 'track', 'genre',
  ];

  /// 字段中文标签（等价旧 Tags.LABELS； core/model/tags.dart 后改为引用）。
  static const Map<String, String> tagLabels = <String, String>{
    'title': '标题',
    'artist': '艺术家',
    'albumArtist': '专辑艺术家',
    'album': '专辑',
    'year': '年份',
    'track': '音轨',
    'genre': '流派',
    'comment': '注释',
    'lyrics': '歌词',
  };

  /// 字段中文标签（预览 / 设置里显示）。
  static String label(String key) => tagLabels[key] ?? key;

  /// 三态的中文名。
  static String modeName(int mode) {
    switch (mode) {
      case disabled:
        return '不写';
      case overwrite:
        return '覆盖';
      default:
        return '只补空';
    }
  }

  /// 默认策略：overwrite ? 全覆盖 : 全只补空。
  static Map<String, int> defaultModes(bool overwrite) {
    final Map<String, int> m = <String, int>{};
    for (final String f in candidateFields) {
      m[f] = overwrite ? TagFill.overwrite : TagFill.supplement;
    }
    return m;
  }

  /// 取某字段策略；缺省按「只补空」。
  static int modeOf(Map<String, int>? modes, String key) {
    if (modes == null) return supplement;
    return modes[key] ?? supplement;
  }

  /// 三态差异：disabled 不写、supplement 只补空、overwrite 不同就写。
  /// 返回空 Map 表示这首不用动。
  static Map<String, String> diff(
    Map<String, String>? before,
    Map<String, String>? candidate, {
    Map<String, int>? modes,
    bool? overwrite,
  }) {
    final Map<String, String> out = <String, String>{};
    if (candidate == null) return out;
    final Map<String, int> m = modes ?? defaultModes(overwrite ?? false);
    for (final String key in candidateFields) {
      final int mode = modeOf(m, key);
      if (mode == disabled) continue;
      final String newValue = TextUtil.safeStr(candidate[key]).trim();
      if (newValue.isEmpty) continue;
      final String oldValue =
          before == null ? '' : TextUtil.safeStr(before[key]).trim();
      if (oldValue == newValue) continue;
      if (mode == supplement && oldValue.isNotEmpty) continue;
      out[key] = newValue;
    }
    return out;
  }

  /// 三态饱和：所有 supplement 字段都已有值、且没有 overwrite 字段 → 无字段可写。
  static bool isSaturated(
    Map<String, String>? before, {
    Map<String, int>? modes,
    bool? overwrite,
  }) {
    if (before == null) return false;
    final Map<String, int> m = modes ?? defaultModes(overwrite ?? false);
    for (final String key in candidateFields) {
      final int mode = modeOf(m, key);
      if (mode == TagFill.overwrite) return false;
      if (mode == supplement &&
          TextUtil.safeStr(before[key]).trim().isEmpty) {
        return false;
      }
    }
    return true;
  }

  /// 预览摘要，如「标题、专辑、年份」。
  static String describe(Map<String, String>? updates) {
    if (updates == null || updates.isEmpty) return '';
    final StringBuffer sb = StringBuffer();
    for (final String key in updates.keys) {
      if (sb.isNotEmpty) sb.write('、');
      sb.write(label(key));
    }
    return sb.toString();
  }
}
