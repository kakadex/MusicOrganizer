import 'package:flutter/services.dart';

/// 桌面窗口外观通道（Windows runner 实现）。
///
/// 两件事，都在 0.3.17 加：
/// 1. **标题栏深浅跟随应用**：0.3.16 把窗口回退成系统原生标题栏后，标题栏颜色由
///    DWM 的 `DWMWA_USE_IMMERSIVE_DARK_MODE` 决定，而原生侧只读**系统**设置。
///    用户在 Windows 上选「深色」、系统却是浅色时，标题栏会是白的、内容区是黑的。
///    这里把应用解算出的明暗推给原生侧。
/// 2. **系统明暗变化通知**：原生侧收到 `WM_SETTINGCHANGE` 后把新的系统明暗推回
///    Dart，让「跟随系统」在 Windows 上也能即时切。
///
/// 非 Windows 平台没有实现，所有调用静默失败（返回 null / 不回调）。
abstract final class AppearanceBridge {
  static const MethodChannel _ch =
      MethodChannel('com.dsh.musicorganizer/appearance');

  /// 启动时问一次「系统现在是深色吗」；不支持时返回 null。
  static Future<bool?> systemDark() async {
    try {
      return await _ch.invokeMethod<bool>('isSystemDark');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// 设置标题栏深浅；`null` = 交回系统决定。
  static Future<void> setDarkTitleBar(bool? dark) async {
    try {
      await _ch.invokeMethod<void>('setDarkTitleBar', dark);
    } on MissingPluginException {
      // 安卓 / macOS：没有原生标题栏，忽略。
    } on PlatformException {
      // 改不动标题栏不该影响任何功能。
    }
  }

  /// 监听系统明暗变化（仅 Windows 会回调）。
  static void listenSystemTheme(void Function(bool dark) onChanged) {
    _ch.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'systemThemeChanged') {
        final Object? arg = call.arguments;
        if (arg is bool) onChanged(arg);
      }
      return null;
    });
  }
}
