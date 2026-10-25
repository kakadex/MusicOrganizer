/// 文件系统抽象契约（架构设计 §2.2）—— 安卓 SAF / 桌面 dart:io 双实现的共同父类。
///
/// 失败必须带原因：所有方法出错抛 [FileStoreException]。
library;

import 'dart:io';
import 'dart:typed_data';

import '../model/vfile.dart';
import 'tree_ref.dart';

/// 文件系统访问异常。
class FileStoreException implements Exception {
  FileStoreException(this.code, this.message);

  /// E_NO_PERMISSION / E_NOT_FOUND / E_SECURITY / E_IO。
  final String code;

  final String message;

  @override
  String toString() => 'FileStoreException($code): $message';
}

/// 文件系统抽象：上层（扫描 / 整理 / 写盘）不感知 SAF 与 dart:io 的差异。
abstract class FileStore {
  /// 已授权（或已登记）的目录树。
  Future<List<TreeRef>> roots();

  /// 选择一棵树（安卓：OpenDocumentTree；桌面：目录选择器）。
  Future<TreeRef?> pickTree();

  /// 释放一棵树的授权。
  Future<void> releaseTree(TreeRef t);

  /// 单个文档信息；不存在返回 null。
  Future<VFile?> stat(String id);

  /// 目录子项（按名排序 + docId 去重）。
  Future<List<VFile>> children(VFile dir);

  /// 文档的 content uri（安卓）；桌面为 file uri。
  Uri documentUri(String id);

  /// 读文件头 [maxBytes] 字节。
  Future<Uint8List> headBytes(VFile f, int maxBytes);

  /// 读文件尾 [maxBytes] 字节。
  Future<Uint8List> tailBytes(VFile f, int maxBytes);

  /// 把文档复制到本地缓存文件。
  Future<void> copyToLocal(VFile f, File cacheTarget);

  /// 用本地缓存文件覆盖写回文档（截断写）。
  Future<void> writeFromLocal(VFile f, File cacheSource);

  Future<VFile> createFile(VFile parent, String name, String mime);

  Future<VFile> createDir(VFile parent, String name);

  Future<bool> delete(VFile f);

  Future<bool> rename(VFile f, String newName);

  /// 移动；null=成功，否则为失败原因（优先 moveDocument，失败回退复制+校验+删除）。
  Future<String?> move(VFile f, VFile targetDir);
}
