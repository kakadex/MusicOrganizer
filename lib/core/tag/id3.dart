/// ID3v2.3 / v2.4 标签读写（纯手写实现）。
///
/// 读取：解析文本帧 TIT2/TPE1/TPE2/TALB/TYER/TDRC/TRCK/TCON/COMM/USLT。
/// 写入：保留不认识的帧（含封面 APIC），重写目标字段后生成新标签头部 —— 合并语义。
library;

import 'dart:convert';
import 'dart:typed_data';

import '../model/tags.dart';
import 'cover_art.dart';
import 'tag_text.dart';

/// ID3v2 标签读写（纯 Dart，工作在内存字节上）。
abstract final class Id3 {
  static const Map<String, String> readFields = <String, String>{
    'TIT2': 'title',
    'TPE1': 'artist',
    'TPE2': 'artist',
    'TALB': 'album',
    'TYER': 'year',
    'TDRC': 'year',
    'TRCK': 'track',
    'TCON': 'genre',
    'COMM': 'comment',
    'USLT': 'lyrics',
  };

  static const Map<String, List<String>> fieldFrames = <String, List<String>>{
    'title': <String>['TIT2'],
    'artist': <String>['TPE1'],
    'album': <String>['TALB'],
    'year': <String>['TYER', 'TDRC'],
    'track': <String>['TRCK'],
    'genre': <String>['TCON'],
    'comment': <String>['COMM'],
    'lyrics': <String>['USLT'],
  };

  // ------------------------------------------------------------------
  // 读取
  // ------------------------------------------------------------------

  static Tags read(Uint8List data) => readAt(data, 0);

  /// 从 [offset] 处开始解析 ID3v2（DSF 的 metadata 块在文件中部/尾部）。
  static Tags readAt(Uint8List data, int offset) {
    final Tags tags = Tags();
    try {
      if (offset + 10 > data.length) return tags;
      if (data[offset] != 0x49 ||
          data[offset + 1] != 0x44 ||
          data[offset + 2] != 0x33) {
        return tags;
      }
      final int version = data[offset + 3];
      final int flags = data[offset + 5];
      final int size = _syncsafe(data, offset + 6);
      final int tagEnd = offset + 10 + size + ((flags & 0x10) != 0 ? 10 : 0);
      int pos = offset + 10;
      if ((flags & 0x40) != 0) {
        final int extSize =
            version >= 4 ? _syncsafe(data, pos) : _be32(data, pos);
        pos = offset + 10 + 4 + extSize;
      }
      if ((flags & 0x80) != 0) {
        return _readUnsynchronized(data, pos, tagEnd, version);
      }
      while (pos + 10 <= tagEnd) {
        if (data[pos] == 0) break;
        final String id = _ascii(data, pos, 4);
        int frameSize =
            version >= 4 ? _syncsafe(data, pos + 4) : _be32(data, pos + 4);
        if (frameSize <= 0 || pos + 10 + frameSize > tagEnd) {
          if (version >= 4) {
            final int alt = _be32(data, pos + 4);
            if (alt > 0 && pos + 10 + alt <= tagEnd) {
              frameSize = alt;
            } else {
              break;
            }
          } else {
            break;
          }
        }
        _applyFrame(tags, id, Uint8List.sublistView(data, pos + 10, pos + 10 + frameSize));
        pos += 10 + frameSize;
      }
    } catch (_) {}
    return tags;
  }

  static Tags _readUnsynchronized(
      Uint8List data, int pos, int tagEnd, int version) {
    final Tags tags = Tags();
    final Uint8List whole = Uint8List.sublistView(data, pos, tagEnd);
    final BytesBuilder out = BytesBuilder();
    for (int i = 0; i < whole.length; i++) {
      out.addByte(whole[i]);
      if (whole[i] == 0xFF && i + 1 < whole.length && whole[i + 1] == 0) i++;
    }
    final Uint8List d = out.toBytes();
    int p = 0;
    while (p + 10 <= d.length) {
      if (d[p] == 0) break;
      final String id = _ascii(d, p, 4);
      final int frameSize = version >= 4 ? _syncsafe(d, p + 4) : _be32(d, p + 4);
      if (frameSize <= 0 || p + 10 + frameSize > d.length) break;
      _applyFrame(tags, id, Uint8List.sublistView(d, p + 10, p + 10 + frameSize));
      p += 10 + frameSize;
    }
    return tags;
  }

