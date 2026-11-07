/// 字体缩放（0.3.9）：全局文字倍率，桌面端尤其需要——高分辨率屏上
/// 默认字号偏小，手机用户也可能想要大字。
///
/// 为什么不逐个改字号常量：`MoKit.fsTitle` 这类常量散落在几十个组件里，
/// 逐个乘倍率既容易漏又没法响应式刷新。这里统一用 [MediaQuery.textScaler]
/// 包在 MaterialApp 外层，Flutter 的文本渲染链会自动套用到所有 Text。
///
/// 取值范围 0.8~1.6（80%~160%），默认 1.0；桌面端默认给 1.15（Windows 上
/// 系统的 96 DPI 习惯下，13px 正文偏小，稍微放大更接近原生软件观感）。
library;

import 'package:flutter/material.dart';

/// 字体缩放控制器（全局单例，随设置持久化）。
class FontScale extends ChangeNotifier {
  FontScale._();
  static final FontScale instance = FontScale._();

  static const double minScale = 0.8;
  static const double maxScale = 1.6;
  static const double defaultScale = 1.0;

  /// 桌面端默认倍率：比手机稍大，贴近 Windows 原生软件的观感。
  static const double desktopDefaultScale = 1.15;

  double _scale = defaultScale;
  double get scale => _scale;

  /// 应用一个倍率（越界自动夹到合法区间）。
  void set(double value) {
    final double v = value.clamp(minScale, maxScale).toDouble();
    if (v == _scale) return;
    _scale = v;
    notifyListeners();
  }

  /// 档位列表（设置页用）：80% / 100% / 115% / 130% / 150%。
  static const List<double> steps = <double>[0.8, 1.0, 1.15, 1.3, 1.5];

  /// 百分比文案，如「115%」。
  static String label(double v) => '${(v * 100).round()}%';
}
