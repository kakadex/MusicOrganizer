/// 空文件夹清理（含「删了但没真删」的复查）。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart' hide Tags;
import 'package:musicorganizer/core/cleanup/empty_dirs.dart';
import 'package:musicorganizer/core/fs/desktop_file_store.dart';
import 'package:musicorganizer/core/model/vfile.dart';

/// 故意「返回成功但不真删」：模拟 SAF 上出现过的假成功。
class _LyingStore extends DesktopFileStore {
  @override
  Future<bool> delete(VFile f) async => true;
}

void main() {
  late Directory root;
  late DesktopFileStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mo_empty_');
    store = DesktopFileStore()..addRoot(root.path);
  });

  tearDown(() => root.delete(recursive: true));

  void mkdir(String rel) =>
      Directory('${root.path}/$rel').createSync(recursive: true);
  void mkfile(String rel) {
    final File f = File('${root.path}/$rel');
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(Uint8List.fromList(<int>[1, 2, 3]));
  }

  VFile rootFile() => VFile(docId: root.path, name: '', dir: true);

  test('只挑「子树里没有文件」的目录；「未识别」与根目录受保护', () async {
    mkdir('歌手A/专辑1'); // 空
    mkfile('歌手A/专辑2/song.mp3'); // 有文件
    mkdir('空壳/子空'); // 两级都空
    mkdir('未识别'); // 根下的占位目录，保留
    mkfile('有封面/cover.jpg'); // 只有图片，不是空

    final EmptyDirPlan plan = await EmptyDirs.plan(store, rootFile());
    final List<String> paths = plan.empty.map((EmptyDir e) => e.relPath).toList();

    expect(paths, contains('歌手A/专辑1'));
    expect(paths, contains('空壳'));
    expect(paths, contains('空壳/子空'));
    expect(paths, isNot(contains('未识别')));
    expect(paths, isNot(contains('歌手A/专辑2')));
    expect(paths, isNot(contains('有封面')), reason: '里面还有 cover.jpg，不能删');
    expect(plan.protectedDirs.single, '未识别');
    // 深的先删
    expect(paths.indexOf('空壳/子空') < paths.indexOf('空壳'), isTrue);
  });

  test('删除后逐个复查：真删掉的才计数，目录与受保护目录保留', () async {
    mkdir('歌手A/专辑1');
    mkdir('空壳/子空');
    mkfile('歌手A/专辑2/song.mp3');
    mkdir('未识别');

    final EmptyDirPlan plan = await EmptyDirs.plan(store, rootFile());
    final EmptyDeleteResult r = await EmptyDirs.delete(store, plan.empty);

    expect(r.removed, 3);
    expect(r.failed, 0);
    expect(Directory('${root.path}/歌手A/专辑1').existsSync(), isFalse);
    expect(Directory('${root.path}/空壳').existsSync(), isFalse);
    expect(Directory('${root.path}/未识别').existsSync(), isTrue);
    expect(Directory('${root.path}/歌手A/专辑2').existsSync(), isTrue);
  });

  test('系统谎报成功（返回 true 但没删）→ 计为失败，不谎报已清理', () async {
    mkdir('空目录');
    final _LyingStore lying = _LyingStore()..addRoot(root.path);
    final EmptyDirPlan plan = await EmptyDirs.plan(lying, rootFile());
    expect(plan.count, 1);

    final EmptyDeleteResult r = await EmptyDirs.delete(lying, plan.empty);
    expect(r.removed, 0);
    expect(r.failed, 1);
    expect(r.summary(), contains('没删掉'));
    expect(Directory('${root.path}/空目录').existsSync(), isTrue);
  });

  test('扫描到删除之间又进了文件 → 跳过不删', () async {
    mkdir('待删');
    final EmptyDirPlan plan = await EmptyDirs.plan(store, rootFile());
    // 用户在这期间把文件搬回这个目录
    mkfile('待删/new.mp3');

    final EmptyDeleteResult r = await EmptyDirs.delete(store, plan.empty);
    expect(r.removed, 0);
    expect(r.skipped, 1);
    expect(Directory('${root.path}/待删').existsSync(), isTrue);
  });
}
