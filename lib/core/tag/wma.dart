/// WMA（ASF 容器）标签**只读**解析。
///
/// 只读不写：ASF 头对象大小字段与内部对象长度层层嵌套，改标签要重排整段头部。
library;

import 'dart:typed_data';

import '../model/tags.dart';

/// WMA 只读标签解析（纯 Dart）。
abstract final class Wma {
  static final Uint8List _guidHeader = Uint8List.fromList(<int>[
    0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11,
    0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C,
  ]);
  static final Uint8List _guidContent = Uint8List.fromList(<int>[
    0x33, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11,
    0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C,
  ]);
  static final Uint8List _guidExtContent = Uint8List.fromList(<int>[
    0x40, 0xA4, 0xD0, 0xD2, 0x07, 0xE3, 0xD2, 0x11,
    0x97, 0xF0, 0x00, 0xA0, 0xC9, 0x5E, 0xA8, 0x50,
  ]);

  static bool isWma(Uint8List data) => _hasPrefix(data, _guidHeader);

  static Tags read(Uint8List data) {
    final Tags tags = Tags();
    if (!isWma(data)) return tags;
    final Map<String, String> map = <String, String>{};
    if (data.length < 30) return tags;
    final int headerSize = _le64(data, 16);
    final int count = _le32(data, 24);
    int pos = 30;
    final int limit = data.length < headerSize ? data.length : headerSize;
    for (int i = 0; i < count && pos + 24 <= limit; i++) {
      final int objSize = _le64(data, pos + 16);
      if (objSize < 24 || pos + objSize > limit) break;
      final int dataStart = pos + 24;
      final int dataLen = objSize - 24;
      if (_startsWithAt(data, pos, _guidContent)) {
        _readContentDescription(data, dataStart, dataLen, map);
      } else if (_startsWithAt(data, pos, _guidExtContent)) {
        _readExtendedContent(data, dataStart, dataLen, map);
      }
      pos += objSize;
    }
    _put(tags, map, 'title', 'title');
    _put(tags, map, 'artist', 'author');
    _put(tags, map, 'album', 'wm/albumtitle');
    _put(tags, map, 'year', 'wm/year');
    _put(tags, map, 'track', 'wm/tracknumber');
    _put(tags, map, 'genre', 'wm/genre');
    _put(tags, map, 'comment', 'description');
    _put(tags, map, 'lyrics', 'wm/lyrics');
    return tags;
  }

  static void _put(
      Tags tags, Map<String, String> map, String field, String key) {
    final String? v = map[key];
    if (v != null && v.trim().isNotEmpty) tags.put(field, v.trim());
  }

  static void _readContentDescription(
      Uint8List buf, int start, int len, Map<String, String> out) {
    if (len < 10) return;
    final List<int> sizes = <int>[];
    for (int i = 0; i < 5; i++) {
      sizes.add((buf[start + i * 2] | (buf[start + i * 2 + 1] << 8)));
    }
    int pos = start + 10;
    const List<String> keys = <String>[
      'title', 'author', 'copyright', 'description', 'rating'
    ];
    for (int i = 0; i < 5; i++) {
      final int n = sizes[i];
      if (n <= 0 || pos + n > start + len) continue;
      final String v = _utf16(buf, pos, n);
      pos += n;
      if (v.isNotEmpty) out.putIfAbsent(keys[i], () => v);
    }
  }

  static void _readExtendedContent(
      Uint8List buf, int start, int len, Map<String, String> out) {
    if (len < 2) return;
    final int count = buf[start] | (buf[start + 1] << 8);
    int pos = start + 2;
    final int end = start + len;
    for (int i = 0; i < count && pos + 2 <= end; i++) {
      final int nameLen = buf[pos] | (buf[pos + 1] << 8);
      pos += 2;
      if (nameLen <= 0 || pos + nameLen + 4 > end) break;
      final String name = _utf16(buf, pos, nameLen).toLowerCase();
      pos += nameLen;
      final int type = buf[pos] | (buf[pos + 1] << 8);
      final int valueLen = buf[pos + 2] | (buf[pos + 3] << 8);
      pos += 4;
      if (valueLen < 0 || pos + valueLen > end) break;
      String value;
      if (type == 0) {
        value = _utf16(buf, pos, valueLen);
      } else if (type == 3 && valueLen >= 4) {
        value = '${_le32(buf, pos)}';
      } else if (type == 5 && valueLen >= 2) {
        value = '${buf[pos] | (buf[pos + 1] << 8)}';
      } else if (type == 4 && valueLen >= 8) {
        value = '${_le64(buf, pos)}';
      } else {
        value = '';
      }
      pos += valueLen;
      if (value.isNotEmpty) out.putIfAbsent(name, () => value);
    }
  }

  static String _utf16(Uint8List buf, int off, int len) {
    final StringBuffer sb = StringBuffer();
    for (int i = 0; i + 1 < len; i += 2) {
      final int cu = buf[off + i] | (buf[off + i + 1] << 8);
      if (cu == 0) break;
      sb.writeCharCode(cu);
    }
    return sb.toString();
  }

  /// UTF-16LE 编码（长度补齐为偶数）；回归测试造样本也用同一编码。
  static Uint8List utf16Bytes(String s) {
    final Uint8List out = Uint8List(s.length * 2);
    for (int i = 0; i < s.length; i++) {
      final int cu = s.codeUnitAt(i);
      out[i * 2] = cu & 0xFF;
      out[i * 2 + 1] = (cu >> 8) & 0xFF;
    }
    return out;
  }

  static bool _hasPrefix(Uint8List data, Uint8List prefix) {
    if (data.length < prefix.length) return false;
    return _startsWithAt(data, 0, prefix);
  }

  static bool _startsWithAt(Uint8List buf, int off, Uint8List prefix) {
    if (off + prefix.length > buf.length) return false;
    for (int i = 0; i < prefix.length; i++) {
      if (buf[off + i] != prefix[i]) return false;
    }
    return true;
  }

  static int _le32(Uint8List b, int off) =>
      b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24);

  static int _le64(Uint8List b, int off) {
    int v = 0;
    for (int i = 7; i >= 0; i--) {
      v = (v << 8) | b[off + i];
    }
    return v;
  }
}
