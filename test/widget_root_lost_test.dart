import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/app/repo.dart';
import 'package:musicorganizer/app/theme/mo_theme.dart';
import 'package:musicorganizer/app/theme/palette.dart';
import 'package:musicorganizer/feature/library/library_page.dart';

/// 目录丢失的界面回归：授权失效时要明确说「重新选一次就好」，
/// 而不是装作从没选过目录（用户会以为曲库被删了）。
void main() {
  testWidgets('授权失效显示专门提示', (WidgetTester tester) async {
    final Repo repo = Repo.instance;
    repo.resetForTest();
    repo.rootLost = true;

    await tester.pumpWidget(MaterialApp(
      theme: MoTheme.build(MoPalette.of(MoThemeId.minimal, dark: false), dark: false),
      home: const Scaffold(body: LibraryPage()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('上次的曲库目录授权已失效'), findsOneWidget);
    expect(find.text('重新选择目录'), findsOneWidget);
    expect(find.textContaining('没有被改动'), findsOneWidget);
  });

  testWidgets('从没选过目录时是普通引导', (WidgetTester tester) async {
    final Repo repo = Repo.instance;
    repo.resetForTest();

    await tester.pumpWidget(MaterialApp(
      theme: MoTheme.build(MoPalette.of(MoThemeId.minimal, dark: false), dark: false),
      home: const Scaffold(body: LibraryPage()),
    ));
    await tester.pumpAndSettle();

    // 空状态标题与页头副标题都会写这一句，这里只要求出现
    expect(find.text('还没有选择曲库目录'), findsWidgets);
    expect(find.text('选择目录'), findsOneWidget);
  });
}
