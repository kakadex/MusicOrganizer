/// 桌面（dart:io）文件系统实现 —— id 即绝对路径。
///
/// head/tail 读文件偏移；copy/write 用 File；move 用 rename，跨卷失败回退「复制+删源」。
/// 目录选择器通过 [directoryPicker] 由 UI 层注入（core 保持纯 Dart、不引 file_selector）。
library;

import 'dart:io';
import 'dart:typed_data';

import '../model/vfile.dart';
import 'file_store.dart';
import 'tree_ref.dart';
import 'tree_lookup.dart';

/// 桌面文件系统实现。
class DesktopFileStore implements FileStore {
  /// 多根分派（桌面 id 即路径，前缀匹配仍可用）。
  final TreeLookup lookup = TreeLookup();

  final List<TreeRef> _roots = <TreeRef>[];

  /// 目录选择器（UI 层注入 file_selector.getDirectoryPath）。
  Future<String?> Function()? directoryPicker;

  @override
  Future<List<TreeRef>> roots() async => List<TreeRef>.of(_roots);

  /// 登记一个根目录（也供测试直接注入）。
  void addRoot(String path) {
    if (path.isEmpty) return;
    final String norm = _normalize(path);
    if (!_roots.any((TreeRef r) => r.rootDocId == norm)) {
      final TreeRef ref = TreeRef(treeUri: norm, rootDocId: norm);
      _roots.add(ref);
      lookup.add(ref);
    }
  }

  @override
  Future<TreeRef?> pickTree() async {
    final String? path = await directoryPicker?.call();
    if (path == null || path.isEmpty) return null;
    addRoot(path);
    final String norm = _normalize(path);
    for (final TreeRef r in _roots) {
      if (r.rootDocId == norm) return r;
    }
    return null;
  }

  @override
  Future<void> releaseTree(TreeRef t) async {
    _roots.removeWhere((TreeRef r) => r.rootDocId == t.rootDocId);
    lookup.remove(t.treeUri);
  }

  @override
  Future<VFile?> stat(String id) async {
    try {
      final FileStat s = await File(id).stat();
      if (s.type == FileSystemEntityType.notFound) return null;
      return _fromStat(id, s);
    } on FileSystemException catch (e) {
      throw FileStoreException('E_IO', e.message);
    }
  }

  @override
  Future<List<VFile>> children(VFile dir) async {
    try {
      final List<VFile> out = <VFile>[];
      final Set<String> seen = <String>{};
      final List<FileSystemEntity> entities =
          await Directory(dir.docId).list().toList();
      for (final FileSystemEntity e in entities) {
        final FileStat s = await e.stat();
        final VFile v = _fromStat(e.path, s);
        if (seen.add(v.docId)) out.add(v);
      }
      out.sort((VFile a, VFile b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return out;
    } on FileSystemException catch (e) {
      throw FileStoreException('E_IO', e.message);
    }
  }

  @override
  Uri documentUri(String id) => Uri.file(id);

  @override
  Future<Uint8List> headBytes(VFile f, int maxBytes) async {
    try {
      final RandomAccessFile raf = await File(f.docId).open();
      try {
        final int n = maxBytes < raf.lengthSync() ? maxBytes : raf.lengthSync();
        return raf.readSync(n);
      } finally {
        await raf.close();
      }
    } on FileSystemException catch (e) {
      throw FileStoreException('E_IO', e.message);
    }
  }

  @override
  Future<Uint8List> tailBytes(VFile f, int maxBytes) async {
    try {
      final RandomAccessFile raf = await File(f.docId).open();
      try {
        final int len = raf.lengthSync();
        final int n = maxBytes < len ? maxBytes : len;
        await raf.setPosition(len - n);
        return raf.readSync(n);
      } finally {
        await raf.close();
      }
    } on FileSystemException catch (e) {
      throw FileStoreException('E_IO', e.message);
    }
  }

  @override
  Future<void> copyToLocal(VFile f, File cacheTarget) async {
    try {
      await File(f.docId).copy(cacheTarget.path);
    } on FileSystemException catch (e) {
      throw FileStoreException('E_IO', e.message);
    }
  }

  @override
  Future<void> writeFromLocal(VFile f, File cacheSource) async {
    try {
      await File(f.docId).writeAsBytes(await cacheSource.readAsBytes(), flush: true);
    } on FileSystemException catch (e) {
      throw FileStoreException('E_IO', e.message);
    }
  }

  @override
  Future<VFile> createFile(VFile parent, String name, String mime) async {
    try {
      final String path = _join(parent.docId, name);
      final File file = await File(path).create();
      return _fromStat(path, await file.stat());
    } on FileSystemException catch (e) {
      throw FileStoreException('E_IO', e.message);
    }
  }

  @override
  Future<VFile> createDir(VFile parent, String name) async {
    try {
      final String path = _join(parent.docId, name);
      final Directory dir = await Directory(path).create();
      return _fromStat(path, await dir.stat());
    } on FileSystemException catch (e) {
      throw FileStoreException('E_IO', e.message);
    }
  }

  @override
  Future<bool> delete(VFile f) async {
    try {
      if (f.dir) {
        await Directory(f.docId).delete(recursive: true);
      } else {
        await File(f.docId).delete();
      }
      return true;
    } on FileSystemException {
      return false;
    }
  }

  @override
  Future<bool> rename(VFile f, String newName) async {
    try {
      final String target = _join(_dirname(f.docId), newName);
      await File(f.docId).rename(target);
      return true;
    } on FileSystemException {
      return false;
    }
  }

  @override
  Future<String?> move(VFile f, VFile targetDir) async {
    final String target = _join(targetDir.docId, f.name);
    try {
      await File(f.docId).rename(target);
      return null;
    } on FileSystemException {
      // 跨卷 rename 失败：回退「复制 + 删除」
      try {
        final File src = File(f.docId);
        await src.copy(target);
        await src.delete();
        return null;
      } on FileSystemException catch (e) {
        return e.message;
      }
    }
  }

  VFile _fromStat(String path, FileStat s) {
    return VFile(
      docId: path,
      parentId: _dirname(path).isEmpty ? null : _dirname(path),
      name: _basename(path),
      mime: '',
      size: s.size,
      lastModified: s.modified.millisecondsSinceEpoch,
      dir: s.type == FileSystemEntityType.directory,
    );
  }

  static String _normalize(String path) => path.replaceAll('\\', '/');

  static String _basename(String path) {
    final String p = _normalize(path);
    final int slash = p.lastIndexOf('/');
    return slash < 0 ? p : p.substring(slash + 1);
  }

  static String _dirname(String path) {
    final String p = _normalize(path);
    final int slash = p.lastIndexOf('/');
    return slash <= 0 ? '' : p.substring(0, slash);
  }

  static String _join(String parent, String name) {
    final String p = _normalize(parent);
    return p.endsWith('/') ? '$p$name' : '$p/$name';
  }
}
