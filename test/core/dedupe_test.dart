import 'package:flutter_test/flutter_test.dart';
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
}