  static void _applyFrame(Tags tags, String id, Uint8List data) {
    if (id == 'SYLT') {
      if (tags.get('lyrics').isEmpty) {
        final String sylt = decodeSylt(data);
        if (sylt.isNotEmpty) tags.put('lyrics', sylt);
      }
      return;
    }
    if (id == 'TXXX') {
      if (tags.get('lyrics').isEmpty && data.length > 1) {
        final int enc = data[0];
        final (String desc, int pos) = _readTerminated(data, 1, enc);
        if (desc.toUpperCase().contains('LYRIC')) {
          final int start = pos < data.length ? pos : data.length;
          final Uint8List payload = Uint8List.sublistView(data, start);
          final String value = _stripNul(decodePayload(payload, enc)).trim();
          if (value.isNotEmpty) tags.put('lyrics', value);
        }
      }
      return;
    }
    final String? field = readFields[id];
    if (field == null) return;
    if (id == 'COMM' || id == 'USLT') {
      tags.put(field, _decodeComm(data));
    } else if (id == 'TPE2') {
      if (tags.get('artist').isEmpty) tags.put('artist', _decodeText(data));
    } else {
      final String v = _decodeText(data);
      if (v.isNotEmpty) tags.put(field, v);
    }
  }

  /// 解析 SYLT（同步歌词）→ `[mm:ss.xx]文本`。
  static String decodeSylt(Uint8List data) {
    if (data.length < 6) return '';
    final int enc = data[0];
    final (_, int afterDesc) = _readTerminated(data, 6, enc);
    int p = afterDesc;
    final StringBuffer out = StringBuffer();
    while (p + 4 <= data.length) {
      final (String text, int np) = _readTerminated(data, p, enc);
      p = np;
      if (p + 4 > data.length) break;
      final int ms = (data[p] << 24) | (data[p + 1] << 16) | (data[p + 2] << 8) | data[p + 3];
      p += 4;
      if (text.trim().isEmpty) continue;
      final int totalSeconds = ms ~/ 1000;
      if (out.isNotEmpty) out.write('\n');
      final int m = totalSeconds ~/ 60;
      final int s = totalSeconds % 60;
      final int cs = (ms % 1000) ~/ 10;
      out.write('[${m.toString().padLeft(2, '0')}:'
          '${s.toString().padLeft(2, '0')}.'
          '${cs.toString().padLeft(2, '0')}]${text.trim()}');
    }
    return out.toString();
  }

  /// 按编码读一个以 NUL 结尾的字符串，返回 (文本, 新位置)。
  static (String, int) _readTerminated(Uint8List data, int start, int enc) {
    int p = start;
    if (enc == 1 || enc == 2) {
      while (p + 1 < data.length) {
        if (data[p] == 0 && data[p + 1] == 0) break;
        p += 2;
      }
      final int end = p < data.length ? p : data.length;
      final String text =
          _stripNul(decodePayload(Uint8List.sublistView(data, start, end), enc));
      return (text, (end + 2) < data.length ? end + 2 : data.length);
    }
    while (p < data.length && data[p] != 0) {
      p++;
    }
    final String text =
        _stripNul(decodePayload(Uint8List.sublistView(data, start, p), enc));
    return (text, (p + 1) < data.length ? p + 1 : data.length);
  }

  static String _decodeText(Uint8List data) {
    if (data.isEmpty) return '';
    final int enc = data[0];
    return _stripNul(decodePayload(Uint8List.sublistView(data, 1), enc)).trim();
  }

  static String _decodeComm(Uint8List data) {
    if (data.length < 4) return '';
    final int enc = data[0];
    int p = 4;
    while (p < data.length) {
      if (enc == 1 || enc == 2) {
        if (p + 1 < data.length && data[p] == 0 && data[p + 1] == 0) {
          p += 2;
          break;
        }
        p += 2;
      } else {
        if (data[p] == 0) {
          p += 1;
          break;
        }
        p += 1;
      }
    }
    if (p >= data.length) return '';
    return _stripNul(decodePayload(Uint8List.sublistView(data, p), enc)).trim();
  }

