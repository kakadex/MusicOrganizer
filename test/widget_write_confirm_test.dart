import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/app/theme/mo_theme.dart';
import 'package:musicorganizer/app/theme/palette.dart';
import 'package:musicorganizer/core/tx/write_preview.dart';
import 'package:musicorganizer/feature/common/write_confirm_sheet.dart';

/// 写入确认面板的界面回归：
/// 1. 条目很多时，底部确认按钮必须仍然可见、可点（列表自己滚，按钮不跟着滚走）；
/// 2. 一项都没勾时按钮禁用并给出提示；
/// 3. 取消返回 null，确认返回勾中的那批。
void main() {
  List<WriteTarget> many(int n) => <WriteTarget>[
        for (int i = 0; i < n; i++)
          WriteTarget(
            docId: 'r/$i.mp3',
            name: '示例曲目 $i.mp3',
            path: '示例歌手',
            kind: WriteKind.tag,
            note: '示例来源',
            lines: <WriteLine>[
              WriteLine(
                label: '标题',
                oldText: '旧名 $i',
                newText: '新名 $i',
                key: 'title',
              ),
            ],
          ),
      ];

  Future<void> pumpHost(
    WidgetTester tester,
    List<WriteTarget> targets,
    void Function(List<WriteTarget>?) onResult,
  ) async {
    await tester.pumpWidget(MaterialApp(
      theme: MoTheme.build(MoPalette.of(MoThemeId.minimal, dark: false), dark: false),
      home: Scaffold(
        body: Builder(
          builder: (BuildContext ctx) => Center(
            child: TextButton(
              onPressed: () async {
                final List<WriteTarget>? r = await WriteConfirmSheet.show(
                  ctx,
                  title: '确认写入',
                  subtitle: '勾中的曲目会被写入',
                  targets: targets,
                  unit: '首',
                );
                onResult(r);
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  testWidgets('30 条时确认按钮仍在屏幕内可点', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    List<WriteTarget>? got;
    await pumpHost(tester, many(30), (List<WriteTarget>? r) => got = r);

    // 按钮在屏幕可视区域内（不是排在列表末尾、需要滚到底才看得到）
    final Finder commit = find.text('写入 30 首');
    expect(commit, findsOneWidget);
    final Rect box = tester.getRect(commit);
    expect(box.bottom, lessThanOrEqualTo(700),
        reason: '确认按钮不能被挤出屏幕');
    expect(box.top, greaterThan(0));

    await tester.tap(commit);
    await tester.pumpAndSettle();
    expect(got, isNotNull);
    expect(got!.length, 30);
  });

  testWidgets('全不选后按钮禁用并提示', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    List<WriteTarget>? got;
    await pumpHost(tester, many(3), (List<WriteTarget>? r) => got = r);

    await tester.tap(find.text('全不选'));
    await tester.pumpAndSettle();

    expect(find.textContaining('没有勾选任何变更'), findsOneWidget);
    // 点禁用按钮不应关闭面板
    await tester.tap(find.text('写入'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('确认写入'), findsOneWidget);
    expect(got, isNull);
  });

  testWidgets('取消返回 null', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    List<WriteTarget>? got;
    await pumpHost(tester, many(2), (List<WriteTarget>? r) => got = r);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(got, isNull);
  });
}
