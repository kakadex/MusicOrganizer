import 'package:flutter/material.dart';

import 'palette.dart';

/// 把当前色板挂到 [ThemeData.extensions] 上，让 `MoKit` 与组件主题拿到同一套
/// 设计 token（0.3.17）。
///
/// 为什么需要它：`ColorScheme` 只有固定的槽位名，而我们的色板有 16 个语义字段
/// （faint / onSurfacePrimary / primarySoft 等没有对应槽位）。挂在 extension 上
/// 就不用为了取一个颜色去反查 `ColorScheme` 的近似槽位。
@immutable
class MoColors extends ThemeExtension<MoColors> {
  const MoColors({required this.palette});

  final MoPalette palette;

  @override
  MoColors copyWith({MoPalette? palette}) =>
      MoColors(palette: palette ?? this.palette);

  @override
  MoColors lerp(ThemeExtension<MoColors>? other, double t) {
    if (other is! MoColors) return this;
    // 深浅切换本来就不该有渐变（色值差异大，插值中间态会发灰），直接换。
    return t < 0.5 ? this : other;
  }
}
