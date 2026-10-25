/// DSF（DSD Stream File）标签读写 —— 移植自旧 core/Dsf.java。
///
/// 布局：DSD chunk(28B) → fmt chunk(52B) → data chunk → metadata（裸 ID3v2，无 'ID3 ' 包装，
/// 位置由 DSD chunk 的 metadataPointer 绝对偏移指定）。读写复用 Id3。
library;

import 'dart:typed_data';

import '../model/tags.dart';
import 'id3.dart';

/// DSF 标签读写（纯 Dart）。
abstract final class Dsf {
  static bool isDsf(Uint8List data) =>
      data.length >= 4 &&
      data[0] == 0x44 &&
      data[1] == 0x53 &&
      data[2] == 0x44 &&
      data[3] == 0x20;

  static Tags read(Uint8List data) {
    final Tags tags = Tags();
    if (!isDsf(data)) return tags;
    final int pointer = _readPointer(data);
    if (pointer <= 0 || pointer + 10 > data.length) return tags;
    return Id3.readAt(data, pointer);
  }

  /// 时长（秒）：sampleCount / samplingFrequency。
  static double durationSeconds(Uint8List data) {
    if (data.length < 80 ||
        !(data[0] == 0x44 && data[1] == 0x53 && data[2] == 0x44 && data[3] == 0x20)) {
      return 0;
    }
    if (!(data[28] == 0x66 && data[29] == 0x6D && data[30] == 0x74 && data[31] == 0x20)) {
      return 0;
    }
    final int sampleCount = _le64(data, 40 + 24);
    final int freq = _le32(data, 40 + 16);
    if (sampleCount <= 0 || freq <= 0) return 0;
    return sampleCount / freq;
  }

  /// 重写标签。cover: null=不动 / 空=删除 / 非空=写入。返回新文件字节。
  static Uint8List rewrite(Uint8List data, Map<String, String> values,
      {Uint8List? cover}) {
    if (!isDsf(data)) throw const FormatException('文件不是有效的 DSF');
    if (data.length < 52) throw const FormatException('DSF 文件过短');
    if (!(data[28] == 0x66 && data[29] == 0x6D && data[30] == 0x74 && data[31] == 0x20)) {
      throw const FormatException('DSF fmt chunk 缺失');
    }
    final int fmtSize = _le64(data, 32);
    if (fmtSize < 52) throw const FormatException('DSF fmt chunk 大小异常');
    final int dataHeadPos = 28 + fmtSize;
    if (!(data[dataHeadPos] == 0x64 &&
        data[dataHeadPos + 1] == 0x61 &&
        data[dataHeadPos + 2] == 0x74 &&
        data[dataHeadPos + 3] == 0x61)) {
      throw const FormatException('DSF data chunk 缺失');
    }
    final int dataSize = _le64(data, dataHeadPos + 4) - 12;
    if (dataSize < 0) throw const FormatException('DSF data chunk 大小异常');

    final Uint8List newTag = Id3.buildTag(values, cover: cover);
    final int audioStart = dataHeadPos + 12;
    final int metadataOffset = audioStart + dataSize;
    final int total = metadataOffset + newTag.length;

    final BytesBuilder out = BytesBuilder();
    final Uint8List dsdHead = Uint8List(28);
    dsdHead[0] = 0x44;
    dsdHead[1] = 0x53;
    dsdHead[2] = 0x44;
    dsdHead[3] = 0x20;
    _writeLe64(dsdHead, 4, 28);
    _writeLe64(dsdHead, 12, total);
    _writeLe64(dsdHead, 20, metadataOffset);
    out.add(dsdHead);
    out.add(Uint8List.sublistView(data, 28, 28 + fmtSize));
    final Uint8List dataHead = Uint8List(12);
    dataHead[0] = 0x64;
    dataHead[1] = 0x61;
    dataHead[2] = 0x74;
    dataHead[3] = 0x61;
    _writeLe64(dataHead, 4, 12 + dataSize);
    out.add(dataHead);
    out.add(Uint8List.sublistView(data, audioStart, audioStart + dataSize));
    out.add(newTag);
    return out.toBytes();
  }

  static bool hasCover(Uint8List data) {
    if (!isDsf(data)) return false;
    final int pointer = _readPointer(data);
    if (pointer <= 0 || pointer + 10 > data.length) return false;
    return Id3.hasCover(Uint8List.sublistView(data, pointer));
  }

  static int _readPointer(Uint8List data) {
    if (!(data[0] == 0x44 && data[1] == 0x53 && data[2] == 0x44 && data[3] == 0x20)) {
      return -1;
    }
    return _le64(data, 20);
  }

  static int _le64(Uint8List b, int off) {
    int v = 0;
    for (int i = 7; i >= 0; i--) {
      v = (v << 8) | b[off + i];
    }
    return v;
  }

  static int _le32(Uint8List b, int off) =>
      b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24);

  static void _writeLe64(Uint8List b, int off, int value) {
    for (int i = 0; i < 8; i++) {
      b[off + i] = (value >> (i * 8)) & 0xFF;
    }
  }
}
