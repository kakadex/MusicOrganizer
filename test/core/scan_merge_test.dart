import 'package:flutter_test/flutter_test.dart' hide Tags;
import 'package:musicorganizer/core/model/tags.dart';
import 'package:musicorganizer/core/model/vfile.dart';
import 'package:musicorganizer/core/scan/scan_merge.dart';

VFile audio(String id, int size, int mtime) =>
    VFile(docId: id, parentId: 'r', name: '$id.mp3', size: size, lastModified: mtime);

void main() {
  test('文件没变 → 沿用上次标签', () {
    final VFile old = audio('a', 100, 5);
    old.cacheMeta(Tags()..put('title', '旧标题'), cover: true, lyrics: true);
    final VFile now = audio('a', 100, 5);

    final ScanMergeResult r = ScanMerge.merge(<VFile>[old], <VFile>[now]);
    expect(r.reused, 1);
    expect(r.fresh, 0);
    expect(r.removed, 0);
    expect(now.cachedTags!.get('title'), '旧标题');
    expect(now.cachedHasCover, isTrue);
    expect(now.cachedHasLyrics, isTrue);
    expect(r.summary().contains('复用 1 首'), isTrue);
  });

  test('size 或 mtime 变了 → 当作新文件重读', () {
    final VFile old = audio('a', 100, 5);
    old.cacheMeta(Tags()..put('title', '旧标题'));

    final VFile sizeChanged = audio('a', 200, 5);
    expect(ScanMerge.merge(<VFile>[old], <VFile>[sizeChanged]).fresh, 1);
    expect(sizeChanged.metaCached(), isFalse);

    final VFile mtimeChanged = audio('a', 100, 9);
    expect(ScanMerge.merge(<VFile>[old], <VFile>[mtimeChanged]).fresh, 1);
  });

  test('上次没读过标签的不能复用', () {
    final VFile old = audio('a', 100, 5);
    final VFile now = audio('a', 100, 5);
    final ScanMergeResult r = ScanMerge.merge(<VFile>[old], <VFile>[now]);
    expect(r.reused, 0);
    expect(r.fresh, 1);
  });

  test('消失的文件计入 removed，新增计入 fresh', () {
    final VFile old1 = audio('a', 100, 5);
    old1.cacheMeta(Tags());
    final VFile old2 = audio('b', 100, 5);
    old2.cacheMeta(Tags());
    final VFile now = audio('c', 100, 5);

    final ScanMergeResult r =
        ScanMerge.merge(<VFile>[old1, old2], <VFile>[now]);
    expect(r.removed, 2);
    expect(r.fresh, 1);
    expect(r.summary().contains('移除 2 首'), isTrue);
  });

  test('本次列表里的重复 docId 只保留一条', () {
    final VFile a1 = audio('a', 100, 5);
    final VFile a2 = audio('a', 100, 5);
    final ScanMergeResult r = ScanMerge.merge(null, <VFile>[a1, a2]);
    expect(r.files.length, 1);
  });

  test('目录与歌词文件不参与标签复用统计', () {
    final VFile d = VFile(docId: 'r/sub', parentId: 'r', name: 'sub', dir: true);
    final VFile lrc = VFile(
        docId: 'r/a.lrc', parentId: 'r', name: 'a.lrc', size: 10, lastModified: 1);
    final ScanMergeResult r = ScanMerge.merge(<VFile>[], <VFile>[d, lrc]);
    expect(r.files.length, 2);
    expect(r.reused, 0);
    expect(r.fresh, 0);
  });

  test('两端都没数据时也能跑', () {
    expect(ScanMerge.merge(null, null).files, isEmpty);
    expect(ScanMerge.merge(<VFile>[], <VFile>[]).removed, 0);
  });
}
