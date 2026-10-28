/// 歌词候选列表（T-07）：多源命中时能自己挑一条。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/model/lyric_hit.dart';
import 'package:musicorganizer/feature/lyrics_batch/lyrics_candidate_sheet.dart';
import 'package:musicorganizer/feature/lyrics_batch/lyrics_logic.dart';

LyricChoice choice(
    {required String source,
    required double score,
    required String synced,
    String translation = ''}) {
  final LyricHit hit = LyricHit()
    ..source = source
    ..title = '晴天'
    ..artist = '周杰伦'
    ..synced = synced
    ..translation = translation;
  return LyricChoice(hit: hit, score: score);
}

void main() {
  test('brief 只给前几行 + 总数', () {
    expect(LyricPick.brief('[00:01]第一句\n[00:02]第二句\n[00:03]第三句'),
        '[00:01]第一句 / [00:02]第二句 …（共 3 行）');
    expect(LyricPick.brief('[00:01]唯一一句'), '[00:01]唯一一句');
    expect(LyricPick.brief('   '), '');
  });

  testWidgets('候选面板：换一条并确认，返回被选中的那条', (WidgetTester tester) async {
    final List<LyricChoice> candidates = <LyricChoice>[
      choice(source: 'netease', score: 0.92, synced: '[00:01]网易第一句\n[00:02]网易第二句'),
      choice(source: 'qqmusic', score: 0.88, synced: '[00:01]QQ第一句'),
      choice(source: 'kugou', score: 0.40, synced: '[00:01]酷狗第一句'),
    ];
    LyricChoice? picked;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (BuildContext ctx) => TextButton(
            onPressed: () async {
              picked = await LyricCandidateSheet.show(ctx, candidates);
            },
            child: const Text('打开'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    // 三条都列出来，带来源与置信度
    expect(find.text('共 3 条候选'), findsOneWidget);
    expect(find.text('网易云 · 带时间轴'), findsOneWidget);
    expect(find.text('QQ 音乐 · 带时间轴'), findsOneWidget);
    expect(find.text('92%'), findsOneWidget);
    // 低置信的要标出来，别让人误选
    expect(find.textContaining('低置信'), findsOneWidget);

    // 选第二条再确认
    await tester.tap(find.text('QQ 音乐 · 带时间轴'));
    await tester.pump();
    await tester.tap(find.text('用这条'));
    await tester.pumpAndSettle();

    expect(picked, isNotNull);
    expect(picked!.hit.source, 'qqmusic');
  });
}
