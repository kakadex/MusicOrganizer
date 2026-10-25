import 'package:flutter/material.dart';

import 'app/mo_app.dart';
import 'app/repo.dart';
import 'app/theme/palette.dart';
import 'app/theme/theme_controller.dart';

/// 应用入口：初始化全局仓库 → 恢复主题 → 挂载 [MoApp]。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final Repo repo = Repo.instance;
  await repo.init();

  // 主题：上次选的方案与明暗（存在 SharedPreferences 里，repo 初始化时已读回）
  final int themeId = repo.settings.get<int>('theme_id', fallback: 1) ?? 1;
  final bool dark = repo.settings.get<bool>('theme_dark', fallback: false) ?? false;
  final ThemeController controller = ThemeController(
    themeId: MoThemeId.values[themeId.clamp(0, MoThemeId.values.length - 1)],
    dark: dark,
  );
  repo.themeController = controller;

  runApp(MoApp(themeController: controller));
}
