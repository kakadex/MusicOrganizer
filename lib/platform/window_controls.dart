/// 桌面窗口控制（0.4.0 第三期：自绘标题栏）。
///
/// 为什么需要：自绘标题栏去掉了系统标题栏（省出一行空间），代价是
/// 拖动窗口 / 最小化 / 最大化 / 关闭这些系统行为都要自己实现。
/// 原生侧（`windows/runner/win32_window.cpp`）实现，这里只做通道封装。
///
/// 手机端没有窗口概念：所有方法在非 Windows 平台是安全空操作。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Windows 窗口控制通道。
const MethodChannel kWindowChannel =
    MethodChannel('com.dsh.musicorganizer/window');

/// 是否支持窗口控制（只有 Windows 桌面有）。
bool get windowControlsSupported => !kIsWeb && Platform.isWindows;

/// 桌面窗口操作（全部安全空操作：失败不抛异常，避免影响界面）。
abstract final class WindowControls {
  /// 开始拖动窗口（按下标题栏空白处时调用）。
  ///
  /// 原生侧转成 `WM_NCLBUTTONDOWN + HTCAPTION`，让系统接管拖动——
  /// 比自己算鼠标位移可靠得多（含贴边吸附、跨屏 DPI 变化）。
  static Future<void> startDrag() async {
    if (!windowControlsSupported) return;
    try {
      await kWindowChannel.invokeMethod<void>('startDrag');
    } on Exception {
      // 拖动失败不影响使用
    }
  }

  /// 最小化。
  static Future<void> minimize() async {
    if (!windowControlsSupported) return;
    try {
      await kWindowChannel.invokeMethod<void>('minimize');
    } on Exception {
      // 窗口控制失败不影响使用（例如通道未注册）
    }
  }

  /// 最大化 / 还原 切换。
  static Future<void> toggleMaximize() async {
    if (!windowControlsSupported) return;
    try {
      await kWindowChannel.invokeMethod<void>('toggleMaximize');
    } on Exception {
      // 窗口控制失败不影响使用（例如通道未注册）
    }
  }

  /// 关闭窗口（等同于点右上角 ×，会走正常退出流程）。
  static Future<void> close() async {
    if (!windowControlsSupported) return;
    try {
      await kWindowChannel.invokeMethod<void>('close');
    } on Exception {
      // 窗口控制失败不影响使用（例如通道未注册）
    }
  }

  /// 查询当前是否最大化。
  static Future<bool> isMaximized() async {
    if (!windowControlsSupported) return false;
    try {
      final bool? v = await kWindowChannel.invokeMethod<bool>('isMaximized');
      return v ?? false;
    } on Exception {
      return false;
    }
  }

  /// 订阅「最大化状态变化」（点按钮、双击标题栏、系统快捷键都会触发）。
  static void listenMaximized(void Function(bool maximized) onChange) {
    if (!windowControlsSupported) return;
    kWindowChannel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'maximizedChanged') {
        onChange(call.arguments == true);
      }
      return null;
    });
  }
}
