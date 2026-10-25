import 'package:flutter/material.dart';

import 'palette.dart';

/// 把 [MoPalette] 编译成 Flutter [ThemeData]。
abstract final class MoTheme {
  /// 构建主题数据。
  ///
  /// [dark] 决定 brightness；语义色的明暗提亮变体已内含在各 palette 中。
  /// 组件级细节（圆角、 elevation、 chip 样式等）留待 T14 打磨。
  static ThemeData build(MoPalette p, {required bool dark}) {
    final Brightness brightness = dark ? Brightness.dark : Brightness.light;
    final ColorScheme scheme = ColorScheme(
      brightness: brightness,
      primary: p.primary,
      onPrimary: _on(p.primary),
      secondary: p.accent,
      onSecondary: _on(p.accent),
      error: p.err,
      onError: _on(p.err),
      surface: p.card,
      onSurface: p.text,
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
    );
  }

  /// 按背景亮度选黑 / 白前景，保证基本对比度。
  static Color _on(Color background) =>
      ThemeData.estimateBrightnessForColor(background) == Brightness.dark
          ? Colors.white
          : Colors.black;
}