  static String decodePayload(Uint8List payload, int enc) {
    switch (enc) {
      case 0:
        return TagText.decodeLatin1OrGbk(payload);
      case 1:
        if (payload.length >= 2 && payload[0] == 0xFE && payload[1] == 0xFF) {
          return _utf16(Uint8List.sublistView(payload, 2), littleEndian: false);
        }
        if (payload.length >= 2 && payload[0] == 0xFF && payload[1] == 0xFE) {
          return _utf16(Uint8List.sublistView(payload, 2), littleEndian: true);
        }
        return _utf16(payload, littleEndian: true);
      case 2:
        return _utf16(payload, littleEndian: false);
      case 3:
        return TagText.decodeUtf8(payload);
      default:
        return TagText.decodeLatin1OrGbk(payload);
    }
  }

  /// encoding=0（ISO-8859-1）文本帧的解码（保留同名入口，供 TagHeadTest 用）。
  static String decodeLatin1OrGbk(Uint8List payload) =>
      TagText.decodeLatin1OrGbk(payload);

  static String _utf16(Uint8List b, {required bool littleEndian}) {
    final StringBuffer sb = StringBuffer();
    for (int i = 0; i + 1 < b.length; i += 2) {
      final int cu =
          littleEndian ? (b[i] | (b[i + 1] << 8)) : ((b[i] << 8) | b[i + 1]);
      sb.writeCharCode(cu);
    }
    return sb.toString();
  }

  static String _stripNul(String s) => TagText.stripNul(s);

  // ------------------------------------------------------------------
  // 写入
  // ------------------------------------------------------------------

  /// 只构造 ID3v2.3 标签字节（头 + 帧 + 512 字节填充）。
  static Uint8List buildTag(Map<String, String> values, {Uint8List? cover}) {
    final Uint8List frameBytes =
        _buildFrames(3, values, cover, const <Uint8List>[]);
    final int pad = 512;
    final int tagSize = frameBytes.length + pad;
    final Uint8List head = Uint8List(10);
    head[0] = 0x49;
    head[1] = 0x44;
    head[2] = 0x33;
    head[3] = 3;
    head[4] = 0;
    head[5] = 0;
    _writeSyncsafe(head, 6, tagSize);
    final BytesBuilder out = BytesBuilder();
    out.add(head);
    out.add(frameBytes);
    out.add(Uint8List(pad));
    return out.toBytes();
  }

  /// 写入字段（合并语义）；返回新文件字节。cover: null=不动 / 空=删除 / 非空=替换。
  static Uint8List rewrite(Uint8List data, Map<String, String> values,
      {Uint8List? cover}) {
    int version = 3;
    int audioStart = 0;
    final List<Uint8List> preserved = <Uint8List>[];
    final Set<String> replaceIds = <String>{};
    for (final String key in values.keys) {
      final List<String>? ids = fieldFrames[key];
      if (ids != null) {
        for (final String id in ids) {
          replaceIds.add(id);
        }
      }
    }
    if (cover != null) replaceIds.add('APIC');

    if (data.length >= 10 &&
        data[0] == 0x49 &&
        data[1] == 0x44 &&
        data[2] == 0x33) {
      version = data[3];
      if (version < 3 || version > 4) version = 3;
      final int flags = data[5];
      final int size = _syncsafe(data, 6);
      final int tagEnd = 10 + size + ((flags & 0x10) != 0 ? 10 : 0);
      audioStart = tagEnd;
      int pos = 10;
      if ((flags & 0x40) != 0) {
        final int extSize =
            version >= 4 ? _syncsafe(data, pos) : _be32(data, pos);
        pos = 10 + 4 + extSize;
      }
      while (pos + 10 <= tagEnd) {
        if (data[pos] == 0) break;
        final String id = _ascii(data, pos, 4);
        int frameSize =
            version >= 4 ? _syncsafe(data, pos + 4) : _be32(data, pos + 4);
        if (frameSize <= 0 || pos + 10 + frameSize > tagEnd) {
          if (version >= 4) {
            final int alt = _be32(data, pos + 4);
            if (alt > 0 && pos + 10 + alt <= tagEnd) {
              frameSize = alt;
            } else {
              break;
            }
          } else {
            break;
          }
        }
        if (!replaceIds.contains(id)) {
          final Uint8List frame = Uint8List(10 + frameSize);
          frame.setRange(0, 10, data, pos);
          frame.setRange(10, 10 + frameSize, data, pos + 10);
          preserved.add(frame);
        }
        pos += 10 + frameSize;
      }
    }

    final Uint8List frameBytes = _buildFrames(version, values, cover, preserved);
    final int pad = 512;
    final int tagSize = frameBytes.length + pad;
    final Uint8List head = Uint8List(10);
    head[0] = 0x49;
    head[1] = 0x44;
    head[2] = 0x33;
    head[3] = version;
    head[4] = 0;
    head[5] = 0;
    _writeSyncsafe(head, 6, tagSize);
    final BytesBuilder out = BytesBuilder();
    out.add(head);
    out.add(frameBytes);
    out.add(Uint8List(pad));
    final int start = audioStart < data.length ? audioStart : data.length;
    out.add(Uint8List.sublistView(data, start));
    return out.toBytes();
  }

