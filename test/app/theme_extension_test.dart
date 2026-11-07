import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/app/theme/mo_colors.dart';
import 'package:musicorganizer/app/theme/mo_theme.dart';
import 'package:musicorganizer/app/theme/palette.dart';
import 'package:musicorganizer/app/ui_kit.dart';

void main() {
  testWidgets('MoKit 从主题扩取出同一套 token（9 个 feature 文件共用）',
      (WidgetTester tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      theme: MoTheme.build(MoPalette.dark, dark: true),
      home: Builder(builder: (BuildContext c) {
        ctx = c;
        return const SizedBox();
      }),
    ));
    expect(MoKit.ok(ctx), MoPalette.dark.ok);
    expect(MoKit.warn(ctx), MoPalette.dark.warn);
    expect(MoKit.err(ctx), MoPalette.dark.err);
    expect(MoKit.sub(ctx), MoPalette.dark.sub);
    expect(MoKit.faint(ctx), MoPalette.dark.faint);
    expect(MoKit.soft(ctx), MoPalette.dark.primarySoft);
    expect(MoKit.line(ctx), MoPalette.dark.line);
    expect(MoKit.card(ctx), MoPalette.dark.card);
    expect(MoKit.primaryOnSurface(ctx), MoPalette.dark.onSurfacePrimary);
  });

  testWidgets('裸 MaterialApp（没有 MoColors）不崩，按明暗回退固定色板',
      (WidgetTester tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: Builder(builder: (BuildContext c) {
        ctx = c;
        return const SizedBox();
      }),
    ));
    expect(MoKit.ok(ctx), MoPalette.dark.ok);
    expect(MoKit.text(ctx), MoPalette.dark.text);
  });

  test('ColorScheme 与色板逐槽一致，次级色不再跑绿', () {
    final ThemeData t = MoTheme.build(MoPalette.light, dark: false);
    final ColorScheme s = t.colorScheme;
    expect(s.primary, MoPalette.light.primary);
    expect(s.onPrimary, MoPalette.light.onPrimary);
    expect(s.secondary, MoPalette.light.accent);
    expect(s.secondaryContainer, MoPalette.light.primarySoft);
    expect(s.surface, MoPalette.light.card);
    expect(s.onSurface, MoPalette.light.text);
    expect(s.outline, MoPalette.light.line);
    expect(t.scaffoldBackgroundColor, MoPalette.light.bg);
    expect(t.snackBarTheme.actionTextColor, MoPalette.light.onSurfacePrimary);

    final double dh =
        (HSLColor.fromColor(s.secondary).hue - HSLColor.fromColor(s.primary).hue)
            .abs();
    expect(dh < 30 || dh > 330, isTrue, reason: '次级色应与主色同色系（差 $dh°）');
    expect(s.secondary, isNot(const Color(0xFF10B981)));
  });

  test('深色主题：brightness / 扩展 / 组件主题全部跟着走', () {
    final ThemeData t = MoTheme.build(MoPalette.dark, dark: true);
    expect(t.brightness, Brightness.dark);
    expect(t.extension<MoColors>()!.palette, MoPalette.dark);
    expect(t.dividerTheme.color, MoPalette.dark.line);
    expect(t.sliderTheme.inactiveTrackColor, MoPalette.dark.primarySoft);
    expect(t.appBarTheme.backgroundColor, MoPalette.dark.card);
    expect(t.navigationBarTheme.indicatorColor, MoPalette.dark.primarySoft);
  });
}
