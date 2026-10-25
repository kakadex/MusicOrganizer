/// SAF MethodChannel 封装（channel `com.dsh.musicorganizer/saf`）。
///
/// T03 落地 pickTree / listRoots / stat / listChildren 四个方法（Kotlin SafPlugin 实现），
/// 其余方法（copy/write/readHead/readTail/create/delete/rename/move）T08 补齐，
/// 当前调用会抛 FileStoreException(E_IO)。
library;

import 'package:flutter/services.dart';

import '../core/fs/file_store.dart';

/// SAF MethodChannel 名（与 android 侧 SafPlugin 注册名一致）。
const String kSafChannelName = 'com.dsh.musicorganizer/saf';

/// 全局 SAF 通道。
final MethodChannel safChannel = MethodChannel(kSafChannelName);

/// 把平台异常映射为 [FileStoreException]（失败必须带原因）。
FileStoreException _mapError(Object e) {
  if (e is PlatformException) {
    switch (e.code) {
      case 'E_NO_PERMISSION':
        return FileStoreException('E_NO_PERMISSION', e.message ?? '');
      case 'E_NOT_FOUND':
        return FileStoreException('E_NOT_FOUND', e.message ?? '');
      case 'E_SECURITY':
        return FileStoreException('E_SECURITY', e.message ?? '');
      default:
        return FileStoreException('E_IO', e.message ?? e.code);
    }
  }
  return FileStoreException('E_IO', '$e');
}

/// SAF 通道封装。
class SafChannel {
  /// 选树；用户取消返回 null。
  Future<Map<String, String>?> pickTree() async {
    try {
      final Object? r = await safChannel.invokeMethod('pickTree');
      if (r == null) return null;
      final Map<Object?, Object?> m = r as Map;
      return <String, String>{
        'treeUri': '${m['treeUri']}',
        'rootDocId': '${m['rootDocId']}',
      };
    } catch (e) {
      throw _mapError(e);
    }
  }

  /// 已授权（persisted）的目录树列表。
  Future<List<Map<String, String>>> listRoots() async {
    try {
      final Object? r = await safChannel.invokeMethod('listRoots');
      if (r == null) return <Map<String, String>>[];
      return (r as List)
          .map((Object? e) => <String, String>{
                'treeUri': '${(e as Map)['treeUri']}',
                'rootDocId': '${e['rootDocId']}',
              })
          .toList();
    } catch (e) {
      throw _mapError(e);
    }
  }

  /// 单个文档信息；不存在返回 null。
  Future<Map<String, Object?>?> stat(String treeUri, String docId) async {
    try {
      final Object? r = await safChannel.invokeMethod(
          'stat', <String, Object?>{'treeUri': treeUri, 'docId': docId});
      if (r == null) return null;
      return Map<String, Object?>.from(r as Map);
    } catch (e) {
      throw _mapError(e);
    }
  }

  /// 目录子项（Kotlin 侧已按名排序 + docId 去重）。
  Future<List<Map<String, Object?>>> listChildren(
      String treeUri, String parentDocId) async {
    try {
      final Object? r = await safChannel.invokeMethod('listChildren',
          <String, Object?>{'treeUri': treeUri, 'parentDocId': parentDocId});
      if (r == null) return <Map<String, Object?>>[];
      return (r as List)
          .map((Object? e) => Map<String, Object?>.from(e as Map))
          .toList();
    } catch (e) {
      throw _mapError(e);
    }
  }

  // ------------------------------------------------------------------
  // T08 补齐（当前占位，调用抛 E_IO）
  // ------------------------------------------------------------------

  Future<int> copyDocToCache(String treeUri, String docId, String cachePath,
      int maxBytes) {
    throw FileStoreException('E_IO', '通道方法未实现（T08 补齐）');
  }

  Future<bool> writeCacheToDoc(String treeUri, String docId, String cachePath) {
    throw FileStoreException('E_IO', '通道方法未实现（T08 补齐）');
  }

  Future<Uint8List> readHead(String treeUri, String docId, int maxBytes) {
    throw FileStoreException('E_IO', '通道方法未实现（T08 补齐）');
  }

  Future<Uint8List> readTail(String treeUri, String docId, int maxBytes) {
    throw FileStoreException('E_IO', '通道方法未实现（T08 补齐）');
  }

  Future<Map<String, Object?>> createDocument(
      String treeUri, String parentDocId, String name, String mime) {
    throw FileStoreException('E_IO', '通道方法未实现（T08 补齐）');
  }

  Future<Map<String, Object?>> createDir(
      String treeUri, String parentDocId, String name) {
    throw FileStoreException('E_IO', '通道方法未实现（T08 补齐）');
  }

  Future<bool> deleteDocument(String treeUri, String docId) {
    throw FileStoreException('E_IO', '通道方法未实现（T08 补齐）');
  }

  Future<Map<String, Object?>> renameDocument(
      String treeUri, String docId, String newName) {
    throw FileStoreException('E_IO', '通道方法未实现（T08 补齐）');
  }

  Future<bool> moveDocument(
      String treeUri, String docId, String targetParentDocId) {
    throw FileStoreException('E_IO', '通道方法未实现（T08 补齐）');
  }
}
