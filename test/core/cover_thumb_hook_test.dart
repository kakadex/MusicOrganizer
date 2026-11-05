/// 旁挂图 / 目录封面的磁盘小图快路径（0.2.87）。
///
/// 背景：整专辑曲库每个目录放一张 cover.jpg（常见 1–4MB），旧版列表每次
/// 滚动都要列目录 + 读原图 + 解码；内存缓存上限 24MB，只够约 6 张。
///
/// 这里用假存储记录「读了多少次原图」，直接断言优化是否真的生效：
/// - 第一次查：读原图一次，缩图落盘一次；
/// - 之后用同一个键查（模拟重启后内存缓存空了）：**不再读原图**，走小图。
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/cover/cover_thumb_hook.dart';
import 'package:musicorganizer/core/cover/folder_cover.dart';
import 'package:musicorganizer/core/cover/sidecar_cover.dart';
import 'package:musicorganizer/core/fs/file_store.dart';
import 'package:musicorganizer/core/model/vfile.dart';

/// 只实现封面查找要用的几个方法，并记录读原图的次数。
class _Store implements FileStore {
  _Store(this.files);

  /// docId → 文件内容（图片字节）。
  final Map<String, Uint8List> files;

  /// 子项按父目录分组。
  final Map<String, List<String>> kids = <String, List<String>>{};

  /// 读原图（headBytes）的次数 —— 本测试的核心指标。
  int originalReads = 0;

  void add(String parentId, String name, Uint8List bytes) {
    final String docId = '$parentId/$name';
    files[docId] = bytes;
    kids.putIfAbsent(parentId, () => <String>[]).add(name);
  }

  @override
  Future<List<VFile>> children(VFile dir) async => <VFile>[
        for (final String name in kids[dir.docId] ?? const <String>[])
          VFile(
            docId: '${dir.docId}/$name',
            parentId: dir.docId,
            name: name,
            size: files['${dir.docId}/$name']!.length,
          ),
      ];

  @override
  Future<VFile?> stat(String id) async {
    final Uint8List? b = files[id];
    if (b == null) return null;
    final int slash = id.lastIndexOf('/');
    return VFile(
      docId: id,
      parentId: slash <= 0 ? '' : id.substring(0, slash),
      name: slash < 0 ? id : id.substring(slash + 1),
      size: b.length,
    );
  }

  @override
  Future<Uint8List> headBytes(VFile f, int maxBytes) async {
    originalReads++;
    return files[f.docId] ?? Uint8List(0);
  }

  @override
  Future<T> runInteractive<T>(Future<T> Function() action) => action();

  @override
  Future<void> cancelPending(String token) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Uint8List bigImage(int n) => Uint8List.fromList(List<int>.filled(n, 0x42));

/// 假磁盘缓存：键 → 小图。
class _FakeDisk {
  final Map<String, Uint8List> store = <String, Uint8List>{};
  int saves = 0;
  int shrinks = 0;

  String keyOf(VFile f) => '${f.docId}|${f.size}';

  void install() {
    CoverThumbHook.peek = (VFile f) async => store[keyOf(f)];
    CoverThumbHook.save = (VFile f, Uint8List art) async {
      saves++;
      store[keyOf(f)] = Uint8List.fromList(<int>[1, 2, 3, 4]);
    };
    CoverThumbHook.shrink = (Uint8List art) async {
      shrinks++;
      return Uint8List.fromList(<int>[9, 9, 9, 9]);
    };
  }
}

void main() {
  late _FakeDisk disk;

  setUp(() {
    FolderCover.invalidate();
    SidecarCover.invalidate();
    disk = _FakeDisk()..install();
  });

  tearDown(() {
    CoverThumbHook.reset();
    FolderCover.invalidate();
    SidecarCover.invalidate();
  });

  test('目录封面：首次读原图并落盘，且内存里存的是缩过的（不是 4MB 原图）', () async {
    final _Store st = _Store(<String, Uint8List>{});
    st.add('album', 'cover.jpg', bigImage(4000));
    final VFile dir = VFile(docId: 'album', name: 'album', dir: true);

    final Uint8List? art = await FolderCover.find(st, dir);
    expect(art, isNotNull);
    expect(st.originalReads, 1, reason: '第一次必须读一次原图');
    expect(disk.saves, 1, reason: '原图应缩一次并落盘');
    expect(disk.shrinks, 1);
    expect(art!.length, 4, reason: '内存里拿到的应是缩图（假缩小图 4 字节），不是 4000 字节原图');
  });

  test('目录封面：二次查找（模拟重启后内存缓存为空）不再读原图', () async {
    final _Store st = _Store(<String, Uint8List>{});
    st.add('album', 'cover.jpg', bigImage(4000));
    final VFile dir = VFile(docId: 'album', name: 'album', dir: true);

    await FolderCover.find(st, dir);
    expect(st.originalReads, 1);

    FolderCover.invalidate(); // 模拟重启：内存缓存清空，磁盘还在
    final Uint8List? again = await FolderCover.find(st, dir);
    expect(again, isNotNull);
    expect(st.originalReads, 1, reason: '命中磁盘小图后不许再读原图');
    expect(disk.saves, 1, reason: '命中缓存不该重复落盘');
  });

  test('同名图片：同样走小图快路径', () async {
    final _Store st = _Store(<String, Uint8List>{});
    st.add('album', 'song.jpg', bigImage(3000));
    final VFile audio = VFile(
        docId: 'album/song.mp3', parentId: 'album', name: 'song.mp3', size: 10);

    final Uint8List? art = await SidecarCover.find(st, audio);
    expect(art, isNotNull);
    expect(st.originalReads, 1);
    expect(disk.saves, 1);

    SidecarCover.invalidate();
    final Uint8List? again = await SidecarCover.find(st, audio);
    expect(again, isNotNull);
    expect(st.originalReads, 1, reason: '命中磁盘小图后不许再读原图');
  });

  test('没有钩子（未挂载）时退回老路：仍然能拿到封面', () async {
    CoverThumbHook.reset();
    final _Store st = _Store(<String, Uint8List>{});
    st.add('album', 'cover.jpg', bigImage(500));
    final VFile dir = VFile(docId: 'album', name: 'album', dir: true);

    final Uint8List? art = await FolderCover.find(st, dir);
    expect(art, isNotNull);
    expect(art!.length, 500, reason: '没有缩小钩子时按原图返回');
    expect(st.originalReads, 1);
  });

  test('目录确实没有封面：缓存空结果，不反复列目录', () async {
    final _Store st = _Store(<String, Uint8List>{});
    final VFile dir = VFile(docId: 'empty', name: 'empty', dir: true);

    expect(await FolderCover.find(st, dir), isNull);
    expect(await FolderCover.find(st, dir), isNull);
    expect(st.originalReads, 0);
  });
}
