import 'package:flutter/services.dart';

import '../app/theme/palette.dart';

/// 「跟随系统」是否连颜色（壁纸取色）一起跟随。
///
/// true = Android 12+ 用系统动态色，桌面 / 低版本回退固定中性色板；
/// false = 只跟随明暗，颜色固定。界面与迁移逻辑不受影响，只改这一个常量。
const bool kFollowSystemColors = true;

/// 读取 Android 12+ 的系统动态色（零新增 pub 依赖）。
///
/// 原生侧实现在 `android/.../SystemColorsPlugin.kt`，读 `system_accent*` /
/// `system_neutral*` 资源；其它平台没有这个通道，[fetch] 返回 null，调用方
/// 回退到固定色板（Windows 就是这样，属预期行为，不是失败）。
abstract final class SystemColors {
  static const MethodChannel _ch =
      MethodChannel('com.dsh.musicorganizer/system_colors');

  /// 返回 null 表示「本平台 / 本版本不支持动态色」。
  static Future<SystemPaletteSet?> fetch() async {
    if (!kFollowSystemColors) return null;
    try {
      final Map<dynamic, dynamic>? raw =
          await _ch.invokeMapMethod<dynamic, dynamic>('getPalette');
      if (raw == null || raw.isEmpty) return null;
      final Map<String, int> colors = <String, int>{
        for (final MapEntry<dynamic, dynamic> e in raw.entries)
          if (e.value is int) e.key.toString(): e.value as int,
      };
      if (colors.isEmpty) return null;
      return SystemPaletteSet(
        light: MoPalette.fromSystem(colors, dark: false),
        dark: MoPalette.fromSystem(colors, dark: true),
      );
    } on MissingPluginException {
      // 桌面端没有实现这个通道：正常路径，不是错误。
      return null;
    } on PlatformException {
      // 取色失败不许挡启动。
      return null;
    }
  }
}
