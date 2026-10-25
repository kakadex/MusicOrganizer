import 'package:flutter/material.dart';

import 'app/mo_app.dart';
import 'app/repo.dart';
import 'app/theme/theme_controller.dart';

/// 应用入口：初始化全局仓库 → 挂载 [MoApp]。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Repo.instance.init();
  runApp(MoApp(themeController: ThemeController()));
}
