/// 同名 .lrc 的落盘：与音频同目录、同主名，先找已有文件再新建。
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../core/fs/file_store.dart';
import '../../core/fs/raw_write.dart';
import '../../core/model/vfile.dart';
import 'lyrics_logic.dart';

/// .lrc 写入（纯工具）。
abstract final class LyricLrcWriter {
  /// 写入成功返回空串，失败返回原因。
  static Future<String> write(
      FileStore store, VFile file, String text) async {
    try {
      final String? parentId = file.parentId;
      final VFile? dir = parentId == null ? null : await store.stat(parentId);
      if (dir == null) return '找不到文件所在目录';
      final VFile target = await RawWrite.ensureFile(
          store, dir, LyricPick.lrcName(file), 'text/plain');
      await RawWrite.bytes(store, target, Uint8List.fromList(utf8.encode(text)));
      return '';
    } catch (e) {
      return '$e';
    }
  }
}
