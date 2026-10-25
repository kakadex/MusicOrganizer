import 'package:flutter/material.dart';

import 'mo_theme.dart';
import 'palette.dart';

/// 主题状态（Phase 0：内存态）。
///
/// 持久化槽位已预留：主题 id / 夜间模式后续经 `Repo.settings` 落盘，
/// 启动时读回（T13 设置页接线时接入）。
class ThemeController extends ChangeNotifier {
  /// 创建主题控制器；默认「简紫 · 亮色」。
  ThemeController({MoThemeId themeId = MoThemeId.minimal, bool dark = false}) {
    _themeId = themeId;
    _dark = dark;
  }

  MoThemeId _themeId = MoThemeId.minimal;
  bool _dark = false;

  /// 当前主题方案。
  MoThemeId get themeId => _themeId;

  /// 是否夜间模式。
  bool get dark => _dark;

  /// 当前 [ThemeData]。
  ThemeData get themeData =>
      MoTheme.build(MoPalette.of(_themeId, dark: _dark), dark: _dark);

  /// 切换主题方案。
  void setTheme(MoThemeId id) {
    if (id == _themeId) return;
    _themeId = id;
    notifyListeners();
  }

  /// 切换明暗。
  void setDark(bool value) {
    if (value == _dark) return;
    _dark = value;
    notifyListeners();
  }

  /// 明暗翻转。
  void toggleDark() => setDark(!_dark);
}
