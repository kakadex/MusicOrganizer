/// SAF MethodChannel 封装（channel `com.dsh.musicorganizer/saf`）。
///
/// 契约见架构设计 §2.2；Kotlin SafPlugin 实现全部 12 个方法。
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

  /// 把文档复制到本地缓存；maxBytes<=0 整文件。返回字节数。
  Future<int> copyDocToCache(
      String treeUri, String docId, String cachePath, int maxBytes) async {
    try {
      final Object? r = await safChannel.invokeMethod('copyDocToCache',
          <String, Object?>{
            'treeUri': treeUri,
            'docId': docId,
            'cachePath': cachePath,
            'maxBytes': maxBytes,
          });
      return (r as num?)?.toInt() ?? 0;
    } catch (e) {
      throw _mapError(e);
    }
  }

  /// 用本地缓存覆盖写回文档（"wt" 截断写）。
  Future<bool> writeCacheToDoc(
      String treeUri, String docId, String cachePath) async {
    try {
      final Object? r = await safChannel.invokeMethod('writeCacheToDoc',
          <String, Object?>{
            'treeUri': treeUri,
            'docId': docId,
            'cachePath': cachePath,
          });
      return r == true;
    } catch (e) {
      throw _mapError(e);
    }
  }

  /// 读文件头。
  Future<Uint8List?> readHead(String treeUri, String docId, int maxBytes) async {
    try {
      final Object? r = await safChannel.invokeMethod('readHead',
          <String, Object?>{'treeUri': treeUri, 'docId': docId, 'maxBytes': maxBytes});
      return r as Uint8List?;
    } catch (e) {
      throw _mapError(e);
    }
  }

  /// 读文件尾。
  Future<Uint8List?> readTail(String treeUri, String docId, int maxBytes) async {
    try {
      final Object? r = await safChannel.invokeMethod('readTail',
          <String, Object?>{'treeUri': treeUri, 'docId': docId, 'maxBytes': maxBytes});
      return r as Uint8List?;
    } catch (e) {
      throw _mapError(e);
    }
  }

  /// 扫系统媒体库里的音频（需要读取音频权限）。
  Future<List<Map<String, Object?>>> mediaStoreAudio(int minDurationMs) async {
    try {
      final Object? r = await safChannel.invokeMethod(
          'mediaStoreAudio', <String, Object?>{'minDurationMs': minDurationMs});
      if (r is! List) return <Map<String, Object?>>[];
      return <Map<String, Object?>>[
        for (final Object? e in r) Map<String, Object?>.from(e as Map),
      ];
    } catch (e) {
      throw _mapError(e);
    }
  }

  /// 把媒体库里的音频复制到本地缓存（导入用）；返回字节数。
  Future<int> copyMediaToCache(String uri, String cachePath) async {
    try {
      final Object? r = await safChannel.invokeMethod('copyMediaToCache',
          <String, Object?>{'uri': uri, 'cachePath': cachePath});
      return (r as int?) ?? 0;
    } catch (e) {
      throw _mapError(e);
    }
  }

  /// 申请读取音频的权限；已授权或用户同意返回 true。
  Future<bool> requestAudioPermission() async {
    try {
      final Object? r = await safChannel.invokeMethod('requestAudioPermission');
      return r == true;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, Object?>> createDocument(
      String treeUri, String parentDocId, String name, String mime) async {
    try {
      final Object? r = await safChannel.invokeMethod('createDocument',
          <String, Object?>{
            'treeUri': treeUri,
            'parentDocId': parentDocId,
            'name': name,
            'mime': mime,
          });
      return Map<String, Object?>.from(r as Map);
    } catch (e) {
      throw _mapError(e);
    }
  }

  Future<Map<String, Object?>> createDir(
      String treeUri, String parentDocId, String name) async {
    try {
      final Object? r = await safChannel.invokeMethod('createDir',
          <String, Object?>{
            'treeUri': treeUri,
            'parentDocId': parentDocId,
            'name': name,
          });
      return Map<String, Object?>.from(r as Map);
    } catch (e) {
      throw _mapError(e);
    }
  }

  Future<bool> deleteDocument(String treeUri, String docId) async {
    try {
      final Object? r = await safChannel.invokeMethod('deleteDocument',
          <String, Object?>{'treeUri': treeUri, 'docId': docId});
      return r == true;
    } catch (e) {
      throw _mapError(e);
    }
  }

  Future<Map<String, Object?>?> renameDocument(
      String treeUri, String docId, String newName) async {
    try {
      final Object? r = await safChannel.invokeMethod('renameDocument',
          <String, Object?>{'treeUri': treeUri, 'docId': docId, 'newName': newName});
      if (r == null) return null;
      return Map<String, Object?>.from(r as Map);
    } catch (e) {
      throw _mapError(e);
    }
  }

  Future<bool> moveDocument(String treeUri, String docId,
      String sourceParentDocId, String targetParentDocId) async {
    try {
      final Object? r = await safChannel.invokeMethod('moveDocument',
          <String, Object?>{
            'treeUri': treeUri,
            'docId': docId,
            'sourceParentDocId': sourceParentDocId,
            'targetParentDocId': targetParentDocId,
          });
      return r == true;
    } catch (e) {
      throw _mapError(e);
    }
  }

  /// 通知系统媒体库重扫（安卓 MediaScannerConnection）。
  Future<void> mediaScan(List<String> paths) async {
    try {
      await safChannel.invokeMethod('mediaScan', <String, Object?>{'paths': paths});
    } catch (_) {
      // 媒体库刷新失败不影响主流程
    }
  }
}