  static Uint8List _buildFrames(int version, Map<String, String> values,
      Uint8List? cover, List<Uint8List> preserved) {
    final BytesBuilder frames = BytesBuilder();
    final String yearId = version >= 4 ? 'TDRC' : 'TYER';
    if (values.containsKey('title')) {
      _putTextFrame(frames, version, 'TIT2', _orEmpty(values['title']));
    }
    if (values.containsKey('artist')) {
      _putTextFrame(frames, version, 'TPE1', _orEmpty(values['artist']));
    }
    if (values.containsKey('album')) {
      _putTextFrame(frames, version, 'TALB', _orEmpty(values['album']));
    }
    if (values.containsKey('year')) {
      _putTextFrame(frames, version, yearId, _orEmpty(values['year']));
    }
    if (values.containsKey('track')) {
      _putTextFrame(frames, version, 'TRCK', _orEmpty(values['track']));
    }
    if (values.containsKey('genre')) {
      _putTextFrame(frames, version, 'TCON', _orEmpty(values['genre']));
    }
    if (values.containsKey('comment')) {
      _putCommFrame(frames, version, _orEmpty(values['comment']));
    }
    if (values.containsKey('lyrics')) {
      _putUsltFrame(frames, version, _orEmpty(values['lyrics']));
    }
    if (cover != null && cover.isNotEmpty) {
      _putApicFrame(frames, version, cover);
    }
    for (final Uint8List raw in preserved) {
      frames.add(raw);
    }
    return frames.toBytes();
  }

  static String _orEmpty(String? s) => s == null ? '' : s.trim();

  static void _putTextFrame(
      BytesBuilder out, int version, String id, String value) {
    final Uint8List text;
    final int enc;
    if (version >= 4) {
      enc = 3;
      text = Uint8List.fromList(utf8.encode(value));
    } else {
      enc = 1;
      final Uint8List body = _utf16le(value);
      text = Uint8List(body.length + 2);
      text[0] = 0xFF;
      text[1] = 0xFE;
      text.setRange(2, 2 + body.length, body);
    }
    final Uint8List data = Uint8List(1 + text.length);
    data[0] = enc;
    data.setRange(1, 1 + text.length, text);
    _writeFrame(out, version, id, data);
  }

  static void _putCommFrame(BytesBuilder out, int version, String value) {
    final int enc = version >= 4 ? 3 : 1;
    final BytesBuilder data = BytesBuilder();
    data.addByte(enc);
    data.add(<int>[0x65, 0x6E, 0x67]); // 'eng'
    if (version >= 4) {
      data.addByte(0);
      data.add(utf8.encode(value));
    } else {
      data.addByte(0);
      data.addByte(0);
      data.add(<int>[0xFF, 0xFE]);
      data.add(_utf16le(value));
    }
    _writeFrame(out, version, 'COMM', data.toBytes());
  }

