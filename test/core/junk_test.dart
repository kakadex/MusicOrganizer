import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/cleanup/junk.dart';
import 'package:musicorganizer/core/model/vfile.dart';

VFile entry(String name, {int size = 2048, bool dir = false}) => VFile(
      docId: 'r/$name',
      parentId: 'r',
      name: name,
      size: size,
      dir: dir,
    );

void main() {
  test('系统垃圾文件', () {
    for (final String name in <String>['Thumbs.db', 'desktop.ini', '.DS_Store']) {
      expect(Junk.kindOf(entry(name)), JunkKind.system, reason: name);
      expect(Junk.isJunk(entry(name)), isTrue);
      expect(Junk.reasonOf(entry(name)), '系统垃圾文件');
    }
  });

  test('歌词 / 标签备份', () {
    for (final String name in <String>[
      '示例歌名.lrc.bak',
      '示例歌名.lrc.bak.txt',
      '示例歌名.bak',
      '示例歌名.bak.txt',
    ]) {
      expect(Junk.kindOf(entry(name)), JunkKind.backup, reason: name);
    }
    expect(Junk.kindOf(entry('示例歌名.lrc')), isNull);
  });

  test('未完成的临时文件（含改名成音频的残留）', () {
    for (final String name in <String>[
      '示例歌名.mp3.part',
      '示例歌名.crdownload',
      '示例歌名.tmp',
      '示例歌名.tmp.mp3',
    ]) {
      expect(Junk.kindOf(entry(name)), JunkKind.temp, reason: name);
    }
  });

  test('0 字节与不足 1KB 的音频', () {
    expect(Junk.kindOf(entry('示例歌名.mp3', size: 0)), JunkKind.empty);
    expect(Junk.kindOf(entry('示例歌名.lrc', size: 0)), JunkKind.empty);
    expect(Junk.kindOf(entry('示例歌名.mp3', size: Junk.tinyAudioBytes - 1)),
        JunkKind.tiny);
    expect(Junk.kindOf(entry('示例歌名.mp3', size: Junk.tinyAudioBytes)), isNull);
    expect(Junk.kindOf(entry('示例歌名.lrc', size: 32)), isNull);
  });

  test('目录与正常文件不算垃圾', () {
    expect(Junk.isJunk(entry('示例目录', dir: true)), isFalse);
    expect(Junk.isJunk(entry('示例歌名.flac', size: 8 * 1024 * 1024)), isFalse);
    expect(Junk.reasonOf(entry('示例封面.jpg')), '');
  });

  test('plan 保持顺序，groupByKind 按类型归类', () {
    final List<VFile> files = <VFile>[
      entry('示例歌名.tmp'),
      entry('Thumbs.db', size: 1024),
      entry('示例歌名.lrc.bak', size: 512),
      entry('示例歌名.mp3', size: 4 * 1024 * 1024),
    ];
    final List<JunkItem> items = Junk.plan(files);
    expect(items.map((JunkItem it) => it.file.name).toList(),
        <String>['示例歌名.tmp', 'Thumbs.db', '示例歌名.lrc.bak']);

    final Map<JunkKind, List<JunkItem>> grouped = Junk.groupByKind(items);
    expect(grouped.keys.toList(),
        <JunkKind>[JunkKind.system, JunkKind.backup, JunkKind.temp]);
    expect(grouped[JunkKind.system]!.single.size, 1024);
    expect(Junk.totalSize(items), 2048 + 1024 + 512);
    expect(Junk.summary(items), '3 个文件 · 可释放 3.5 KB');
    expect(Junk.summary(<JunkItem>[]), '没有发现垃圾文件');
  });
}
