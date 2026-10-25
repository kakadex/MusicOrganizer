import 'package:flutter/material.dart';

/// 主题方案标识 —— 对应旧项目 `core/Theme.java` 的 WARM / MINIMAL / LYRICO。
enum MoThemeId {
  /// 暖橙黑胶：温润奶油底 + 暖橙强调。
  warm('暖橙'),

  /// 简紫：纯净留白 + 靛蓝点缀（默认）。
  minimal('简紫'),

  /// 简蓝：Material You 蓝调，圆润克制。
  lyrico('简蓝');

  const MoThemeId(this.label);

  /// 界面展示名（设置页 / 切换胶囊）。
  final String label;
}

/// 一组完整的界面配色（不可变值对象；字段与旧 `Theme.Palette` 一一对应）。
@immutable
class MoPalette {
  const MoPalette({
    required this.bg,
    required this.card,
    required this.primary,
    required this.primaryDark,
    required this.primarySoft,
    required this.text,
    required this.body,
    required this.sub,
    required this.line,
    required this.ok,
    required this.warn,
    required this.err,
    required this.accent,
  });

  /// 页面背景。
  final Color bg;

  /// 卡片 / 面板背景。
  final Color card;

  /// 主色（按钮、选中、强调、进度）。
  final Color primary;

  /// 主色深一档。
  final Color primaryDark;

  /// 主色的浅底（胶囊容器、待处理徽标底）。
  final Color primarySoft;

  /// 主文字 / 标题。
  final Color text;

  /// 正文。
  final Color body;

  /// 辅助 / caption。
  final Color sub;

  /// 分割线 / 描边。
  final Color line;

  /// 成功语义色。
  final Color ok;

  /// 警告语义色。
  final Color warn;

  /// 错误语义色。
  final Color err;

  /// 点缀色。
  final Color accent;

  /// 取某主题某明暗下的调色板；themeId 越界按「简紫」处理。
  static MoPalette of(MoThemeId id, {required bool dark}) {
    switch (id) {
      case MoThemeId.warm:
        return dark ? warmDark : warmLight;
      case MoThemeId.lyrico:
        return dark ? lyricoDark : lyricoLight;
      case MoThemeId.minimal:
        return dark ? minimalDark : minimalLight;
    }
  }

  // ------------------------------------------------------------------
  // 暖橙黑胶
  // ------------------------------------------------------------------

  /// 暖橙 · 亮。
  static const MoPalette warmLight = MoPalette(
    bg: Color(0xFFFFF1E6),
    card: Color(0xFFFFFFFF),
    primary: Color(0xFFFF7A45),
    primaryDark: Color(0xFFC75B2E),
    primarySoft: Color(0xFFF5EBE0),
    text: Color(0xFF2B2018),
    body: Color(0xFF5A4A38),
    sub: Color(0xFF9A7B54),
    line: Color(0xFFEADBC8),
    ok: Color(0xFF3FA66A),
    warn: Color(0xFFE0A100),
    err: Color(0xFFD64545),
    accent: Color(0xFFE9C46A),
  );

  /// 暖橙 · 暗。
  static const MoPalette warmDark = MoPalette(
    bg: Color(0xFF1E130D),
    card: Color(0xFF2A1C14),
    primary: Color(0xFFFF8A5C),
    primaryDark: Color(0xFFFF7A45),
    primarySoft: Color(0xFF3A261B),
    text: Color(0xFFF7EBE0),
    body: Color(0xFFD9C6B4),
    sub: Color(0xFFA99080),
    line: Color(0xFF3A2A20),
    ok: Color(0xFF4FBF82),
    warn: Color(0xFFF0B429),
    err: Color(0xFFF0736C),
    accent: Color(0xFFE9C46A),
  );

  // ------------------------------------------------------------------
  // 极简清感（默认）
  // ------------------------------------------------------------------

  /// 简紫 · 亮。
  static const MoPalette minimalLight = MoPalette(
    bg: Color(0xFFF5F6FA),
    card: Color(0xFFFFFFFF),
    primary: Color(0xFF4F46E5),
    primaryDark: Color(0xFF3730A3),
    primarySoft: Color(0xFFEEF0F8),
    text: Color(0xFF1A1C23),
    body: Color(0xFF3A3F52),
    sub: Color(0xFF6B7194),
    line: Color(0xFFE3E6F0),
    ok: Color(0xFF10B981),
    warn: Color(0xFFF59E0B),
    err: Color(0xFFEF4444),
    accent: Color(0xFF10B981),
  );

  /// 简紫 · 暗。
  static const MoPalette minimalDark = MoPalette(
    bg: Color(0xFF13151C),
    card: Color(0xFF1C1E27),
    primary: Color(0xFF6C63FF),
    primaryDark: Color(0xFF4F46E5),
    primarySoft: Color(0xFF262A3D),
    text: Color(0xFFE8EAF0),
    body: Color(0xFFC3C7D4),
    sub: Color(0xFF9AA1B0),
    line: Color(0xFF2A2D3A),
    ok: Color(0xFF34D399),
    warn: Color(0xFFFBBF24),
    err: Color(0xFFFB7185),
    accent: Color(0xFF34D399),
  );

  // ------------------------------------------------------------------
  // 简蓝
  // ------------------------------------------------------------------

  /// 简蓝 · 亮。
  static const MoPalette lyricoLight = MoPalette(
    bg: Color(0xFFF5F7FB),
    card: Color(0xFFFFFFFF),
    primary: Color(0xFF3D7BFF),
    primaryDark: Color(0xFF2A5BE0),
    primarySoft: Color(0xFFE6EEFF),
    text: Color(0xFF141A2E),
    body: Color(0xFF3C445E),
    sub: Color(0xFF6B7280),
    line: Color(0xFFE4E8F2),
    ok: Color(0xFF1FA971),
    warn: Color(0xFFF2A33C),
    err: Color(0xFFF0506E),
    accent: Color(0xFF3D7BFF),
  );

  /// 简蓝 · 暗。
  static const MoPalette lyricoDark = MoPalette(
    bg: Color(0xFF0F1218),
    card: Color(0xFF181C25),
    primary: Color(0xFF5B8BFF),
    primaryDark: Color(0xFF3D7BFF),
    primarySoft: Color(0xFF1E2740),
    text: Color(0xFFE9EDF6),
    body: Color(0xFFB6BED4),
    sub: Color(0xFF8A91A6),
    line: Color(0xFF262B38),
    ok: Color(0xFF34D399),
    warn: Color(0xFFFBBF24),
    err: Color(0xFFFB7185),
    accent: Color(0xFF5B8BFF),
  );
}
