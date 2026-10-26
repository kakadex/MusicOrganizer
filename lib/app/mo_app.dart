import 'package:flutter/material.dart';

import '../feature/crash/crash_screen.dart';
import 'shell.dart';
import 'theme/theme_controller.dart';

/// 应用根组件（Phase 0 骨架）：主题源 + 路由表。
class MoApp extends StatelessWidget {
  const MoApp({super.key, required this.themeController});

  /// 主题状态源（持久化接入后下沉到 Repo 设置槽位）。
  final ThemeController themeController;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: themeController,
      builder: (BuildContext context, Widget? child) {
        return MaterialApp(
          title: 'MusicOrganizer',
          debugShowCheckedModeBanner: false,
          navigatorKey: CrashScreen.navigatorKey,
          theme: themeController.themeData,
          home: const MoShell(),
        );
      },
    );
  }
}
