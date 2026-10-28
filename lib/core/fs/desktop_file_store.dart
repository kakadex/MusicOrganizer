/// 桌面（dart:io）文件系统实现 —— id 即绝对路径。
///
/// head/tail 读文件偏移；copy/write 用 File；move 用 rename，跨卷失败回退
/// 「临时文件 → 校验 → 原子 rename → 删源」。
/// 目录选择器通过 [directoryPicker] 由 UI 层注入（core 保持纯 Dart、不引 file_selector）。
///
/// **安全边界**：所有公开操作都要求 id 位于已登记根目录之下；`..` 先做词法消解，
/// 前缀匹配按路径段（避免 `C:/Music2` 被误判成 `C:/Music` 的子路径），创建 / 改名
/// 只接受单段名字。符号链接仍按词法校验（不解析），指向根外的链接属于系统级
/// 配置问题，不在应用层做递归解析。
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

  @override
  Future<String> authState(String treeUri) async {
    // 桌面没有「授权」这回事：目录还在就能用；不在多半是盘没插或目录被移走，
    // 属于「暂时读不到」——保留记录等下次再试，不能当成授权失效清掉
    if (treeUri.isEmpty) return 'UNAVAILABLE';
    return Directory(_canonicalize(treeUri)).existsSync() ? 'VALID' : 'UNAVAILABLE';
  }

  /// 登记一个根目录（也供测试直接注入）。
  void addRoot(String path) {
    final String raw = path.trim();
    if (raw.isEmpty) return;
    // UNC（\\server\share）不走这里：桌面选择器返回的是本地路径，UNC 直接拒绝
    if (raw.startsWith('\\\\') || raw.startsWith('//')) return;
    final String norm = _canonicalize(raw);
    if (!_isAbsolute(norm)) return;
    if (!_roots.any((TreeRef r) => _samePath(r.rootDocId, norm))) {
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
    final String norm = _canonicalize(path);
    for (final TreeRef r in _roots) {
      if (_samePath(r.rootDocId, norm)) return r;
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
    _assertWithinRoots(id);
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
    _assertWithinRoots(dir.docId);
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
    _assertWithinRoots(f.docId);
    try {
      final RandomAccessFile raf = await File(f.docId).open();
      try {
        final int len = await raf.length();
        final int n = maxBytes < len ? maxBytes : len;
        return await raf.read(n);
      } finally {
        await raf.close();
      }
    } on FileSystemException catch (e) {
      throw FileStoreException('E_IO', e.message);
    }
  }

  @override
  Future<Uint8List> tailBytes(VFile f, int maxBytes) async {
    _assertWithinRoots(f.docId);
    try {
      final RandomAccessFile raf = await File(f.docId).open();
      try {
        final int len = await raf.length();
        final int n = maxBytes < len ? maxBytes : len;
        await raf.setPosition(len - n);
        return await raf.read(n);
      } finally {
        await raf.close();
      }
    } on FileSystemException catch (e) {
      throw FileStoreException('E_IO', e.message);
    }
  }

  @override
  Future<void> copyToLocal(VFile f, File cacheTarget) async {
    _assertWithinRoots(f.docId);
    try {
      await File(f.docId).copy(cacheTarget.path);
    } on FileSystemException catch (e) {
      throw FileStoreException('E_IO', e.message);
    }
  }

  @override
  Future<void> writeFromLocal(VFile f, File cacheSource) async {
    _assertWithinRoots(f.docId);
    try {
      await File(f.docId).writeAsBytes(await cacheSource.readAsBytes(), flush: true);
    } on FileSystemException catch (e) {
      throw FileStoreException('E_IO', e.message);
    }
  }

  @override
  Future<VFile> createFile(VFile parent, String name, String mime) async {
    _assertWithinRoots(parent.docId);
    _assertSafeName(name);
    try {
      final String path = _join(parent.docId, name);
      _assertWithinRoots(path);
      final File file = await File(path).create();
      return _fromStat(path, await file.stat());
    } on FileSystemException catch (e) {
      throw FileStoreException('E_IO', e.message);
    }
  }

  @override
  Future<VFile> createDir(VFile parent, String name) async {
    _assertWithinRoots(parent.docId);
    _assertSafeName(name);
    try {
      final String path = _join(parent.docId, name);
      _assertWithinRoots(path);
      final Directory dir = await Directory(path).create();
      return _fromStat(path, await dir.stat());
    } on FileSystemException catch (e) {
      throw FileStoreException('E_IO', e.message);
    }
  }

  @override
  Future<bool> delete(VFile f) async {
    _assertWithinRoots(f.docId);
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
    _assertWithinRoots(f.docId);
    _assertSafeName(newName);
    try {
      final String target = _join(_dirname(f.docId), newName);
      _assertWithinRoots(target);
      await File(f.docId).rename(target);
      return true;
    } on FileSystemException {
      return false;
    }
  }

  @override
  Future<String?> move(VFile f, VFile targetDir) async {
    _assertWithinRoots(f.docId);
    _assertWithinRoots(targetDir.docId);
    _assertSafeName(f.name);
    final String target = _join(targetDir.docId, f.name);
    _assertWithinRoots(target);
    try {
      await File(f.docId).rename(target);
      return null;
    } on FileSystemException {
      // 跨卷 rename 失败：先复制到目标同目录的临时文件，校验大小后原子改名，
      // 最后才删源。任一步失败都保留源文件并清掉临时文件，绝不“复制一半”。
      final File src = File(f.docId);
      final File tmp = File(
          '$target.mo_tmp_${DateTime.now().microsecondsSinceEpoch}');
      try {
        await src.copy(tmp.path);
        if (await src.length() != await tmp.length()) {
          await tmp.delete();
          return '跨卷移动校验失败：大小不一致';
        }
        await tmp.rename(target);
        await src.delete();
        return null;
      } on FileSystemException catch (e) {
        try {
          await tmp.delete();
        } catch (_) {}
        return e.message;
      }
    }
  }

  VFile _fromStat(String path, FileStat s) {
    // docId / parentId 统一用 `/`（Windows 上 `File('C:/a/b')` 一样能开）——
    // 根目录本来就是归一过的，这里不归一会让 relativePath 匹配不上，
    // 整理时「已经在目标目录里」就永远判不出来，已归位的文件会被反复重排。
    final String id = _canonicalize(path);
    final String parent = _dirname(path);
    return VFile(
      docId: id,
      parentId: parent.isEmpty ? null : parent,
      name: _basename(path),
      mime: '',
      size: s.size,
      lastModified: s.modified.millisecondsSinceEpoch,
      dir: s.type == FileSystemEntityType.directory,
    );
  }

  // ---- 路径安全 ----

  /// 词法规范化：统一分隔符、消解 `.` / `..`、去尾斜杠。
  ///
  /// 只做词法层，不解析符号链接；根目录内的符号链接指向根外属于系统级配置，
  /// 需要时由上层另行处理（当前桌面端不跟随链接做删除 / 写入）。
  static String _canonicalize(String path) {
    final String unified = path.replaceAll('\\', '/');
    final bool absolute = _isAbsolute(unified);
    final List<String> out = <String>[];
    for (final String p in unified.split('/')) {
      if (p.isEmpty || p == '.') continue;
      if (p == '..') {
        if (out.isNotEmpty) {
          out.removeLast();
        } else if (!absolute) {
          out.add('..');
        }
      } else {
        out.add(p);
      }
    }
    if (out.isEmpty) return absolute ? '/' : '';
    final String joined = out.join('/');
    return unified.startsWith('/') ? '/$joined' : joined;
  }

  static bool _isAbsolute(String p) =>
      p.startsWith('/') || RegExp(r'^[A-Za-z]:/').hasMatch(p);

  static bool _samePath(String a, String b) {
    final String ca = _canonicalize(a);
    final String cb = _canonicalize(b);
    return Platform.isWindows ? ca.toLowerCase() == cb.toLowerCase() : ca == cb;
  }

  /// child 是否等于 parent 或位于 parent 之下（按路径段边界，不是字符串前缀）。
  static bool _isWithin(String child, String parent) {
    String c = _canonicalize(child);
    String p = _canonicalize(parent);
    if (Platform.isWindows) {
      c = c.toLowerCase();
      p = p.toLowerCase();
    }
    if (c == p) return true;
    final String prefix = p.endsWith('/') ? p : '$p/';
    return c.startsWith(prefix);
  }

  /// 所有公开操作的第一道闸：目标必须在某个已登记根目录之下。
  void _assertWithinRoots(String id) {
    final String c = _canonicalize(id);
    if (!_isAbsolute(c)) {
      throw FileStoreException('E_SECURITY', 'relative path: $id');
    }
    for (final TreeRef r in _roots) {
      if (_isWithin(c, r.rootDocId)) return;
    }
    throw FileStoreException('E_SECURITY', 'path outside authorized roots: $id');
  }

  /// 创建 / 改名只接受单段名字：带分隔符、`.`、`..` 一律拒绝。
  static void _assertSafeName(String name) {
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains('\\') ||
        name.contains('\u0000') ||
        (Platform.isWindows && name.contains(':'))) {
      throw FileStoreException('E_SECURITY', 'invalid name: $name');
    }
  }

  static String _basename(String path) {
    final String p = _canonicalize(path);
    final int slash = p.lastIndexOf('/');
    return slash < 0 ? p : p.substring(slash + 1);
  }

  static String _dirname(String path) {
    final String p = _canonicalize(path);
    final int slash = p.lastIndexOf('/');
    return slash <= 0 ? '' : p.substring(0, slash);
  }

  static String _join(String parent, String name) {
    final String p = _canonicalize(parent);
    return p.endsWith('/') ? '$p$name' : '$p/$name';
  }
}
