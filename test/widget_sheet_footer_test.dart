import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/app/theme/mo_theme.dart';
import 'package:musicorganizer/app/theme/palette.dart';
import 'package:musicorganizer/app/ui_kit.dart';
import 'package:musicorganizer/core/match/tag_fill.dart';
import 'package:musicorganizer/core/match/tag_plan.dart';
import 'package:musicorganizer/core/model/vfile.dart';
import 'package:musicorganizer/feature/library/preview_sheet.dart';

/// 框体底栏：内容再长，确认按钮也不能被顶出屏幕。
void main() {
  Future<void> pumpHost(
      WidgetTester tester, void Function(BuildContext) onOpen) {
    return tester.pumpWidget(MaterialApp(
      theme: MoTheme.build(MoPalette.of(MoThemeId.minimal, dark: false), dark: false),
      home: Scaffold(
        body: Builder(
          builder: (BuildContext ctx) => TextButton(
            onPressed: () => onOpen(ctx),
            child: const Text('打开'),
          ),
        ),
      ),
    ));
  }

  void smallScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2.0; // 逻辑 360 x 640
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('确认写入：203 首时底栏按钮仍在屏内', (WidgetTester tester) async {
    smallScreen(tester);
    final List<FilePlan> plans = <FilePlan>[
      for (int i = 0; i < 203; i++)
        FilePlan(
          file: VFile(
              docId: 'doc$i', name: 'song$i.mp3', size: 1024, lastModified: 1),
          fields: <PlanField>[
            PlanField(
              key: 'title',
              oldValue: '',
              newValue: '标题 $i',
              mode: TagFill.supplement,
            ),
          ],
        ),
    ];

    await pumpHost(tester, (BuildContext ctx) => PreviewSheet.show(ctx, plans));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    const double screenBottom = 640;
    final Finder commit = find.text('写入 203 首');
    expect(commit, findsOneWidget);
    expect(tester.getRect(commit).bottom, lessThanOrEqualTo(screenBottom));
    expect(tester.getRect(find.text('将写入 203 首')).bottom,
        lessThanOrEqualTo(screenBottom));

    // 列表确实从第一首开始排（后面的内容滚在列表里，不影响底栏）
    expect(find.text('song0.mp3'), findsOneWidget);
  });

  testWidgets('showMoSheet 的固定底栏不随长列表滚走', (WidgetTester tester) async {
    smallScreen(tester);
    await pumpHost(
      tester,
      (BuildContext ctx) => showMoSheet<void>(
        ctx,
        title: '长列表',
        children: <Widget>[
          for (int i = 0; i < 300; i++) Text('行 $i'),
        ],
        footer: const SizedBox(height: 40, child: Text('底栏按钮')),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    const double screenBottom = 640;
    expect(find.text('底栏按钮'), findsOneWidget);
    expect(tester.getRect(find.text('底栏按钮')).bottom,
        lessThanOrEqualTo(screenBottom));
    // 内容从第一行开始排（后面的滚在列表里，不影响底栏）
    expect(find.text('行 0'), findsOneWidget);
  });

  testWidgets('确认写入：点右侧箭头能展开字段', (WidgetTester tester) async {
    smallScreen(tester);
    final FilePlan plan = FilePlan(
      file: VFile(docId: 'doc1', name: 'song.mp3', size: 1, lastModified: 1),
      fields: <PlanField>[
        PlanField(
            key: 'title', oldValue: '', newValue: '新标题', mode: TagFill.supplement),
        PlanField(
            key: 'artist', oldValue: '', newValue: '新歌手', mode: TagFill.supplement),
        PlanField(
            key: 'album', oldValue: '', newValue: '新专辑', mode: TagFill.supplement),
        PlanField(
            key: 'year', oldValue: '', newValue: '2026', mode: TagFill.supplement),
      ],
    );

    await pumpHost(
        tester, (BuildContext ctx) => PreviewSheet.show(ctx, <FilePlan>[plan]));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    // 未展开时看不到字段行
    expect(find.text('标题'), findsNothing);
    // 点右侧箭头（箭头在整行点击区内）
    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pumpAndSettle();
    expect(find.text('标题'), findsOneWidget);
    expect(find.textContaining('新标题', findRichText: true), findsOneWidget);
    // 再点一次收起
    await tester.tap(find.byIcon(Icons.expand_less));
    await tester.pumpAndSettle();
    expect(find.text('标题'), findsNothing);
  });
}
