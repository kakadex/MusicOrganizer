import 'package:flutter/material.dart';

/// 一套完整的界面配色（不可变值对象）。
///
/// 0.3.17：原来的「暖橙 / 简紫 / 简蓝」三套配色已删除，只保留浅 / 深两张中性
/// 色板，另可由系统动态色（Android 12+）派生。字段从 13 个扩到 16 个：
/// 新增 [onPrimary]、[onSurfacePrimary]（解决「主色既做按钮底又做文字」的
/// 对比度冲突）与 [faint]（三级弱化文字的实色，替掉原来 40% 透明度）。
@immutable
class MoPalette {
  const MoPalette({
    required this.bg,
    required this.card,
    required this.primary,
    required this.onPrimary,
    required this.primaryDark,
    required this.primarySoft,
    required this.onSurfacePrimary,
    required this.text,
    required this.body,
    required this.sub,
    required this.faint,
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

  /// 主色（按钮底、选中、进度）。
  final Color primary;

  /// 主色底上的前景（暗色主色上用深字，见 D7）。
  final Color onPrimary;

  /// 主色深一档。
  final Color primaryDark;

  /// 主色的浅底（胶囊容器、选中态容器）。
  final Color primarySoft;

  /// 文字 / 图标用的强调色（比 [primary] 在底色上更清楚）。
  final Color onSurfacePrimary;

  /// 主文字 / 标题。
  final Color text;

  /// 正文。
  final Color body;

  /// 辅助 / caption。
  final Color sub;

  /// 第三级弱化（占位、禁用态）；对底色 ≥3:1，不用透明度。
  final Color faint;

  /// 分割线 / 描边（装饰用，不承担分层职责）。
  final Color line;

  /// 成功语义色。
  final Color ok;

  /// 警告语义色。
  final Color warn;

  /// 错误语义色。
  final Color err;

  /// 点缀色（与主色同系，不再出现绿色）。
  final Color accent;

  /// 浅色板。
  static const MoPalette light = MoPalette(
    bg: Color(0xFFF7F8FB),
    card: Color(0xFFFFFFFF),
    primary: Color(0xFF3F5AA6),
    onPrimary: Color(0xFFFFFFFF),
    primaryDark: Color(0xFF2C4178),
    primarySoft: Color(0xFFE9EDF8),
    onSurfacePrimary: Color(0xFF35508F),
    text: Color(0xFF171A21),
    body: Color(0xFF343A4B),
    sub: Color(0xFF5A6073),
    faint: Color(0xFF7C8394),
    line: Color(0xFFDFE3EC),
    ok: Color(0xFF15803D),
    warn: Color(0xFFB45309),
    err: Color(0xFFC62828),
    accent: Color(0xFF3F5AA6),
  );

  /// 深色板。
  static const MoPalette dark = MoPalette(
    bg: Color(0xFF12141A),
    card: Color(0xFF1B1E27),
    primary: Color(0xFF8FA6E8),
    onPrimary: Color(0xFF17182B),
    primaryDark: Color(0xFF3F5AA6),
    primarySoft: Color(0xFF232C42),
    onSurfacePrimary: Color(0xFFB6C6FF),
    text: Color(0xFFECEEF4),
    body: Color(0xFFC4CAD8),
    sub: Color(0xFFA0A7BA),
    faint: Color(0xFF7E8798),
    line: Color(0xFF303441),
    ok: Color(0xFF4ADE80),
    warn: Color(0xFFFBBF24),
    err: Color(0xFFFB7185),
    accent: Color(0xFF8FA6E8),
  );

  /// 由系统动态色（Android 12+ 的 `system_*` 资源）构造一套色板。
  ///
  /// [c] 的键形如 `a1_600` / `n1_50`（见 `SystemColorsPlugin.kt`）。缺键或值为 0
  /// 时回退到同明暗的固定色板——**语义色（ok/warn/err）固定不跟壁纸变**：
  /// 系统色板没有「成功 / 警告」语义，让错误红变成壁纸紫会破坏可理解性。
  factory MoPalette.fromSystem(Map<String, int> c, {required bool dark}) {
    Color get(String key, Color fallback) {
      final int? v = c[key];
      // 系统资源可能只给 RGB（alpha=0），补上不透明再用，避免整块透明。
      return v == null || v == 0 ? fallback : Color(0xFF000000 | v);
    }

    final MoPalette base = dark ? MoPalette.dark : MoPalette.light;
    final String a1 = dark ? 'a1_200' : 'a1_600';
    return MoPalette(
      bg: get(dark ? 'n1_900' : 'n1_50', base.bg),
      card: get(dark ? 'n1_800' : 'n1_10', base.card),
      primary: get(a1, base.primary),
      onPrimary: get(dark ? 'a1_800' : 'a1_0', base.onPrimary),
      primaryDark: get(dark ? 'a1_300' : 'a1_700', base.primaryDark),
      primarySoft: get(dark ? 'a1_700' : 'a1_100', base.primarySoft),
      onSurfacePrimary: get(dark ? 'a1_100' : 'a1_700', base.onSurfacePrimary),
      text: get(dark ? 'n1_100' : 'n1_900', base.text),
      body: get(dark ? 'n1_200' : 'n1_800', base.body),
      sub: get(dark ? 'n2_300' : 'n2_700', base.sub),
      faint: get(dark ? 'n2_400' : 'n2_600', base.faint),
      line: get(dark ? 'n2_700' : 'n2_200', base.line),
      // 语义色不跟壁纸变。
      ok: base.ok,
      warn: base.warn,
      err: base.err,
      accent: get(dark ? 'a2_200' : 'a2_600', base.accent),
    );
  }
}

/// 系统动态色的浅 / 深两套（Android 12+ 才有；其它平台为 null）。
@immutable
class SystemPaletteSet {
  const SystemPaletteSet({required this.light, required this.dark});

  final MoPalette light;
  final MoPalette dark;
}
