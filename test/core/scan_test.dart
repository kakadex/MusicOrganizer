import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart' hide Tags;
import 'package:musicorganizer/core/fs/file_store.dart';
import 'package:musicorganizer/core/fs/tree_ref.dart';
import 'package:musicorganizer/core/model/cancel_token.dart';
import 'package:musicorganizer/core/model/tags.dart';
import 'package:musicorganizer/core/model/vfile.dart';
import 'package:musicorganizer/core/scan/scan_stats.dart';
import 'package:musicorganizer/core/scan/scanner.dart';
import 'package:musicorganizer/core/tag/id3.dart';

/// 内存文件系统：只为测遍历与读取路径，不碰磁盘。
class MemoryFileStore implements FileStore {
  final Map<String, List<VFile>> kids = <String, List<VFile>>{};
  final Map<String, Uint8List> bytes = <String, Uint8List>{};

  /// 每次列目录都算一次 IO，用来验证缓存是否真的命中。
  int headCalls = 0;

  void put(VFile parent, List<VFile> children) {
    kids[parent.docId] = children;
  }

  @override
  Future<String> authState(String treeUri) async => 'VALID';

  @override
  Future<List<TreeRef>> roots() async => <TreeRef>[];

  @override
  Future<TreeRef?> pickTree() async => null;

  @override
  Future<void> releaseTree(TreeRef t) async {}

  @override
  Future<VFile?> stat(String id) async => null;

  @override
  Future<List<VFile>> children(VFile dir) async =>
      List<VFile>.of(kids[dir.docId] ?? <VFile>[]);

  @override
  Uri documentUri(String id) => Uri.parse('memory://$id');

  @override
  Future<Uint8List> headBytes(VFile f, int maxBytes) async {
    headCalls++;
    final Uint8List all = bytes[f.docId] ?? Uint8List(0);
    if (all.length <= maxBytes) return all;
    return Uint8List.sublistView(all, 0, maxBytes);
  }

  @override
  Future<Uint8List> tailBytes(VFile f, int maxBytes) async => Uint8List(0);

  @override
  Future<void> copyToLocal(VFile f, File cacheTarget) async {}

  @override
  Future<void> writeFromLocal(VFile f, File cacheSource) async {}

  @override
  Future<VFile> createFile(VFile parent, String name, String mime) async => parent;

  @override
  Future<VFile> createDir(VFile parent, String name) async => parent;

  @override
  Future<bool> delete(VFile f) async => false;

  @override
  Future<bool> rename(VFile f, String newName) async => false;

  @override
  Future<String?> move(VFile f, VFile targetDir) async => null;
}

/// 取消令牌：测试里手动置位。
class FlagToken implements CancelToken {
  bool cancelled = false;

  @override
  bool isCancelled() => cancelled;

  @override
  bool isCancelledNow() => cancelled;
}

VFile dir(String id, String name) =>
    VFile(docId: id, name: name, dir: true);

VFile file(String id, String name, {int size = 0, int mtime = 0}) => VFile(
      docId: id,
      parentId: id.substring(0, id.lastIndexOf('/')),
      name: name,
      size: size,
      lastModified: mtime,
    );

