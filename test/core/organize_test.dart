import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart' hide Tags;
import 'package:musicorganizer/core/fs/file_store.dart';
import 'package:musicorganizer/core/fs/tree_ref.dart';
import 'package:musicorganizer/core/model/cancel_token.dart';
import 'package:musicorganizer/core/model/tags.dart';
import 'package:musicorganizer/core/model/vfile.dart';
import 'package:musicorganizer/core/organize/organizer.dart';

/// 内存文件系统：建目录 / 移动都按真实语义记账，用来验证整理流程。
class MemStore implements FileStore {
  final Map<String, VFile> docs = <String, VFile>{};
  final Map<String, List<String>> kids = <String, List<String>>{};

  /// 新建目录次数（复用已有目录不应增加）。
  int createdDirs = 0;

  /// 打开后所有移动都失败，用来验证失败记账。
  bool failMove = false;

  VFile addDir(String parentId, String name) {
    final String id = '$parentId/$name';
    final VFile d =
        VFile(docId: id, parentId: parentId, name: name, dir: true);
    docs[id] = d;
    kids.putIfAbsent(parentId, () => <String>[]).add(id);
    return d;
  }

  VFile addFile(String parentId, String name, {int size = 2048, Tags? tags}) {
    final String id = '$parentId/$name';
    final VFile f = VFile(docId: id, parentId: parentId, name: name, size: size);
    if (tags != null) f.cacheMeta(tags);
    docs[id] = f;
    kids.putIfAbsent(parentId, () => <String>[]).add(id);
    return f;
  }

  @override
  Future<List<VFile>> children(VFile dir) async => <VFile>[
        for (final String id in kids[dir.docId] ?? <String>[])
          if (docs[id] != null) docs[id]!,
      ];

  @override
  Future<VFile> createDir(VFile parent, String name) async {
    final VFile? hit = docs['${parent.docId}/$name'];
    if (hit != null) return hit;
    createdDirs++;
    return addDir(parent.docId, name);
  }

  @override
  Future<String?> move(VFile f, VFile targetDir) async {
    if (failMove) return 'E_IO：模拟写盘失败';
    final String id = '${targetDir.docId}/${f.name}';
    if (docs.containsKey(id)) return '目标已存在同名文件';
    kids[f.parentId]?.remove(f.docId);
    docs.remove(f.docId);
    final VFile moved = f.copyWith(docId: id, parentId: targetDir.docId);
    docs[id] = moved;
    kids.putIfAbsent(targetDir.docId, () => <String>[]).add(id);
    return null;
  }

  @override
  Future<bool> delete(VFile f) async {
    kids[f.parentId]?.remove(f.docId);
    return docs.remove(f.docId) != null;
  }

  @override
  Future<bool> rename(VFile f, String newName) async => false;

  @override
  Future<VFile?> stat(String id) async => docs[id];

  @override
  @override
  Future<String> authState(String treeUri) async => 'VALID';

  @override
  Future<List<TreeRef>> roots() async => <TreeRef>[];

  @override
  Future<TreeRef?> pickTree() async => null;

  @override
  Future<void> releaseTree(TreeRef t) async {}

  @override
  Uri documentUri(String id) => Uri.parse('memory://$id');

  @override
  Future<Uint8List> headBytes(VFile f, int maxBytes) async => Uint8List(0);

  @override
  Future<Uint8List> tailBytes(VFile f, int maxBytes) async => Uint8List(0);

  @override
  Future<Uint8List> rangeBytes(VFile f, int offset, int maxBytes) async =>
      Uint8List(0);

  @override
  Future<void> copyToLocal(VFile f, File cacheTarget) async {}

  @override
  Future<void> writeFromLocal(VFile f, File cacheSource) async {}

  @override
  Future<VFile> createFile(VFile parent, String name, String mime) async =>
      addFile(parent.docId, name);
}

class FlagToken implements CancelToken {
  FlagToken(this.cancelled);

  bool cancelled;

  @override
  bool isCancelled() => cancelled;

  @override
  bool isCancelledNow() => cancelled;
}

Tags tagsOf({String artist = '', String album = ''}) {
  final Tags t = Tags();
  t.put('artist', artist);
  t.put('album', album);
  return t;
}

