import 'package:flutter/material.dart';

import 'mo_colors.dart';
import 'palette.dart';

/// 把 [MoPalette] 编译成 Flutter [ThemeData]。
abstract final class MoTheme {
  /// 构建主题数据。
  ///
  /// 0.3.17 起**不再** `ColorScheme.fromSeed` + 局部 copyWith：那样没覆盖到的槽位
  /// （secondaryContainer / tertiary…）会落回种子色生成的默认值，一屏绿紫混色。
  /// 现在直接按 16 个 token 填满 `ColorScheme`，颜色只有一个来源。
  ///
  /// [dark] 决定 brightness；语义色的明暗变体已内含在色板里。
  static ThemeData build(MoPalette p, {required bool dark}) {
    final Brightness brightness = dark ? Brightness.dark : Brightness.light;
    final ColorScheme scheme = ColorScheme(
      brightness: brightness,
      primary: p.primary,
      onPrimary: p.onPrimary,
      primaryContainer: p.primarySoft,
      onPrimaryContainer: p.primaryDark,
      secondary: p.accent,
      onSecondary: p.onPrimary,
      secondaryContainer: p.primarySoft,
      onSecondaryContainer: p.primaryDark,
      tertiary: p.accent,
      onTertiary: p.onPrimary,
      tertiaryContainer: p.primarySoft,
      onTertiaryContainer: p.primaryDark,
      error: p.err,
      onError: p.onPrimary,
      errorContainer: p.primarySoft,
      onErrorContainer: p.err,
      surface: p.card,
      onSurface: p.text,
      surfaceDim: p.bg,
      surfaceBright: p.card,
      surfaceContainerLowest: p.bg,
      surfaceContainerLow: p.bg,
      surfaceContainer: dark ? p.card : p.bg,
      surfaceContainerHigh: p.card,
      surfaceContainerHighest: p.primarySoft,
      onSurfaceVariant: p.body,
      outline: p.line,
      outlineVariant: p.line,
      shadow: Colors.black,
      scrim: Colors.black54,
      inverseSurface: p.text,
      onInverseSurface: p.bg,
      inversePrimary: p.onSurfacePrimary,
      surfaceTint: Colors.transparent,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: p.bg,
      // 当前色板挂给 MoKit 与自定义组件取色（见 MoColors）。
      extensions: <ThemeExtension<dynamic>>[MoColors(palette: p)],
      // 统一字体（0.3.10）：Windows 上不指定 fontFamily 时，英文/数字走
      // Segoe UI、中文回退到微软雅黑——两套字体的字重与字形不同，中英混排
      // 就会出现「同一行有粗有细」（用户反馈）。这里显式指定「微软雅黑 UI」：
      // 它覆盖中文，且自带西文字形，中英混排口径一致。
      // Windows 10/11 都自带；macOS / 安卓没有这个字体时会正常走系统回退。
      fontFamily: 'Microsoft YaHei UI',
      fontFamilyFallback: const <String>[
        'Microsoft YaHei',
        'Microsoft YaHei UI',
        'PingFang SC',
        'Noto Sans CJK SC',
        'sans-serif',
      ],
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
        iconTheme: WidgetStatePropertyAll<IconThemeData>(
          IconThemeData(color: p.body),
        ),
      ),
      dividerTheme: DividerThemeData(color: p.line, thickness: 0.5, space: 0.5),
      sliderTheme: SliderThemeData(
        activeTrackColor: p.primary,
        thumbColor: p.primary,
        inactiveTrackColor: p.primarySoft,
        overlayColor: p.primarySoft,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStatePropertyAll<Color>(p.primary),
        trackColor: WidgetStatePropertyAll<Color>(p.primarySoft),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: p.text,
        contentTextStyle: TextStyle(color: p.card, fontSize: 13),
        actionTextColor: p.onSurfacePrimary,
      ),
    );
  }
}
