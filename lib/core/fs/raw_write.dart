/// 非标签文件的原始字节写入（封面导出 / 同名 LRC）。
///
/// 标签写盘必须走 `TagTransaction`；这里只处理「附带的普通文件」：
/// 先写到本机缓存，再让 [FileStore] 覆盖目标文档（安卓也走同一通道）。
library;

import 'dart:io';
import 'dart:typed_data';

import '../model/vfile.dart';
import 'file_store.dart';
import 'temp_name.dart';

/// 原始字节写入工具。
abstract final class RawWrite {
  /// 目录下同名文件（忽略大小写）；没有就新建。
  static Future<VFile> ensureFile(
      FileStore store, VFile dir, String name, String mime) async {
    for (final VFile c in await store.children(dir)) {
      if (!c.dir && c.name.toLowerCase() == name.toLowerCase()) return c;
    }
    return store.createFile(dir, name, mime);
  }

  /// 用 [bytes] 覆盖 [target]；失败抛 [FileStoreException]。
  static Future<void> bytes(
      FileStore store, VFile target, Uint8List bytes) async {
    final File tmp = File('${Directory.systemTemp.path}'
        '${Platform.pathSeparator}${uniqueTempName('mo_raw_')}');
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      await store.writeFromLocal(target, tmp);
    } finally {
      try {
        await tmp.delete();
      } catch (_) {
        // 缓存文件删不掉不影响结果
      }
    }
  }
}
