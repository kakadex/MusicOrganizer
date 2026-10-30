/// 设置页 / 整理二级页作为**独立路由**挂载时的回归。
///
/// 2026-10-30 界面改版踩到的坑：这两个页面原来只活在 shell 的 Scaffold 里，
/// 改成从音乐库齿轮 push 出来以后，页面自己不带 Scaffold，卡片里的 InkWell
/// 一被鼠标悬停就 `Material.of` 拿到 null 直接崩（Null check operator）。
/// 这里用真实的鼠标设备 hover 一遍，崩了会就地失败。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/app/repo.dart';
import 'package:musicorganizer/feature/organize/organize_page.dart';
import 'package:musicorganizer/feature/settings/about_page.dart';
import 'package:musicorganizer/feature/settings/license_page.dart';
import 'package:musicorganizer/feature/settings/settings_page.dart';

Future<void> _hover(WidgetTester tester, String text) async {
  final TestGesture gesture =
      await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  await tester.pump();
  await gesture.moveTo(tester.getCenter(find.text(text).first));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  await gesture.removePointer();
  await tester.pump();
}

void main() {
  testWidgets('设置页独立挂载：有 Scaffold，悬停「清理与查重」入口不崩',
      (WidgetTester tester) async {
    Repo.instance.resetForTest();
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(Scaffold), findsWidgets);
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('清理与查重'), findsOneWidget);

    await _hover(tester, '清理与查重');
    expect(tester.takeException(), isNull);
  });

  testWidgets('清理与查重二级页独立挂载：悬停各功能项不崩',
      (WidgetTester tester) async {
    Repo.instance.resetForTest();
    await tester.pumpWidget(const MaterialApp(
      home: OrganizePage(section: OrganizeSection.cleanup, embedded: true),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('清理与查重'), findsOneWidget);
    expect(find.text('文件名清理'), findsOneWidget);

    await _hover(tester, '文件名清理');
    await _hover(tester, '重复文件筛选');
    expect(tester.takeException(), isNull);
  });

  testWidgets('扫描与整理二级页独立挂载：只出扫描卡，不出现清理项',
      (WidgetTester tester) async {
    Repo.instance.resetForTest();
    await tester.pumpWidget(const MaterialApp(
      home: OrganizePage(section: OrganizeSection.organize, embedded: true),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('扫描与整理'), findsOneWidget);
    expect(find.text('自动整理'), findsOneWidget);
    expect(find.text('文件名清理'), findsNothing);
  });

  testWidgets('关于页独立挂载：静默更新不再写「每天最多一次」的说明',
      (WidgetTester tester) async {
    Repo.instance.resetForTest();
    await tester.pumpWidget(const MaterialApp(home: AboutPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('关于'), findsOneWidget);
    expect(find.text('检查更新'), findsOneWidget);
    expect(find.text('启动时静默检查更新'), findsOneWidget);
    // 对齐 LyricoX 关于页补齐的三项（开源许可 = 本项目自己的 MIT）
    expect(find.text('项目主页'), findsOneWidget);
    expect(find.text('问题反馈'), findsOneWidget);
    expect(find.text('隐私说明'), findsOneWidget);
    expect(find.text('开源许可'), findsOneWidget);
    // 说明文字与实际行为对不上，已删；留着这条断言防止又被加回去
    expect(find.textContaining('每天最多一次'), findsNothing);

    await _hover(tester, '检查更新');
    expect(tester.takeException(), isNull);
  });

  testWidgets('开源许可页：显示本项目自己的 MIT 全文', (WidgetTester tester) async {
    Repo.instance.resetForTest();
    await tester.pumpWidget(const MaterialApp(home: ProjectLicensePage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('开源许可'), findsOneWidget);
    expect(find.textContaining('MIT License'), findsWidgets);
    expect(find.textContaining('MIT 许可协议'), findsOneWidget);
    expect(find.textContaining('Copyright (c) 2026 kakadex'), findsOneWidget);
    expect(find.textContaining('版权所有 (c) 2026 kakadex'), findsOneWidget);
    // 译文仅供参考的法律提示
    expect(find.textContaining('以英文原文为准'), findsOneWidget);
    // 这是本项目自己的许可，不是第三方依赖清单
    expect(find.textContaining('Third-Party'), findsNothing);
  });
}