void main() {
  late MemStore store;

  setUp(() {
    store = MemStore()..addDir('root', 'in');
  });

  test('按歌手 / 专辑算目标目录', () {
    final VFile f = store.addFile('root/in', '示例歌手-示例歌名.mp3', tags: tagsOf(artist: '示例歌手', album: '示例专辑'));
    final List<MovePlan> plans = Organizer.plan(<VFile>[f], rootDocId: 'root');
    expect(plans.length, 1);
    expect(plans.single.targetPath, '示例歌手/示例专辑');
    expect(plans.single.reason, '按歌手 / 专辑归位');
    expect(plans.single.fromDir, 'root/in');
    expect(plans.single.conflict, isFalse);
  });

  test('byAlbum 关闭时只按歌手；占位专辑当没有', () {
    final VFile a = store.addFile('root/in', '示例歌手-示例歌名.mp3',
        tags: tagsOf(artist: '示例歌手', album: '示例专辑'));
    expect(Organizer.plan(<VFile>[a], rootDocId: 'root', byAlbum: false)
        .single
        .targetPath, '示例歌手');

    final VFile b = store.addFile('root/in', '示例歌手-示例曲目.mp3',
        tags: tagsOf(artist: '示例歌手', album: '未知专辑'));
    expect(Organizer.plan(<VFile>[b], rootDocId: 'root').single.targetPath,
        '示例歌手');
  });

  test('文件名推歌手；非法字符清洗成空格', () {
    final VFile a = store.addFile('root/in', '示例歌手-示例歌名.mp3');
    expect(Organizer.plan(<VFile>[a], rootDocId: 'root').single.targetPath,
        '示例歌手');

    final VFile b = store.addFile('root/in', '示例歌名.mp3',
        tags: tagsOf(artist: '示例/歌手'));
    expect(Organizer.plan(<VFile>[b], rootDocId: 'root').single.targetPath,
        '示例 歌手');
  });

  test('认不出歌手的文件不出计划，已在目标目录的默认跳过', () {
    final VFile plain = store.addFile('root/in', '示例歌名.mp3');
    expect(Organizer.plan(<VFile>[plain], rootDocId: 'root'), isEmpty);

    store.addDir('root', '示例歌手');
    store.addDir('root/示例歌手', '示例专辑');
    final VFile done = store.addFile('root/示例歌手/示例专辑', '示例歌手-示例歌名.mp3',
        tags: tagsOf(artist: '示例歌手', album: '示例专辑'));
    expect(Organizer.plan(<VFile>[done], rootDocId: 'root'), isEmpty);
    expect(
        Organizer.plan(<VFile>[done], rootDocId: 'root', onlyUnorganized: false)
            .length,
        1);
  });

  test('批内同目标同名标冲突', () {
    store.addDir('root', 'other');
    final VFile a = store.addFile('root/in', '示例歌名.mp3',
        tags: tagsOf(artist: '示例歌手'));
    final VFile b = store.addFile('root/other', '示例歌名.mp3',
        tags: tagsOf(artist: '示例歌手'));
    final List<MovePlan> plans = Organizer.plan(<VFile>[a, b], rootDocId: 'root');
    expect(plans.length, 2);
    expect(plans[0].conflict, isFalse);
    expect(plans[1].conflict, isTrue);
  });

  test('执行：逐段建目录、移动、进度回调', () async {
    final VFile f = store.addFile('root/in', '示例歌手-示例歌名.mp3', tags: tagsOf(artist: '示例歌手', album: '示例专辑'));
    final List<MovePlan> plans = Organizer.plan(<VFile>[f], rootDocId: 'root');
    final List<String> progress = <String>[];
    final OrganizeResult r = await Organizer.execute(store, plans,
        onProgress: (int done, int total) => progress.add('$done/$total'));

    expect(r.ok, 1);
    expect(r.skipped, 0);
    expect(r.failed, 0);
    expect(r.cancelled, isFalse);
    expect(progress, <String>['1/1']);
    expect(store.createdDirs, 2);
    expect(store.docs.containsKey('root/示例歌手/示例专辑/示例歌手-示例歌名.mp3'),
        isTrue);
    expect(store.docs.containsKey('root/in/示例歌手-示例歌名.mp3'), isFalse);
    expect(r.summary(), '成功 1 个 · 跳过 0 个 · 失败 0 个');
  });

  test('执行：预览后文件被删掉 → 跳过并说明，不建目录', () async {
    final VFile f = store.addFile('root/in', '示例歌名.mp3',
        tags: tagsOf(artist: '示例歌手', album: '示例专辑'));
    final List<MovePlan> plans =
        Organizer.plan(<VFile>[f], rootDocId: 'root');
    // 模拟「预览之后用户把文件删了 / 改名了」
    store.docs.remove(f.docId);

    final OrganizeResult r = await Organizer.execute(store, plans);
    expect(r.ok, 0);
    expect(r.skipped, 1);
    expect(r.failed, 0);
    expect(r.notes.single, contains('已不在原处'));
    expect(store.createdDirs, 0, reason: '文件都没了就不该建目标目录');
  });

  test('执行：预览后文件大小 / 修改时间变了 → 跳过而不按旧计划搬', () async {
    final VFile f = store.addFile('root/in', '示例歌名.mp3', size: 2048,
        tags: tagsOf(artist: '示例歌手'));
    final List<MovePlan> plans =
        Organizer.plan(<VFile>[f], rootDocId: 'root');
    // 同一 docId，但内容已经被别的程序改过（标签编辑器 / 转码工具）
    store.docs[f.docId] = f.copyWith(size: 4096);
    expect((await Organizer.execute(store, plans)).skipped, 1);

    // 大小没变、只有修改时间变（原地重写标签）
    final VFile g = store.addFile('root/in', '另一首.mp3', size: 2048,
        tags: tagsOf(artist: '示例歌手'));
    // 先给一个真实的修改时间，否则「计划里是 0」按规则不参与比较
    store.docs[g.docId] = g.copyWith(lastModified: 1000);
    final VFile snap = store.docs[g.docId]!;
    final List<MovePlan> plans2 =
        Organizer.plan(<VFile>[snap], rootDocId: 'root');
    store.docs[g.docId] = snap.copyWith(lastModified: 1700000000);
    final OrganizeResult r2 = await Organizer.execute(store, plans2);
    expect(r2.skipped, 1);
    expect(r2.notes.single, contains('预览之后文件有变化'));
  });

  test('执行：provider 拿不到大小 / 时间（都是 0）时不误判', () async {
    final VFile f = store.addFile('root/in', '无元数据.mp3', size: 0,
        tags: tagsOf(artist: '示例歌手'));
    final List<MovePlan> plans =
        Organizer.plan(<VFile>[f], rootDocId: 'root');
    // stat 回来的仍是 0：不能因为「0 != 0」以外的原因把文件全跳过
    final OrganizeResult r = await Organizer.execute(store, plans);
    expect(r.ok, 1);
    expect(r.skipped, 0);
  });

  test('执行：目标已有同名文件则跳过且不覆盖', () async {
    store.addDir('root', '示例歌手');
    store.addDir('root/示例歌手', '示例专辑');
    store.addFile('root/示例歌手/示例专辑', '示例歌名.mp3', size: 999);
    final VFile f = store.addFile('root/in', '示例歌名.mp3', size: 2048,
        tags: tagsOf(artist: '示例歌手', album: '示例专辑'));

    final OrganizeResult r = await Organizer.execute(
        store, Organizer.plan(<VFile>[f], rootDocId: 'root'));
    expect(r.ok, 0);
    expect(r.skipped, 1);
    expect(r.notes.single, contains('不覆盖'));
    expect(store.docs['root/示例歌手/示例专辑/示例歌名.mp3']!.size, 999);
    expect(store.docs.containsKey('root/in/示例歌名.mp3'), isTrue);
    expect(store.createdDirs, 0);
  });

  test('执行：批内冲突与移动失败分别记跳过 / 失败', () async {
    store.addDir('root', 'other');
    final VFile a = store.addFile('root/in', '示例歌名.mp3',
        tags: tagsOf(artist: '示例歌手'));
    final VFile b = store.addFile('root/other', '示例歌名.mp3',
        tags: tagsOf(artist: '示例歌手'));
    final List<MovePlan> plans = Organizer.plan(<VFile>[a, b], rootDocId: 'root');

    store.failMove = true;
    final OrganizeResult r = await Organizer.execute(store, plans);
    expect(r.ok, 0);
    expect(r.skipped, 1);
    expect(r.failed, 1);
    expect(r.errors.single, contains('E_IO'));
    expect(r.notes.single, contains('批内重名'));
  });

  test('执行：取消后不再搬任何文件', () async {
    final VFile f = store.addFile('root/in', '示例歌名.mp3',
        tags: tagsOf(artist: '示例歌手'));
    final List<MovePlan> plans = Organizer.plan(<VFile>[f], rootDocId: 'root');
    final OrganizeResult r = await Organizer.execute(store, plans,
        cancel: FlagToken(true));
    expect(r.cancelled, isTrue);
    expect(r.ok, 0);
    expect(r.skipped, 0);
    expect(store.docs.containsKey('root/in/示例歌名.mp3'), isTrue);
  });
}
