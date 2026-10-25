/// 桌面拖放接入（Windows）。
///
/// Flutter 框架本身没有「把文件拖进窗口」的 API，所以在运行器（windows/runner）
/// 里接了 `WM_DROPFILES`，把路径通过 MethodChannel 送过来，这里只做解析与分发。
/// 好处：不引 pub 包，双端依赖白名单不变。
///
/// 规则（与界面上的「选择目录」等价）：
/// - 拖进来的是**文件夹** → 直接当曲库根；
/// - 拖进来的是**文件** → 取它所在的目录当曲库根（用户拖几首歌进来，意图通常是「看这个目录」）。
library;

import 'dart:io';

import 'package:flutter/services.dart';

/// 一次拖放解析结果。
class DropResult {
  const DropResult({
    required this.rootPath,
    required this.fileCount,
    required this.fromDirectory,
  });

  /// 要作为曲库根的目录（绝对路径）。
  final String rootPath;

  /// 拖进来的文件个数（拖的是目录时为 0）。
  final int fileCount;

  /// 是否直接拖的目录。
  final bool fromDirectory;

  String describe() => fromDirectory
      ? '已切换到 $rootPath'
      : '已按 $fileCount 个文件所在目录切换：$rootPath';
}

/// 拖放解析（纯逻辑，可离线单测）。
abstract final class DropAction {
  /// 把路径列表解析成「曲库根」。
  ///
  /// [isDirectory] 可注入（测试用），默认走 `FileSystemEntity`。
  static DropResult? resolve(
    List<String>? paths, {
    bool Function(String path)? isDirectory,
  }) {
    if (paths == null || paths.isEmpty) return null;
    final bool Function(String) isDir =
        isDirectory ?? ((String p) => FileSystemEntity.isDirectorySync(p));

    final List<String> files = <String>[];
    for (final String raw in paths) {
      final String p = raw.trim();
      if (p.isEmpty) continue;
      if (isDir(p)) {
        // 拖了目录：优先用它（多个目录只认第一个，避免「到底看哪个」的歧义）
        return DropResult(rootPath: p, fileCount: 0, fromDirectory: true);
      }
      files.add(p);
    }
    if (files.isEmpty) return null;
    final String first = files.first;
    final int cut = first.lastIndexOf(RegExp(r'[\\/]'));
    if (cut <= 0) return null;
    final String dir = first.substring(0, cut);
    return DropResult(rootPath: dir, fileCount: files.length, fromDirectory: false);
  }
}

/// 与 Windows 运行器之间的通道。
abstract final class DropChannel {
  static const MethodChannel channel =
      MethodChannel('com.dsh.musicorganizer/drop');

  /// 监听拖放；[onPaths] 收到的是全部拖入路径。
  ///
  /// 非 Windows 平台不会收到任何回调（通道没有对端，注册也安全）。
  static void listen(void Function(List<String> paths) onPaths) {
    channel.setMethodCallHandler((MethodCall call) async {
      if (call.method != 'onDrop') return null;
      final Object? args = call.arguments;
      final List<String> paths = <String>[];
      if (args is List) {
        for (final Object? e in args) {
          if (e is String && e.isNotEmpty) paths.add(e);
        }
      }
      if (paths.isNotEmpty) onPaths(paths);
      return null;
    });
  }
}
