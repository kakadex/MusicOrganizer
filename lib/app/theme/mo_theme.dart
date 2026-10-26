import 'package:flutter/material.dart';

import 'palette.dart';

/// 把 [MoPalette] 编译成 Flutter [ThemeData]。
abstract final class MoTheme {
  /// 构建主题数据。
  ///
  /// [dark] 决定 brightness；语义色的明暗提亮变体已内含在各 palette 中。
  /// 组件级细节（圆角、 elevation、 chip 样式等）留待 。
  static ThemeData build(MoPalette p, {required bool dark}) {
    final Brightness brightness = dark ? Brightness.dark : Brightness.light;
    // 以主色为种子生成完整配色，再把「页面底 / 卡片面 / 文字 / 线条」按调色板校正。
    //
    // 为什么不能只填 primary/surface：M3 组件（NavigationBar、Chip、Checkbox…）
    // 读的是 secondaryContainer / surfaceContainer / outline 这些槽位；
    // 不填就落到基线默认色（一屏绿 + 紫，最显廉价的那种混色）。
    final ColorScheme base = ColorScheme.fromSeed(
      seedColor: p.primary,
      brightness: brightness,
    );
    final ColorScheme scheme = base.copyWith(
      primary: p.primary,
      onPrimary: _on(p.primary),
      secondary: p.accent,
      onSecondary: _on(p.accent),
      error: p.err,
      onError: _on(p.err),
      surface: p.card,
      onSurface: p.text,
      surfaceContainerLowest: p.bg,
      surfaceContainerLow: p.bg,
      surfaceContainer: dark ? p.card : p.bg,
      surfaceContainerHigh: p.card,
      surfaceContainerHighest: dark ? p.line : p.primarySoft,
      onSurfaceVariant: p.body,
      outline: p.line,
      outlineVariant: p.line,
      primaryContainer: p.primarySoft,
      onPrimaryContainer: p.primaryDark,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: p.bg,
      appBarTheme: AppBarTheme(
        backgroundColor: p.card,
        foregroundColor: p.text,
        elevation: 0,
        centerTitle: true,
      ),
      textTheme: TextTheme(
        titleLarge: TextStyle(color: p.text),
        titleMedium: TextStyle(color: p.text),
        bodyLarge: TextStyle(color: p.body),
        bodyMedium: TextStyle(color: p.body),
        bodySmall: TextStyle(color: p.sub),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: p.card,
        indicatorColor: p.primarySoft,
        elevation: 0,
        labelTextStyle: WidgetStatePropertyAll<TextStyle>(
          TextStyle(fontSize: 11, color: p.sub, fontWeight: FontWeight.w500),
        ),
        iconTheme: WidgetStatePropertyAll<IconThemeData>(IconThemeData(color: p.body)),
      ),
      dividerTheme: DividerThemeData(color: p.line, thickness: 0.5, space: 0.5),
      sliderTheme: SliderThemeData(
        activeTrackColor: p.primary,
        thumbColor: p.primary,
        inactiveTrackColor: p.line,
        overlayColor: p.primarySoft,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStatePropertyAll<Color>(p.primary),
        trackColor: WidgetStatePropertyAll<Color>(p.primarySoft),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: p.text,
        contentTextStyle: TextStyle(color: p.card, fontSize: 13),
        actionTextColor: p.accent,
      ),
    );
  }

  /// 按背景亮度选黑 / 白前景，保证基本对比度。
  static Color _on(Color background) =>
      ThemeData.estimateBrightnessForColor(background) == Brightness.dark
          ? Colors.white
          : Colors.black;
}
