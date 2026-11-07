import 'package:flutter/material.dart';

import '../feature/crash/crash_screen.dart';
import 'shell.dart';
import 'theme/font_scale.dart';
import 'theme/theme_controller.dart';

/// 应用根组件（Phase 0 骨架）：主题源 + 路由表。
class MoApp extends StatelessWidget {
  const MoApp({super.key, required this.themeController});

  /// 主题状态源（持久化接入后下沉到 Repo 设置槽位）。
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
          theme: themeController.themeData,
          // 字体缩放（0.3.9）：包在 home 外面，全应用文字统一按倍率放大。
          // 用 textScaler 而不是改每个字号常量——前者一处生效、能响应式刷新，
          // 后者要改几十处且容易漏。
          builder: (BuildContext ctx, Widget? content) {
            final MediaQueryData mq = MediaQuery.of(ctx);
            return MediaQuery(
              data: mq.copyWith(
                textScaler: TextScaler.linear(FontScale.instance.scale),
              ),
              child: content ?? const SizedBox.shrink(),
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
