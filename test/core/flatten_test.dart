import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/cleanup/cleaner.dart';
import 'package:musicorganizer/core/model/vfile.dart';

/// 扁平化计划：子目录里的音频 → 根目录，撞名不覆盖。
void main() {
  VFile audio(String docId, String name, String parent) => VFile(
        docId: docId,
        parentId: parent,
        name: name,
      );

  test('已在根目录的文件不进计划', () {
    final List<VFile> files = <VFile>[
      audio('root/a.mp3', 'a.mp3', 'root'),
      audio('root/x/b.mp3', 'b.mp3', 'root/x'),
    ];
    final List<FlattenPlan> plans = Flattener.plan(files, rootDocId: 'root');
    expect(plans.length, 1);
    expect(plans.first.source.name, 'b.mp3');
    expect(plans.first.fromDir, 'x');
  });

  test('撞名加 _2 后缀，不覆盖根目录已有文件', () {
    final List<VFile> files = <VFile>[
      audio('root/a.mp3', 'a.mp3', 'root'),
      audio('root/x/a.mp3', 'a.mp3', 'root/x'),
      audio('root/y/a.mp3', 'a.mp3', 'root/y'),
    ];
    final List<FlattenPlan> plans = Flattener.plan(files, rootDocId: 'root');
    expect(plans.map((FlattenPlan p) => p.targetName).toList(),
        <String>['a_2.mp3', 'a_3.mp3']);
  });

  test('非音频文件不搬', () {
    final List<VFile> files = <VFile>[
      audio('root/x/cover.jpg', 'cover.jpg', 'root/x'),
      audio('root/x/b.flac', 'b.flac', 'root/x'),
    ];
    final List<FlattenPlan> plans = Flattener.plan(files, rootDocId: 'root');
    expect(plans.length, 1);
    expect(plans.first.source.name, 'b.flac');
  });

  test('深层目录的相对路径去掉 SAF 卷前缀', () {
    final List<VFile> files = <VFile>[
      audio('primary:Music/A/B/c.mp3', 'c.mp3', 'primary:Music/A/B'),
    ];
    final List<FlattenPlan> plans =
        Flattener.plan(files, rootDocId: 'primary:Music');
    expect(plans.single.fromDir, 'A/B');
    expect(plans.single.renamed, isFalse);
  });
}