  static void _putUsltFrame(BytesBuilder out, int version, String value) {
    if (value.trim().isEmpty) return; // 空值 = 清除歌词帧
    final BytesBuilder data = BytesBuilder();
    if (version >= 4) {
      data.addByte(3);
      data.add(<int>[0x63, 0x68, 0x69]); // 'chi'
      data.addByte(0);
      data.add(utf8.encode(value));
    } else {
      data.addByte(1);
      data.add(<int>[0x63, 0x68, 0x69]);
      data.addByte(0);
      data.addByte(0);
      data.add(<int>[0xFF, 0xFE]);
      data.add(_utf16le(value));
    }
    _writeFrame(out, version, 'USLT', data.toBytes());
  }

  static void _putApicFrame(BytesBuilder out, int version, Uint8List image) {
    final String mime = CoverArt.mimeOf(image);
    if (mime.isEmpty) return;
    final BytesBuilder data = BytesBuilder();
    data.addByte(0);
    data.add(asciiBytes(mime));
    data.addByte(0);
    data.addByte(3); // front cover
    data.addByte(0);
    data.add(image);
    _writeFrame(out, version, 'APIC', data.toBytes());
  }

  static bool hasCover(Uint8List data) {
    try {
      if (data.length < 10 ||
          data[0] != 0x49 ||
          data[1] != 0x44 ||
          data[2] != 0x33) {
        return false;
      }
      final int version = data[3];
      final int flags = data[5];
      final int size = _syncsafe(data, 6);
      final int tagEnd = 10 + size + ((flags & 0x10) != 0 ? 10 : 0);
      int pos = 10;
      if ((flags & 0x40) != 0) {
        final int extSize =
            version >= 4 ? _syncsafe(data, pos) : _be32(data, pos);
        pos = 10 + 4 + extSize;
      }
      while (pos + 10 <= tagEnd) {
        if (data[pos] == 0) break;
        final String id = _ascii(data, pos, 4);
        final int frameSize =
            version >= 4 ? _syncsafe(data, pos + 4) : _be32(data, pos + 4);
        if (frameSize <= 0 || pos + 10 + frameSize > tagEnd) break;
        if (id == 'APIC') return true;
        pos += 10 + frameSize;
      }
    } catch (_) {}
    return false;
  }

  static void _writeFrame(
      BytesBuilder out, int version, String id, Uint8List data) {
    if (data.isEmpty) return;
    out.add(asciiBytes(id));
    final Uint8List size = Uint8List(4);
    if (version >= 4) {
      _writeSyncsafe(size, 0, data.length);
    } else {
      _writeBe32(size, 0, data.length);
    }
    out.add(size);
    out.add(<int>[0, 0]);
    out.add(data);
  }

  // ------------------------------------------------------------------
  // 位工具
  // ------------------------------------------------------------------

  static int _syncsafe(Uint8List b, int off) =>
      ((b[off] & 0x7F) << 21) |
      ((b[off + 1] & 0x7F) << 14) |
      ((b[off + 2] & 0x7F) << 7) |
      (b[off + 3] & 0x7F);

  static int _be32(Uint8List b, int off) =>
      (b[off] << 24) | (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3];

  static void _writeSyncsafe(Uint8List b, int off, int value) {
    b[off] = (value >> 21) & 0x7F;
    b[off + 1] = (value >> 14) & 0x7F;
    b[off + 2] = (value >> 7) & 0x7F;
    b[off + 3] = value & 0x7F;
  }

  static void _writeBe32(Uint8List b, int off, int value) {
    b[off] = (value >> 24) & 0xFF;
    b[off + 1] = (value >> 16) & 0xFF;
    b[off + 2] = (value >> 8) & 0xFF;
    b[off + 3] = value & 0xFF;
  }

  static Uint8List _utf16le(String s) {
    final Uint8List out = Uint8List(s.length * 2);
    for (int i = 0; i < s.length; i++) {
      final int cu = s.codeUnitAt(i);
      out[i * 2] = cu & 0xFF;
      out[i * 2 + 1] = (cu >> 8) & 0xFF;
    }
    return out;
  }

  static String _ascii(Uint8List b, int off, int len) {
    final StringBuffer sb = StringBuffer();
    for (int i = 0; i < len; i++) {
      final int c = b[off + i];
      if (c < 32 || c > 126) return sb.length >= 2 ? sb.toString() : '';
      sb.writeCharCode(c);
    }
    return sb.toString();
  }

  static Uint8List asciiBytes(String s) => Uint8List.fromList(s.codeUnits);
}
