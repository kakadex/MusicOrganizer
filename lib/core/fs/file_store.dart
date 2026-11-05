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
  FileStoreException(this.code, this.message, {this.originalCode, this.cause});

  /// E_NO_PERMISSION / E_NOT_FOUND / E_SECURITY / E_IO /
  /// E_CANCELLED / E_TIMEOUT / E_QUOTA_EXCEEDED / E_LOCKED / E_NOT_READY。
  final String code;

  final String message;

  /// 平台原始 code（如 PlatformException.code），便于排查映射问题。
  final String? originalCode;

  /// 原始异常对象（可空）。
  final Object? cause;

  @override
  String toString() => 'FileStoreException($code): $message';
}

/// 文件系统抽象：上层（扫描 / 整理 / 写盘）不感知 SAF 与 dart:io 的差异。
abstract class FileStore {
  /// 已授权（或已登记）的目录树。
  Future<List<TreeRef>> roots();

  /// 单个目录树的授权状态：VALID / REVOKED / UNAVAILABLE / NOT_READY。
  ///
  /// 桌面没有「授权」这回事，目录在就是 VALID；只有安卓需要分级。
  Future<String> authState(String treeUri) async => 'VALID';

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

  /// 用系统播放器打开一首歌（单曲试听）。
  ///
  /// 返回 null = 成功拉起；否则为失败原因文案。桌面用系统默认播放器打开，
  /// 安卓用 ACTION_VIEW + FLAG_GRANT_READ 拉起系统播放器（URI 必须来自
  /// 已授权目录树，由平台实现校验）。
  Future<String?> openWithPlayer(VFile f) async =>
      '当前平台不支持播放';

  /// 读文件头 [maxBytes] 字节。
  Future<Uint8List> headBytes(VFile f, int maxBytes);

  /// 读文件尾 [maxBytes] 字节。
  Future<Uint8List> tailBytes(VFile f, int maxBytes);

  /// 从 [offset] 处读 [maxBytes] 字节（查重取中段指纹用）。
  ///
  /// 默认返回空：能力是可选的，取不到就退回「只用首尾」的旧判定，
  /// 不会因为某个实现不支持而让整次查重失败。
  Future<Uint8List> rangeBytes(VFile f, int offset, int maxBytes) async =>
      Uint8List(0);

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

  /// 在「界面正在等结果」的窗口里执行 [action]（0.2.68）。
  ///
  /// 安卓 SAF 实现会在这段时间里把读请求标成交互优先（走独立的 2 线程池），
  /// 免得排在批量读标签的大请求后面；桌面实现直接执行，没有调度差异。
  ///
  /// 用钩子而不是给每个方法加参数：接口有 7 个实现，加参数要把测试桩全改一遍；
  /// 而且「这段时间算交互」是调用方的意图，不该塞进每个方法的签名。
  Future<T> runInteractive<T>(Future<T> Function() action) => action();

  /// 通知实现「这一批我取消了」：丢弃还在排队、尚未开跑的底层调用（0.2.68）。
  ///
  /// 只影响排队中的调用，已经在执行的那个会自然完成——中途打断写入反而可能
  /// 留下半成品。桌面实现是空操作。
  Future<void> cancelPending(String token) async {}
}
