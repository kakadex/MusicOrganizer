import 'package:flutter/material.dart';

import 'mo_theme.dart';
import 'palette.dart';

// 命名参数不能以 `_` 开头，所以 `this._mode` 这种初始化形式写法在这里不成立
// （lint 的建议只对位置参数有效）。参数名是对外 API，保持可读，逐条改为
// ignore 又太吵，这里统一关掉这一条。
// ignore_for_file: prefer_initializing_formals

/// 外观三态：跟随系统 / 浅色 / 深色。
///
/// - [systemPalette]：Android 12+ 的系统动态色；其它平台为 null → 用固定中性板。
/// - [systemDark]：桌面端由原生侧推来的「系统当前是否深色」。有值时「跟随系统」
///   解算成明确的 light / dark（Windows 上 Flutter 的 platformBrightness 不保证
///   随系统切换即时刷新，见 0.3.17 发版说明）；null 时交给 Flutter 的
///   `ThemeMode.system`。
class ThemeController extends ChangeNotifier {
  ThemeController({
    ThemeMode mode = ThemeMode.system,
    SystemPaletteSet? systemPalette,
    bool? systemDark,
  })  : _mode = mode,
        _systemPalette = systemPalette,
        _systemDark = systemDark;

  ThemeMode _mode;
  final SystemPaletteSet? _systemPalette;
  bool? _systemDark;

  ThemeMode get mode => _mode;

  SystemPaletteSet? get systemPalette => _systemPalette;

  bool? get systemDark => _systemDark;

  /// 实际交给 `MaterialApp.themeMode` 的值：跟随系统且有明确明暗时解算成
  /// light / dark，否则原样 `system`。
  ThemeMode get effectiveMode {
    if (_mode != ThemeMode.system) return _mode;
    final bool? d = _systemDark;
    if (d == null) return ThemeMode.system;
    return d ? ThemeMode.dark : ThemeMode.light;
  }

  /// 当前是否深色；`null` = 由系统决定（桌面标题栏据此恢复跟随系统）。
  bool? get effectiveDark {
    switch (effectiveMode) {
      case ThemeMode.dark:
        return true;
      case ThemeMode.light:
        return false;
      case ThemeMode.system:
        return null;
    }
  }

  /// 只有「跟随系统」才用动态色；浅色 / 深色一律固定色板（D2）。
  MoPalette _palette(bool dark) {
    final SystemPaletteSet? sys = _systemPalette;
    if (_mode == ThemeMode.system && sys != null) {
      return dark ? sys.dark : sys.light;
    }
    return dark ? MoPalette.dark : MoPalette.light;
  }

  ThemeData get lightTheme => MoTheme.build(_palette(false), dark: false);

  ThemeData get darkTheme => MoTheme.build(_palette(true), dark: true);

  void setMode(ThemeMode value) {
    if (value == _mode) return;
    _mode = value;
    notifyListeners();
  }

  /// 原生侧报告系统明暗变化（桌面端使用）。
  void setSystemDark(bool? value) {
    if (value == _systemDark) return;
    _systemDark = value;
    notifyListeners();
  }
}
