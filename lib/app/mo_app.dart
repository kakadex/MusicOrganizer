import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../feature/crash/crash_screen.dart';
import 'shell.dart';
import 'theme/font_scale.dart';
import 'theme/theme_controller.dart';

/// 应用根组件：主题源 + 路由表。
class MoApp extends StatelessWidget {
  const MoApp({super.key, required this.themeController});

  /// 外观状态源（三态 + 系统动态色，0.3.17）。
  final ThemeController themeController;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[themeController, FontScale.instance]),
      builder: (BuildContext context, Widget? child) {
        return MaterialApp(
          title: 'MusicOrganizer',
          debugShowCheckedModeBanner: false,
          navigatorKey: CrashScreen.navigatorKey,
          theme: themeController.lightTheme,
          darkTheme: themeController.darkTheme,
          // system / light / dark。「跟随系统」且桌面端已经知道系统明暗时，
          // controller 会解算成明确的 light / dark（见 ThemeController.effectiveMode）。
          themeMode: themeController.effectiveMode,
          // 字体缩放（0.3.9）：包在 home 外面，全应用文字统一按倍率放大。
          // 用 textScaler 而不是改每个字号常量——前者一处生效、能响应式刷新，
          // 后者要改几十处且容易漏。
          builder: (BuildContext ctx, Widget? content) {
            final MediaQueryData mq = MediaQuery.of(ctx);
            final bool dark = Theme.of(ctx).brightness == Brightness.dark;
            return MediaQuery(
              data: mq.copyWith(
                textScaler: TextScaler.linear(FontScale.instance.scale),
              ),
              // 状态栏 / 导航栏图标深浅（0.3.17）：深色界面里沿用系统默认的深色
              // 图标会看不清。只改图标与背景透明，不动布局（底边距仍由各页自己加）。
              child: AnnotatedRegion<SystemUiOverlayStyle>(
                value: SystemUiOverlayStyle(
                  statusBarColor: Colors.transparent,
                  statusBarIconBrightness:
                      dark ? Brightness.light : Brightness.dark,
                  statusBarBrightness:
                      dark ? Brightness.dark : Brightness.light,
                  systemNavigationBarIconBrightness:
                      dark ? Brightness.light : Brightness.dark,
                ),
                child: content ?? const SizedBox.shrink(),
              ),
            );
          },
          home: const MoShell(),
          // 路由兜底：外部「用本应用打开」音频时，系统会把文件 URI 当路由名
          // 推给 Flutter（didPushRouteInformation）。没设 onGenerateRoute 时
          // 框架走 onUnknownRoute 兜底，而它没人设置 → 空指针崩溃。
          // 应用是单页 shell，任何未知路由都回主页；文件本身走
          // onFileIntent 通道处理，不依赖路由。
          onGenerateRoute: (RouteSettings settings) => MaterialPageRoute<void>(
            builder: (BuildContext _) => const MoShell(),
          ),
        );
      },
    );
  }
}
