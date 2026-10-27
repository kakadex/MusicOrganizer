import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/app/theme/mo_theme.dart';
import 'package:musicorganizer/app/theme/palette.dart';
import 'package:musicorganizer/app/ui_kit.dart';

/// 底部提示条：必须自己消失，不能一直挡着下面的按钮。
void main() {
  Future<void> pumpHost(WidgetTester tester, {String? action}) {
    return tester.pumpWidget(MaterialApp(
      theme: MoTheme.build(MoPalette.of(MoThemeId.minimal, dark: false), dark: false),
      home: Scaffold(
        body: Builder(
          builder: (BuildContext ctx) => TextButton(
            onPressed: () => moSnack(ctx, '改动 1 首',
                actionLabel: action, onAction: action == null ? null : () {}),
            child: const Text('弹一条'),
          ),
        ),
      ),
    ));
  }

  testWidgets('普通提示 4 秒内消失', (WidgetTester tester) async {
    await pumpHost(tester);
    await tester.tap(find.text('弹一条'));
    await tester.pump();
    expect(find.text('改动 1 首'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('改动 1 首'), findsNothing);
  });

  testWidgets('带撤销按钮的提示 7 秒内也会消失', (WidgetTester tester) async {
    await pumpHost(tester, action: '撤销');
    await tester.tap(find.text('弹一条'));
    await tester.pump();
    expect(find.text('改动 1 首'), findsOneWidget);

    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();
    expect(find.text('改动 1 首'), findsNothing);
  });
}
