/// 安卓 SAF 文件系统实现（走 MethodChannel，多根分派用 TreeLookup）。
///
/// 大文件 copy/write 走 cache 中转；SAF content uri 由 Kotlin 侧 DocumentsContract 构建。
library;

import 'dart:io';
import 'dart:typed_data';

import '../../platform/saf_channel.dart';
import '../model/vfile.dart';
import 'file_store.dart';
import 'tree_ref.dart';
import 'tree_lookup.dart';

/// 安卓 SAF 文件系统实现。
class SafFileStore implements FileStore {
  SafFileStore({SafChannel? channel, TreeLookup? lookup})
      : _channel = channel ?? SafChannel(),
        lookup = lookup ?? TreeLookup();

  final SafChannel _channel;

  /// 多根分派。
  final TreeLookup lookup;

  @override
  Future<List<TreeRef>> roots() async {
    final List<Map<String, String>> roots = await _channel.listRoots();
    final List<TreeRef> out = <TreeRef>[];
    for (final Map<String, String> m in roots) {
      final TreeRef t = TreeRef(treeUri: m['treeUri']!, rootDocId: m['rootDocId']!);
      lookup.add(t);
      out.add(t);
    }
    return out;
  }

  @override
  Future<String> authState(String treeUri) async {
    if (treeUri.isEmpty) return 'REVOKED';
    try {
      return await _channel.authState(treeUri);
    } catch (_) {
      // 通道异常不等于授权失效：按「暂不可用」处理，保留记录等下次再试
      return 'NOT_READY';
    }
  }

  @override
  Future<TreeRef?> pickTree() async {
    final Map<String, String>? m = await _channel.pickTree();
    if (m == null) return null;
    final TreeRef t = TreeRef(treeUri: m['treeUri']!, rootDocId: m['rootDocId']!);
    lookup.add(t);
    return t;
  }

  @override
  Future<void> releaseTree(TreeRef t) async {
    lookup.remove(t.treeUri);
    // 实际撤销持久授权（releasePersistableUriPermission）由 UI 层另行触发。
  }

  TreeRef _treeFor(String docId) {
    final TreeRef? t = lookup.treeFor(docId);
    if (t == null) {
      throw FileStoreException('E_NOT_FOUND', '不属于任何已授权目录树');
    }
    return t;
  }

  VFile _vfile(Map<String, Object?> m) {
    final Object? parent = m['parentId'];
    return VFile(
      docId: '${m['docId'] ?? ''}',
      parentId: (parent == null || '$parent'.isEmpty) ? null : '$parent',
      name: '${m['name'] ?? ''}',
      mime: '${m['mime'] ?? ''}',
      size: (m['size'] as num?)?.toInt() ?? 0,
      lastModified: (m['mtime'] as num?)?.toInt() ?? 0,
      dir: m['isDir'] == true,
    );
  }

  @override
  Future<VFile?> stat(String id) async {
    final TreeRef t = _treeFor(id);
    final Map<String, Object?>? m = await _channel.stat(t.treeUri, id);
    return m == null ? null : _vfile(m);
  }

  @override
  Future<List<VFile>> children(VFile dir) async {
    final TreeRef t = _treeFor(dir.docId);
    final List<Map<String, Object?>> list =
        await _channel.listChildren(t.treeUri, dir.docId);
    return list.map(_vfile).toList();
  }

  @override
  Uri documentUri(String id) => Uri.parse('saf:$id');

  @override
  Future<Uint8List> headBytes(VFile f, int maxBytes) async {
    final TreeRef t = _treeFor(f.docId);
    return await _channel.readHead(t.treeUri, f.docId, maxBytes) ?? Uint8List(0);
  }

  @override
  Future<Uint8List> rangeBytes(VFile f, int offset, int maxBytes) async {
    if (maxBytes <= 0 || offset < 0) return Uint8List(0);
    final TreeRef t = _treeFor(f.docId);
    return await _channel.readRange(t.treeUri, f.docId, offset, maxBytes) ??
        Uint8List(0);
  }

  @override
  Future<Uint8List> tailBytes(VFile f, int maxBytes) async {
    final TreeRef t = _treeFor(f.docId);
    return await _channel.readTail(t.treeUri, f.docId, maxBytes) ?? Uint8List(0);
  }

  @override
  Future<void> copyToLocal(VFile f, File cacheTarget) async {
    final TreeRef t = _treeFor(f.docId);
    await _channel.copyDocToCache(t.treeUri, f.docId, cacheTarget.path, 0);
  }

  @override
  Future<void> writeFromLocal(VFile f, File cacheSource) async {
    final TreeRef t = _treeFor(f.docId);
    final bool ok =
        await _channel.writeCacheToDoc(t.treeUri, f.docId, cacheSource.path);
    if (!ok) throw FileStoreException('E_IO', '写回失败：${f.name}');
  }

  @override
  Future<VFile> createFile(VFile parent, String name, String mime) async {
    final TreeRef t = _treeFor(parent.docId);
    final Map<String, Object?> m =
        await _channel.createDocument(t.treeUri, parent.docId, name, mime);
    return _vfile(m);
  }

  @override
  Future<VFile> createDir(VFile parent, String name) async {
    final TreeRef t = _treeFor(parent.docId);
    final Map<String, Object?> m =
        await _channel.createDir(t.treeUri, parent.docId, name);
    return _vfile(m);
  }

  @override
  Future<bool> delete(VFile f) async {
    final TreeRef t = _treeFor(f.docId);
    return _channel.deleteDocument(t.treeUri, f.docId);
  }

  @override
  Future<bool> rename(VFile f, String newName) async {
    final TreeRef t = _treeFor(f.docId);
    final Map<String, Object?>? m =
        await _channel.renameDocument(t.treeUri, f.docId, newName);
    return m != null;
  }

  @override
  Future<String?> move(VFile f, VFile targetDir) async {
    final TreeRef t = _treeFor(f.docId);
    final String sourceParent = f.parentId ?? t.rootDocId;
    final bool ok = await _channel.moveDocument(
        t.treeUri, f.docId, sourceParent, targetDir.docId);
    return ok ? null : '移动失败：${f.name}';
  }
}