void main() {
  group('walkMusic', () {
    test('递归收集音频与歌词，跳过隐藏项与非音乐文件', () async {
      final MemoryFileStore st = MemoryFileStore();
      final VFile root = dir('r', 'r');
      st.put(root, <VFile>[
        file('r/a.mp3', 'a.mp3'),
        file('r/notes.txt', 'notes.txt'),
        file('r/.hidden.mp3', '.hidden.mp3'),
        dir('r/sub', 'sub'),
        dir('r/.hiddendir', '.hiddendir'),
      ]);
      st.put(dir('r/sub', 'sub'), <VFile>[
        file('r/sub/b.flac', 'b.flac'),
        file('r/sub/c.lrc', 'c.lrc'),
      ]);

      final WalkResult r = await Scanner.walkMusic(st, root);
      expect(r.files.map((VFile f) => f.name).toList(),
          <String>['a.mp3', 'b.flac', 'c.lrc']);
      expect(r.duplicates, 0);
    });

    test('provider 重复返回同一文档时只收一次并计数', () async {
      final MemoryFileStore st = MemoryFileStore();
      final VFile root = dir('r', 'r');
      // 同一个目录被列两次（有些 provider 会这样），整棵子树会被走两遍
      st.put(root, <VFile>[
        dir('r/sub', 'sub'),
        dir('r/sub', 'sub'),
        file('r/a.mp3', 'a.mp3'),
      ]);
      st.put(dir('r/sub', 'sub'), <VFile>[
        file('r/sub/b.mp3', 'b.mp3'),
        file('r/sub/b.mp3', 'b.mp3'),
      ]);

      final WalkResult r = await Scanner.walkMusic(st, root);
      expect(r.files.length, 2);
      expect(r.duplicates, 2);
    });

    test('非递归只收直属文件', () async {
      final MemoryFileStore st = MemoryFileStore();
      final VFile root = dir('r', 'r');
      st.put(root, <VFile>[file('r/a.mp3', 'a.mp3'), dir('r/sub', 'sub')]);
      st.put(dir('r/sub', 'sub'), <VFile>[file('r/sub/b.mp3', 'b.mp3')]);

      final WalkResult r =
          await Scanner.walkMusic(st, root, recursive: false);
      expect(r.files.map((VFile f) => f.name).toList(), <String>['a.mp3']);
    });

    test('取消后不再继续遍历', () async {
      final MemoryFileStore st = MemoryFileStore();
      final VFile root = dir('r', 'r');
      st.put(root, <VFile>[file('r/a.mp3', 'a.mp3'), file('r/b.mp3', 'b.mp3')]);
      final FlagToken token = FlagToken()..cancelled = true;

      final WalkResult r = await Scanner.walkMusic(st, root, cancel: token);
      expect(r.files, isEmpty);
    });
  });

  group('scanMusicFiles / walkAll', () {
    test('结果按目录再按文件名排序', () async {
      final MemoryFileStore st = MemoryFileStore();
      final VFile root = dir('r', 'r');
      st.put(root, <VFile>[
        dir('r/b', 'b'),
        dir('r/a', 'a'),
        file('r/z.mp3', 'z.mp3'),
      ]);
      st.put(dir('r/a', 'a'), <VFile>[
        file('r/a/02.mp3', '02.mp3'),
        file('r/a/01.mp3', '01.mp3'),
      ]);
      st.put(dir('r/b', 'b'), <VFile>[file('r/b/03.mp3', '03.mp3')]);

      final WalkResult r = await Scanner.scanMusicFiles(st, root);
      // 先按父 docId 再按文件名：根目录下的 z.mp3 的父是 'r'，排在 'r/a' 之前
      expect(r.files.map((VFile f) => f.docId).toList(),
          <String>['r/z.mp3', 'r/a/01.mp3', 'r/a/02.mp3', 'r/b/03.mp3']);
    });

    test('walkAll 收全部文件（含非音乐），但不收目录与隐藏项', () async {
      final MemoryFileStore st = MemoryFileStore();
      final VFile root = dir('r', 'r');
      st.put(root, <VFile>[
        file('r/a.mp3', 'a.mp3'),
        file('r/Thumbs.db', 'Thumbs.db'),
        file('r/.x', '.x'),
        dir('r/sub', 'sub'),
      ]);
      st.put(dir('r/sub', 'sub'), <VFile>[file('r/sub/old.lrc.bak', 'old.lrc.bak')]);

      final List<VFile> all = await Scanner.walkAll(st, root);
      expect(all.map((VFile f) => f.name).toList(),
          <String>['a.mp3', 'Thumbs.db', 'old.lrc.bak']);
    });

    test('统计：音频 / 歌词 / 文件总数', () async {
      final MemoryFileStore st = MemoryFileStore();
      final VFile root = dir('r', 'r');
      st.put(root, <VFile>[
        file('r/a.mp3', 'a.mp3'),
        file('r/b.flac', 'b.flac'),
        file('r/c.lrc', 'c.lrc'),
        file('r/d.txt', 'd.txt'),
      ]);
      final List<VFile> all = await Scanner.walkAll(st, root);
      final ScanStats s = Scanner.statsOf(all);
      expect(s.audio, 2);
      expect(s.lyrics, 1);
      expect(s.files, 4);
      expect(s.summary().contains('曲目 2 首'), isTrue);
    });
  });

  group('读取与缓存', () {
    Uint8List mkMp3(Tags t) {
      Uint8List data = Uint8List.fromList(List<int>.filled(1024, 0xFF));
      data = Id3.rewrite(data, t.toMap());
      return data;
    }

    test('readHead 一次读出标签与封面', () async {
      final MemoryFileStore st = MemoryFileStore();
      final VFile f = file('r/a.mp3', 'a.mp3', size: 4096);
      st.bytes[f.docId] = mkMp3(Tags()
        ..put('title', '测试标题')
        ..put('artist', '测试艺人'));

      final ScannerHead head = await Scanner.readHead(st, f);
      expect(head.ok, isTrue);
      expect(head.tags.get('title'), '测试标题');
      expect(head.tags.get('artist'), '测试艺人');
      expect(head.cover, isNull);
    });

    test('读标签走缓存：第二次不再访问 IO', () async {
      final MemoryFileStore st = MemoryFileStore();
      final VFile f = file('r/a.mp3', 'a.mp3', size: 1024, mtime: 7);
      st.bytes[f.docId] = mkMp3(Tags()..put('title', '第一次'));

      final Tags t1 = await Scanner.readTags(st, f);
      expect(t1.get('title'), '第一次');
      final int after1 = st.headCalls;
      final Tags t2 = await Scanner.readTags(st, f);
      expect(t2.get('title'), '第一次');
      expect(st.headCalls, after1);
    });

    test('invalidate 之后再读会回源', () async {
      final MemoryFileStore st = MemoryFileStore();
      final VFile f = file('r/a.mp3', 'a.mp3', size: 1024, mtime: 7);
      st.bytes[f.docId] = mkMp3(Tags()..put('title', '写入前'));

      await Scanner.readTags(st, f);
      st.bytes[f.docId] = mkMp3(Tags()..put('title', '写入后'));
      Scanner.invalidate(f);
      final Tags t = await Scanner.readTags(st, f);
      expect(t.get('title'), '写入后');
    });

    test('无封面格式（非音频）直接判无，不碰 IO', () async {
      final MemoryFileStore st = MemoryFileStore();
      // WMA 虽不可写但可读封面，这里用非音频扩展名验证「完全不碰 IO」的快速路径
      final VFile txt = file('r/a.txt', 'a.txt', size: 1024);
      st.bytes[txt.docId] = Uint8List.fromList(List<int>.filled(64, 0x30));
      expect(await Scanner.hasCover(st, txt), isFalse);
      expect(await Scanner.readCover(st, txt), isNull);
      expect(st.headCalls, 0);
    });
  });
}
