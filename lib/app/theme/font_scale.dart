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

  /// 桌面端默认倍率。
  ///
  /// 原来是 1.15，但非整数缩放会让 Windows 上文字笔画粗细不匀（用户反馈
  /// 「同一行有粗有细」，实锤是 115% 造成的）。改回 1.0 保证渲染干净；
  /// 觉得字小的用户可以在设置里选 125% / 150%，或调 Windows 系统缩放。
  static const double desktopDefaultScale = 1.0;

  double _scale = defaultScale;
  double get scale => _scale;

  /// 应用一个倍率（越界自动夹到合法区间）。
  void set(double value) {
    final double v = value.clamp(minScale, maxScale).toDouble();
    if (v == _scale) return;
    _scale = v;
    notifyListeners();
  }

  /// 档位列表（设置页用）。
  ///
  /// **只用整数倍率**（0.4.0）：Flutter 的字体栅格化在非整数缩放（如 1.15、
  /// 1.3）下会产生笔画粗细不匀、边缘发糊——用户在 Windows 上反馈「同一行
  /// 有粗有细」，实测是 115% 缩放导致。改成 100%/125%/150% 这类整档，
  /// 缩放结果更干净。需要更细的调节就用 Windows 系统缩放。
  static const List<double> steps = <double>[1.0, 1.25, 1.5];

  /// 百分比文案，如「115%」。
  static String label(double v) => '${(v * 100).round()}%';
}
