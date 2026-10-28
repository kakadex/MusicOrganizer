/// 从文件系统取内容样本（大小 + 首、中、尾各 64KB）。
library;

import 'dart:typed_data';

import '../fs/file_store.dart';
import '../model/vfile.dart';
import 'content_sample.dart';

/// 内容采样器：只读三小段，不整文件读入。
abstract final class ContentReader {
  /// 单侧采样字节数。
  static const int sampleBytes = 64 * 1024;

  /// 取一个文件的内容样本；读不到返回 null（不抛）。
  ///
  /// 中段要文件足够大才取（首尾已经把小文件盖完了），而且要落在首尾之外 ——
  /// 取不到也不算失败，样本退回首尾两段。
  static Future<ContentSample?> sample(FileStore st, VFile f) async {
    try {
      final Uint8List head = await st.headBytes(f, sampleBytes);
      final Uint8List tail = await st.tailBytes(f, sampleBytes);
      Uint8List? mid;
      final int need = sampleBytes * 3;
      if (f.size > need) {
        final int offset = (f.size - sampleBytes) ~/ 2;
        final Uint8List got = await st.rangeBytes(f, offset, sampleBytes);
        if (got.length == sampleBytes) mid = got;
      }
      return ContentSample(f.size, head, tail, mid: mid);
    } catch (_) {
      return null;
    }
  }
}
