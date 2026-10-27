import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/cleanup/cleaner.dart';
import 'package:musicorganizer/core/fs/file_store.dart';
import 'package:musicorganizer/core/fs/tree_ref.dart';
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

  group('execute 执行', () {
    // 内存版文件系统：模拟真实语义 —— docId 不存在就 move 失败，
    // 正是它复现了「改名后拿旧 docId 去 move 全部报失败」的原始 bug。
    test('改名过的文件也能搬进根目录', () async {
      final _FakeStore st = _FakeStore()
        ..dirs.add('root/A')
        ..files['root/old.mp3'] = 'root版'
        ..files['root/A/old.mp3'] = '子目录版';
      final List<VFile> all = <VFile>[
        VFile(docId: 'root/old.mp3', parentId: 'root', name: 'old.mp3'),
        VFile(docId: 'root/A/old.mp3', parentId: 'root/A', name: 'old.mp3'),
      ];
      final List<FlattenPlan> plans = Flattener.plan(all, rootDocId: 'root');
      expect(plans.single.renamed, isTrue); // 撞名 → targetName = old_2.mp3
      final FlattenResult r = await Flattener.execute(
        st,
        root: VFile(docId: 'root', name: 'root', dir: true),
        plans: plans,
      );
      expect(r.failed, 0, reason: r.errors.join('; '));
      expect(r.moved, 1);
      expect(st.files['root/old_2.mp3'], '子目录版');
      expect(st.files.containsKey('root/A/old_2.mp3'), isFalse);
      expect(r.removedDirs, 1); // root/A 搬空后删掉
      expect(st.dirs.contains('root/A'), isFalse);
    });

    test('中间层的空目录一并删除', () async {
      final _FakeStore st = _FakeStore()
        ..dirs.addAll(<String>['root/A', 'root/A/B'])
        ..files['root/A/B/song.mp3'] = 'x';
      final List<VFile> all = <VFile>[
        VFile(docId: 'root/A/B/song.mp3', parentId: 'root/A/B',
            name: 'song.mp3'),
      ];
      final List<FlattenPlan> plans = Flattener.plan(all, rootDocId: 'root');
      final FlattenResult r = await Flattener.execute(
        st,
        root: VFile(docId: 'root', name: 'root', dir: true),
        plans: plans,
      );
      expect(r.failed, 0, reason: r.errors.join('; '));
      expect(r.moved, 1);
      expect(st.files['root/song.mp3'], 'x');
      // B 和中间层 A 都删掉
      expect(r.removedDirs, 2);
      expect(st.dirs, isNot(contains('root/A')));
      expect(st.dirs, isNot(contains('root/A/B')));
    });
  });
}

/// 内存版 [FileStore]，只实现扁平化执行用到的行为。
class _FakeStore implements FileStore {
  final Map<String, String> files = <String, String>{};
  final Set<String> dirs = <String>{};

  static String _dirOf(String id) {
    final int slash = id.lastIndexOf('/');
    return slash <= 0 ? id : id.substring(0, slash);
  }

  static String _base(String id) {
    final int slash = id.lastIndexOf('/');
    return slash < 0 ? id : id.substring(slash + 1);
  }

  @override
  Future<List<TreeRef>> roots() async => <TreeRef>[];

  @override
  Future<TreeRef?> pickTree() async => null;

  @override
  Future<void> releaseTree(TreeRef t) async {}

  @override
  Future<VFile?> stat(String id) async => null;

  @override
  Future<List<VFile>> children(VFile dir) async {
    final List<VFile> out = <VFile>[];
    for (final String d in dirs) {
      if (_dirOf(d) == dir.docId) {
        out.add(VFile(docId: d, parentId: dir.docId, name: _base(d), dir: true));
      }
    }
    for (final String f in files.keys) {
      if (_dirOf(f) == dir.docId) {
        out.add(VFile(docId: f, parentId: dir.docId, name: _base(f)));
      }
    }
    return out;
  }

  @override
  Uri documentUri(String id) => Uri.file(id);

  @override
  Future<Uint8List> headBytes(VFile f, int maxBytes) async =>
      Uint8List(0);

  @override
  Future<Uint8List> tailBytes(VFile f, int maxBytes) async =>
      Uint8List(0);

  @override
  Future<void> copyToLocal(VFile f, File cacheTarget) async {}

  @override
  Future<void> writeFromLocal(VFile f, File cacheSource) async {}

  @override
  Future<VFile> createFile(VFile parent, String name, String mime) async =>
      VFile(docId: '${parent.docId}/$name', parentId: parent.docId, name: name);

  @override
  Future<VFile> createDir(VFile parent, String name) async {
    final String id = '${parent.docId}/$name';
    dirs.add(id);
    return VFile(docId: id, parentId: parent.docId, name: name, dir: true);
  }

  @override
  Future<bool> delete(VFile f) async {
    if (f.dir) return dirs.remove(f.docId);
    return files.remove(f.docId) != null;
  }

  @override
  Future<bool> rename(VFile f, String newName) async {
    if (!files.containsKey(f.docId)) return false;
    final String target = '${_dirOf(f.docId)}/$newName';
    if (files.containsKey(target)) return false;
    files[target] = files.remove(f.docId)!;
    return true;
  }

  @override
  Future<String?> move(VFile f, VFile targetDir) async {
    if (!files.containsKey(f.docId)) return '源文件不存在：${f.docId}';
    final String target = '${targetDir.docId}/${f.name}';
    if (files.containsKey(target)) return '目标已存在：${f.name}';
    files[target] = files.remove(f.docId)!;
    return null;
  }
}
