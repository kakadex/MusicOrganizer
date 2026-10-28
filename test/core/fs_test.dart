import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/fs/desktop_file_store.dart';
import 'package:musicorganizer/core/fs/file_store.dart';
import 'package:musicorganizer/core/fs/tree_lookup.dart';
import 'package:musicorganizer/core/fs/tree_ref.dart';
import 'package:musicorganizer/core/model/vfile.dart';

void main() {
  group('TreeLookup', () {
    test('按 docId 前缀分派（最长匹配）', () {
      final TreeLookup lookup = TreeLookup();
      lookup.add(const TreeRef(treeUri: 't1', rootDocId: 'primary:Music'));
      lookup.add(const TreeRef(treeUri: 't2', rootDocId: 'primary:Music/子目录'));
      expect(lookup.treeFor('primary:Music/a.mp3')!.treeUri, 't1');
      expect(lookup.treeFor('primary:Music/子目录/b.mp3')!.treeUri, 't2');
      expect(lookup.treeFor('primary:Music'), isNotNull);
      expect(lookup.treeFor('other:x'), isNull);
      lookup.remove('t2');
      expect(lookup.treeFor('primary:Music/子目录/b.mp3')!.treeUri, 't1');
    });
  });

  group('DesktopFileStore', () {
    late Directory dir;
    late DesktopFileStore store;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('mo_fs_');
      store = DesktopFileStore();
      // 白名单测试：先登记根目录，后续操作才允许
      store.addRoot(dir.path);
    });

    tearDown(() => dir.delete(recursive: true));

    test('stat / children / head / tail', () async {
      final File f = File('${dir.path}/a.mp3');
      await f.writeAsBytes(<int>[1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);

      final VFile? v = await store.stat(f.path);
      expect(v, isNotNull);
      expect(v!.name, 'a.mp3');
      expect(v.size, 10);
      expect(v.dir, isFalse);

      final VFile root = VFile(docId: dir.path, name: 'x', dir: true);
      final List<VFile> kids = await store.children(root);
      expect(kids.length, 1);
      expect(kids[0].name, 'a.mp3');

      expect(await store.headBytes(v, 4), <int>[1, 2, 3, 4]);
      expect(await store.tailBytes(v, 3), <int>[8, 9, 10]);
    });

    test('copy / write', () async {
      final File f = File('${dir.path}/a.mp3');
      await f.writeAsBytes(<int>[1, 2, 3]);
      final VFile v = (await store.stat(f.path))!;

      final File copy = File('${dir.path}/copy.mp3');
      await store.copyToLocal(v, copy);
      expect(await copy.readAsBytes(), <int>[1, 2, 3]);

      final File src = File('${dir.path}/src.mp3');
      await src.writeAsBytes(<int>[9, 9, 9]);
      await store.writeFromLocal(v, src);
      expect(await f.readAsBytes(), <int>[9, 9, 9]);
    });

    test('createFile / createDir / rename / delete', () async {
      final VFile root = VFile(docId: dir.path, name: 'x', dir: true);
      final VFile d = await store.createDir(root, 'sub');
      expect(d.dir, isTrue);

      final VFile f = await store.createFile(d, 'b.txt', 'text/plain');
      expect(f.name, 'b.txt');
      expect(await File(f.docId).exists(), isTrue);

      expect(await store.rename(f, 'c.txt'), isTrue);
      expect(await File('${d.docId}/c.txt').exists(), isTrue);

      final VFile renamed = (await store.stat('${d.docId}/c.txt'))!;
      expect(await store.delete(renamed), isTrue);
      expect(await File(renamed.docId).exists(), isFalse);
    });

    test('move 同卷（rename）', () async {
      final VFile root = VFile(docId: dir.path, name: 'x', dir: true);
      final VFile d = await store.createDir(root, 'sub');
      final File src = File('${dir.path}/a.mp3');
      await src.writeAsBytes(<int>[1, 2, 3]);
      final VFile v = (await store.stat(src.path))!;

      expect(await store.move(v, d), isNull);
      expect(await File('${d.docId}/a.mp3').exists(), isTrue);
      expect(await src.exists(), isFalse);
    });

    test('stat 不存在 → null', () async {
      expect(await store.stat('${dir.path}/nope.mp3'), isNull);
    });

    group('路径白名单', () {
      test('拒绝 .. 越界与根目录外的绝对路径', () async {
        final VFile outside = VFile(
            docId: '${dir.path}/../evil.mp3',
            name: 'evil.mp3',
            size: 1,
            lastModified: 1);
        await expectLater(
            store.stat(outside.docId), throwsA(isA<FileStoreException>()));
        await expectLater(
            store.headBytes(outside, 4), throwsA(isA<FileStoreException>()));
        await expectLater(
            store.delete(outside), throwsA(isA<FileStoreException>()));
      });

      test('前缀碰撞不被误判为子路径', () async {
        await expectLater(store.stat('${dir.path}2/a.mp3'),
            throwsA(isA<FileStoreException>()));
      });

      test('创建 / 改名拒绝带分隔符或 .. 的名字', () async {
        final VFile root = VFile(docId: dir.path, name: 'x', dir: true);
        await expectLater(store.createFile(root, '../evil.mp3', 'audio/mpeg'),
            throwsA(isA<FileStoreException>()));
        await expectLater(store.createDir(root, 'a/b'),
            throwsA(isA<FileStoreException>()));
      });
    });
  });
}
