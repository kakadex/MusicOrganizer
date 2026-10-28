import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/app/theme/mo_theme.dart';
import 'package:musicorganizer/app/theme/palette.dart';
import 'package:musicorganizer/app/ui_kit.dart';

/// 轻提示：顶部、3 秒必收、不遮挡底部按钮。
void main() {
  Future<void> pumpHost(WidgetTester tester, {String? action}) {
    return tester.pumpWidget(MaterialApp(
      theme: MoTheme.build(MoPalette.of(MoThemeId.minimal, dark: false), dark: false),
      home: Scaffold(
        body: Stack(
          children: <Widget>[
            Align(
              alignment: Alignment.topLeft,
              child: Builder(
                builder: (BuildContext ctx) => TextButton(
                  onPressed: () => moSnack(ctx, '改动 1 首',
                      actionLabel: action, onAction: action == null ? null : () {}),
                  child: const Text('弹一条'),
                ),
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: TextButton(onPressed: () {}, child: const Text('底部按钮')),
            ),
          ],
        ),
      ),
    ));
  }

  testWidgets('普通提示 3 秒内消失', (WidgetTester tester) async {
    await pumpHost(tester);
    await tester.tap(find.text('弹一条'));
    await tester.pump();
    expect(find.text('改动 1 首'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3, milliseconds: 200));
    await tester.pumpAndSettle();
    expect(find.text('改动 1 首'), findsNothing);
  });

  testWidgets('带撤销按钮的提示 3 秒内也会消失', (WidgetTester tester) async {
    await pumpHost(tester, action: '撤销');
    await tester.tap(find.text('弹一条'));
    await tester.pump();
    expect(find.text('改动 1 首'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3, milliseconds: 200));
    await tester.pumpAndSettle();
    expect(find.text('改动 1 首'), findsNothing);
  });

  testWidgets('提示在顶部，不遮挡底部按钮', (WidgetTester tester) async {
    await pumpHost(tester, action: '撤销');
    await tester.tap(find.text('弹一条'));
    await tester.pump();

    final Rect toast = tester.getRect(find.text('改动 1 首'));
    final Rect bottom = tester.getRect(find.text('底部按钮'));
    // 整条提示都在底部按钮之上，且靠屏幕顶部
    expect(toast.bottom, lessThan(bottom.top));
    expect(toast.center.dy, lessThan(200));

    // 收尾：等到 3 秒到点，别把定时器留给下一个用例
    await tester.pump(const Duration(seconds: 3, milliseconds: 200));
    await tester.pumpAndSettle();
  });

  testWidgets('点一下就收', (WidgetTester tester) async {
    await pumpHost(tester);
    await tester.tap(find.text('弹一条'));
    await tester.pump();
    expect(find.text('改动 1 首'), findsOneWidget);

    await tester.tap(find.text('改动 1 首'));
    await tester.pumpAndSettle();
    expect(find.text('改动 1 首'), findsNothing);
  });
}
