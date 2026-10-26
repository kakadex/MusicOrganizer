/// 从文件系统取内容样本（大小 + 首尾各 64KB）。
library;

import 'dart:typed_data';

import '../fs/file_store.dart';
import '../model/vfile.dart';
import 'content_sample.dart';

/// 内容采样器：只读首尾各 64KB，不整文件读入。
abstract final class ContentReader {
  /// 单侧采样字节数。
  static const int sampleBytes = 64 * 1024;

  /// 取一个文件的内容样本；读不到返回 null（不抛）。
  static Future<ContentSample?> sample(FileStore st, VFile f) async {
    try {
      final Uint8List head = await st.headBytes(f, sampleBytes);
      final Uint8List tail = await st.tailBytes(f, sampleBytes);
      return ContentSample(f.size, head, tail);
    } catch (_) {
      return null;
    }
  }
}
