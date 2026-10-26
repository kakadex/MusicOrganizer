/// WAV（RIFF/WAVE）标签读写。
///
/// 读取优先 ID3（文件尾 `id3 ` 块），没有才退 LIST/INFO；写入统一写 ID3 块并清旧 INFO。
/// 所有 chunk 小端长度；奇数长度要补 1 字节对齐。
library;

import 'dart:typed_data';

import '../model/tags.dart';
import 'id3.dart';
import 'tag_text.dart';

class _Chunk {
  String id = '';
  int headerOffset = 0;
  int dataOffset = 0;
  int size = 0;
  bool infoMarker = false;

  bool isId3() => id.toLowerCase() == 'id3 ';
  bool isInfoList() => id == 'LIST' && infoMarker;
}

/// WAV 标签读写（纯 Dart）。
abstract final class Wav {
  static bool isWav(Uint8List data) =>
      data.length >= 12 &&
      data[0] == 0x52 &&
      data[1] == 0x49 &&
      data[2] == 0x46 &&
      data[3] == 0x46 &&
      data[8] == 0x57 &&
      data[9] == 0x41 &&
      data[10] == 0x56 &&
      data[11] == 0x45;

  static Tags read(Uint8List data) {
    final Tags tags = Tags();
    if (!isWav(data)) return tags;
    final List<_Chunk> chunks = _chunks(data);
    _Chunk? id3;
    _Chunk? info;
    for (final _Chunk c in chunks) {
      if (c.isId3()) {
        id3 = c;
      } else if (c.isInfoList()) {
        info = c;
      }
    }
    if (id3 != null) {
      final Uint8List id3Bytes =
          Uint8List.sublistView(data, id3.dataOffset, id3.dataOffset + id3.size);
      final Tags fromId3 = Id3.read(id3Bytes);
      if (fromId3.anyValue()) return fromId3;
    }
    if (info != null) _readInfo(data, info, tags);
    return tags;
  }

  /// 写标签：清掉旧 ID3 / INFO 块，在文件尾重新挂一个 ID3v2.3 块。
  static Uint8List rewrite(Uint8List data, Map<String, String> values,
      {Uint8List? cover}) {
    if (!isWav(data)) throw const FormatException('不是有效的 WAV 文件');
    final Uint8List tag = Id3.buildTag(values,
        cover: (cover == null || cover.isEmpty) ? null : cover);
    final List<_Chunk> chunks = _chunks(data);
    final BytesBuilder out = BytesBuilder();
    out.add(<int>[0x52, 0x49, 0x46, 0x46]);
    out.add(<int>[0, 0, 0, 0]);
    out.add(<int>[0x57, 0x41, 0x56, 0x45]);
    for (final _Chunk c in chunks) {
      if (c.isId3() || c.isInfoList()) continue;
      final int end = c.headerOffset + 8 + c.size + (c.size & 1);
      out.add(Uint8List.sublistView(data, c.headerOffset, end));
    }
    out.add(<int>[0x69, 0x64, 0x33, 0x20]); // 'id3 '
    out.add(_le32(tag.length));
    out.add(tag);
    if ((tag.length & 1) == 1) out.addByte(0);
    final Uint8List body = out.toBytes();
    final int riffSize = body.length - 8;
    body[4] = riffSize & 0xFF;
    body[5] = (riffSize >> 8) & 0xFF;
    body[6] = (riffSize >> 16) & 0xFF;
    body[7] = (riffSize >> 24) & 0xFF;
    return body;
  }

  static void _readInfo(Uint8List data, _Chunk list, Tags tags) {
    final int end = list.dataOffset + list.size;
    int pos = list.dataOffset + 4;
    while (pos + 8 <= end) {
      final String id = String.fromCharCodes(data.sublist(pos, pos + 4));
      final int size = _u32(data, pos + 4);
      final int dataPos = pos + 8;
      if (size < 0 || dataPos + size > end) break;
      final String value =
          _decodeText(Uint8List.sublistView(data, dataPos, dataPos + size));
      if (value.isNotEmpty) {
        final String? key = _infoKey(id);
        if (key != null && tags.get(key).isEmpty) tags.put(key, value);
      }
      pos = dataPos + size + (size & 1);
    }
  }

  static String? _infoKey(String id) {
    if (id == 'INAM') return 'title';
    if (id == 'IART') return 'artist';
    if (id == 'IPRD') return 'album';
    if (id == 'ICRD') return 'year';
    if (id == 'IGNR') return 'genre';
    if (id == 'ITRK' || id == 'IPRT') return 'track';
    if (id == 'ICMT') return 'comment';
    return null;
  }

  static String _decodeText(Uint8List raw) {
    if (raw.isEmpty) return '';
    int len = raw.length;
    while (len > 0 && raw[len - 1] == 0) {
      len--;
    }
    if (len == 0) return '';
    return TagText.decodeUtf8(Uint8List.sublistView(raw, 0, len)).trim();
  }

  static List<_Chunk> _chunks(Uint8List data) {
    final List<_Chunk> out = <_Chunk>[];
    int pos = 12;
    while (pos + 8 <= data.length) {
      final _Chunk c = _Chunk();
      c.id = String.fromCharCodes(data.sublist(pos, pos + 4));
      c.size = _u32(data, pos + 4);
      c.headerOffset = pos;
      c.dataOffset = pos + 8;
      if (c.size < 0 || c.dataOffset + c.size > data.length) break;
      if (c.id == 'LIST' && c.size >= 4) {
        final Uint8List marker =
            Uint8List.sublistView(data, c.dataOffset, c.dataOffset + 4);
        c.infoMarker = marker[0] == 0x49 &&
            marker[1] == 0x4E &&
            marker[2] == 0x46 &&
            marker[3] == 0x4F;
      }
      out.add(c);
      pos = c.dataOffset + c.size + (c.size & 1);
    }
    return out;
  }

  static int _u32(Uint8List b, int off) =>
      b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24);

  static Uint8List _le32(int v) => Uint8List.fromList(<int>[
        v & 0xFF,
        (v >> 8) & 0xFF,
        (v >> 16) & 0xFF,
        (v >> 24) & 0xFF,
      ]);
}
