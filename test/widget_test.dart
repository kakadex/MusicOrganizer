import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/app/placeholder_page.dart';
import 'package:musicorganizer/app/router.dart';
import 'package:musicorganizer/app/theme/theme_controller.dart';
import 'package:musicorganizer/core/version.dart';

void main() {
  testWidgets('占位页渲染，外观三态可切换，导航可往返', (WidgetTester tester) async {
    // 主界面（MoShell）依赖真实设备插件（SAF / SharedPreferences），
    // 这里测的是「外观 + 占位页导航」这层纯 UI，用占位页直接挂载。
    final ThemeController controller = ThemeController();
    await tester.pumpWidget(ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) => MaterialApp(
        theme: controller.lightTheme,
        darkTheme: controller.darkTheme,
        themeMode: controller.effectiveMode,
        home: MoPlaceholderPage(
          title: 'MusicOrganizer',
          themeController: controller,
          showNav: true,
        ),
        // 占位页点功能项会 push 命名路由，这里给个兜底生成器
        onGenerateRoute: (RouteSettings settings) => MaterialPageRoute<void>(
          builder: (BuildContext _) => MoPlaceholderPage(
            title: MoRouter.titles[settings.name] ?? 'MusicOrganizer',
            themeController: controller,
          ),
        ),
      ),
    ));

    expect(find.text('MusicOrganizer'), findsOneWidget);
    expect(find.textContaining('Phase 0 骨架占位'), findsOneWidget);
    expect(find.text('版本 $kAppVersionFull'), findsOneWidget);

    // 默认「跟随系统」；三档胶囊都在。
    expect(controller.mode, ThemeMode.system);
    expect(find.text('跟随系统'), findsOneWidget);
    expect(find.text('浅色'), findsOneWidget);
    expect(find.text('深色'), findsOneWidget);

    controller.setMode(ThemeMode.dark);
    await tester.pumpAndSettle();
    expect(controller.effectiveMode, ThemeMode.dark);
    expect(controller.darkTheme.brightness, Brightness.dark);
    expect(controller.lightTheme.brightness, Brightness.light);

    controller.setMode(ThemeMode.light);
    await tester.pumpAndSettle();
    expect(controller.effectiveMode, ThemeMode.light);
    expect(controller.effectiveDark, isFalse);

    // 导航到占位功能页并返回。
    await tester.tap(find.text('曲库浏览'));
    await tester.pumpAndSettle();
    expect(find.text('曲库浏览'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('MusicOrganizer'), findsOneWidget);
  });

  test('路由表与占位标题一一对应', () {
    for (final String route in <String>[
      MoRoutes.home,
      MoRoutes.library,
      MoRoutes.organize,
      MoRoutes.tagBatch,
      MoRoutes.lyricsBatch,
      MoRoutes.covers,
      MoRoutes.editor,
      MoRoutes.history,
      MoRoutes.health,
      MoRoutes.settings,
    ]) {
      expect(MoRouter.titles.containsKey(route), isTrue, reason: route);
    }
  });
}
