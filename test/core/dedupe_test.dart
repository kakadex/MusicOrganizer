import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/dedupe/content_sample.dart';
import 'package:musicorganizer/core/dedupe/duplicates.dart';
import 'package:musicorganizer/core/model/duplicate_group.dart';
import 'package:musicorganizer/core/model/vfile.dart';

/// 内存里的音频条目：docId 用 `/` 分隔，父目录由 docId 推出。
VFile song(String id, {int size = 0}) {
  final int slash = id.lastIndexOf('/');
  return VFile(
    docId: id,
    parentId: id.substring(0, slash),
    name: id.substring(slash + 1),
    size: size,
  );
}

/// 按 docId 返回时长，用于验证「时长复核」分支。
double Function(VFile) durations(Map<String, double> table) =>
    (VFile f) => table[f.docId] ?? 0;

void main() {
  test('「歌手-歌名」与「歌名」判同一首，读不到时长标疑似', () {
    final List<DuplicateGroup> groups = Duplicates.find(<VFile>[
      song('r/示例歌手-示例歌名.mp3', size: 5000),
      song('r/示例歌名.mp3', size: 4000),
    ]);
    expect(groups.length, 1);
    final DuplicateGroup g = groups.single;
    expect(g.files.length, 2);
    expect(g.score, 1.0);
    expect(g.suspect, isTrue);
    expect(g.wastedBytes(), 4000);
    expect(DuplicateGroup.recommendKeep(g), 0);
  });

  test('同名不同歌手不成组', () {
    final List<DuplicateGroup> groups = Duplicates.find(<VFile>[
      song('r/甲-示例歌名.mp3'),
      song('r/乙-示例歌名.mp3'),
    ]);
    expect(groups, isEmpty);
  });

  test('同名同大小是确证副本：时长差不影响结论', () {
    int calls = 0;
    final List<DuplicateGroup> groups = Duplicates.find(
      <VFile>[
        song('r/a/示例歌名.mp3', size: 1024),
        song('r/b/示例歌名.mp3', size: 1024),
      ],
      durationOf: (VFile f) {
        calls++;
        return 200;
      },
    );
    expect(groups.length, 1);
    expect(groups.single.score, 1.0);
    expect(groups.single.suspect, isFalse);
    // 判定阶段不做 IO，只有结果补齐时读了一次
    expect(calls, 2);
    expect(groups.single.files.every((DuplicateItem it) => it.duration == 200),
        isTrue);
  });

  test('名字证据强但时长差很多：列出并标疑似', () {
    final List<DuplicateGroup> groups = Duplicates.find(
      <VFile>[
        song('r/示例歌名.mp3'),
        song('r/示例歌名 (1).mp3'),
      ],
      durationOf: durations(<String, double>{
        'r/示例歌名.mp3': 200,
        'r/示例歌名 (1).mp3': 260,
      }),
    );
    expect(groups.length, 1);
    expect(groups.single.suspect, isTrue);
    expect(groups.single.files[0].duration, 200);
    expect(groups.single.files[1].duration, 260);
  });

  test('只靠包含度命中：读不到时长列疑似，时长差异明显则不成组', () {
    final List<VFile> pair = <VFile>[
      song('r/示例歌名.mp3'),
      song('r/示例歌名加长版.mp3'),
    ];
    final List<DuplicateGroup> unsure = Duplicates.find(pair);
    expect(unsure.length, 1);
    expect(unsure.single.suspect, isTrue);
    expect(unsure.single.score, lessThan(DuplicateGroup.highConfidence));

    final List<DuplicateGroup> rejected = Duplicates.find(
      pair,
      durationOf: durations(<String, double>{
        'r/示例歌名.mp3': 200,
        'r/示例歌名加长版.mp3': 400,
      }),
    );
    expect(rejected, isEmpty);
  });

  test('建议保留优先无复制痕迹的名字', () {
    final List<DuplicateGroup> groups = Duplicates.find(<VFile>[
      song('r/示例歌名 (1).mp3', size: 3000),
      song('r/示例歌名.mp3', size: 2000),
    ]);
    expect(groups.length, 1);
    expect(DuplicateGroup.recommendKeep(groups.single), 1);
    expect(groups.single.wastedBytes(), 3000);
  });

  test('只比音频：歌词与目录不参与', () {
    final List<DuplicateGroup> groups = Duplicates.find(<VFile>[
      song('r/示例歌名.mp3', size: 1024),
      song('r/示例歌名.lrc', size: 64),
      VFile(docId: 'r/示例歌名', name: '示例歌名', dir: true),
    ]);
    expect(groups, isEmpty);
  });

  test('结果先按组内文件数、再按可省空间排序', () {
    final List<DuplicateGroup> groups = Duplicates.find(<VFile>[
      song('r/a/示例歌名.mp3', size: 100),
      song('r/b/示例歌名.mp3', size: 100),
      song('r/c/示例歌名.mp3', size: 100),
      song('r/a/示例曲目.mp3', size: 900),
      song('r/b/示例曲目.mp3', size: 900),
    ]);
    expect(groups.length, 2);
    expect(groups[0].files.length, 3);
    expect(groups[1].files.length, 2);
  });

  test('同名但内嵌艺人不同：翻唱/重名不成组', () {
    final List<DuplicateGroup> groups = Duplicates.find(
      <VFile>[
        song('r/a/示例歌名.mp3', size: 3000),
        song('r/b/示例歌名.mp3', size: 3100),
      ],
      tagArtist: (VFile f) => f.docId.contains('/a/') ? '甲' : '乙',
    );
    expect(groups, isEmpty);
  });

  test('同名无艺人且读不到时长：标疑似而不是确证', () {
    final List<DuplicateGroup> groups = Duplicates.find(<VFile>[
      song('r/a/示例歌名.mp3'),
      song('r/b/示例歌名.mp3'),
      song('r/c/示例歌名.mp3'),
    ]);
    expect(groups.length, 1);
    expect(groups.single.suspect, isTrue);
  });

  test('「歌名-歌手」写法的两首不同歌：靠包含度也不成组', () {
    // 文件名是「歌名-歌手」写法时，艺人段会被解析成歌名、歌名段被解析成歌手，
    // 于是两首歌的「歌名」段变成同一个歌手名，短的那个还是长的那个的子串 ——
    // 只看包含度会把整片歌并成一组。两边艺人段明确不同 → 不成组。
    final List<DuplicateGroup> groups = Duplicates.find(<VFile>[
      song('r/一千个伤心的理由-示例歌手.mp3', size: 1000),
      song('r/你最珍贵-示例歌手嘉宾.mp3', size: 2000),
    ]);
    expect(groups, isEmpty);
  });

  test('内容核验：一致升为确证，不同标为「内容不同」', () async {
    final List<DuplicateGroup> same = Duplicates.find(<VFile>[
      song('r/a/示例歌名.mp3', size: 1024),
      song('r/b/示例歌名.mp3', size: 1024),
    ]);
    // 造一个「名字像但读不到时长」的组，才能进内容核验
    same[0].suspect = true;
    await Duplicates.verifyContent(same, (VFile f) async {
      return ContentSample(1024, Uint8List.fromList(<int>[1, 2, 3]),
          Uint8List.fromList(<int>[4, 5, 6]));
    });
    expect(same.single.content, DuplicateGroup.contentSame);
    expect(same.single.suspect, isFalse);

    final List<DuplicateGroup> diff = Duplicates.find(<VFile>[
      song('r/a/示例歌名.mp3', size: 1024),
      song('r/b/示例歌名.mp3', size: 1024),
    ]);
    diff[0].suspect = true;
    await Duplicates.verifyContent(diff, (VFile f) async {
      // 按 docId 造出不同内容
      return ContentSample(1024, Uint8List.fromList(<int>[f.docId.codeUnitAt(2)]),
          Uint8List.fromList(<int>[4, 5, 6]));
    });
    expect(diff.single.content, DuplicateGroup.contentDiff);
    expect(diff.single.suspect, isTrue);
  });

  group('默认勾选：每组挑出最该删的那一份', () {
    DuplicateItem item(String id,
        {int size = 1000, int durationMs = 0, int bitrateKbps = 0}) {
      final VFile f = song(id, size: size);
      f.cacheMeta(null, durationMs: durationMs, bitrateKbps: bitrateKbps);
      return DuplicateItem(f, f.docId, size, null);
    }

    test('时长最短的那份优先被挑中', () {
      final DuplicateGroup g = DuplicateGroup('k')
        ..files.addAll(<DuplicateItem>[
          item('r/a.mp3', size: 10000000, durationMs: 200000, bitrateKbps: 320),
          item('r/b.mp3', size: 8000000, durationMs: 190000, bitrateKbps: 256),
          item('r/c.mp3', size: 9000000, durationMs: 195000, bitrateKbps: 320),
        ]);
      expect(DuplicateGroup.recommendRemove(g), 1);
      expect(DuplicateGroup.recommendKeepBest(g), 0);
    });

    test('时长一样时看码率，码率一样时看体积', () {
      final DuplicateGroup sameDur = DuplicateGroup('k')
        ..files.addAll(<DuplicateItem>[
          item('r/a.mp3', size: 10000000, durationMs: 200000, bitrateKbps: 320),
          item('r/b.mp3', size: 9000000, durationMs: 200000, bitrateKbps: 128),
        ]);
      expect(DuplicateGroup.recommendRemove(sameDur), 1);

      final DuplicateGroup sameBr = DuplicateGroup('k')
        ..files.addAll(<DuplicateItem>[
          item('r/a.mp3', size: 10000000, durationMs: 200000, bitrateKbps: 320),
          item('r/b.mp3', size: 9000000, durationMs: 200000, bitrateKbps: 320),
        ]);
      expect(DuplicateGroup.recommendRemove(sameBr), 1);
    });

    test('读不到时长 / 码率时退回按体积挑', () {
      final DuplicateGroup g = DuplicateGroup('k')
        ..files.addAll(<DuplicateItem>[
          item('r/a.mp3', size: 10000000),
          item('r/b.mp3', size: 9000000),
        ]);
      expect(DuplicateGroup.recommendRemove(g), 1);
      expect(DuplicateGroup.recommendKeepBest(g), 0);
    });

    test('只有一份时没有「多出来的那份」', () {
      final DuplicateGroup g = DuplicateGroup('k')
        ..files.add(item('r/a.mp3', size: 1000));
      expect(DuplicateGroup.recommendRemove(g), -1);
      expect(DuplicateGroup.recommendKeepBest(g), -1);
    });
  });
}
