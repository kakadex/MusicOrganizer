/// APEv2 标签读写 —— 移植自旧 core/Ape.java（Monkey's Audio / WavPack / Musepack 用同一套）。
///
/// 结构：键值项 + 32 字节 footer。footer 固定在文件尾（ID3v1 之前）。
/// tagSize 含 footer；写入保留文件末尾的 ID3v1。
library;

import 'dart:convert';
import 'dart:typed_data';

import '../model/tags.dart';

class _Item {
  Uint8List value = Uint8List(0);
  bool binary = false;

  _Item.text(String s) : value = Uint8List.fromList(utf8.encode(s));

  _Item.binary(Uint8List v)
      : value = v,
        binary = true;

  String text() => utf8.decode(value);
}

class _Loc {
  int tagStart = -1;
  int id3v1Start = 0;
}

/// APEv2 标签读写（纯 Dart）。
abstract final class Ape {
  static const int _footerSize = 32;
  static const int _flagHasHeader = 1 << 31;

  static const Map<String, String> _keys = <String, String>{
    'title': 'Title',
    'artist': 'Artist',
    'album': 'Album',
    'year': 'Year',
    'track': 'Track',
    'genre': 'Genre',
    'comment': 'Comment',
    'lyrics': 'Lyrics',
  };

  static bool isApe(Uint8List data) {
    if (data.length < 4) return false;
    return (data[0] == 0x4D && data[1] == 0x41 && data[2] == 0x43 && data[3] == 0x20) ||
        (data[0] == 0x77 && data[1] == 0x76 && data[2] == 0x70 && data[3] == 0x6B) ||
        (data[0] == 0x4D && data[1] == 0x50 && data[2] == 0x43 && data[3] == 0x4B);
  }

  static Tags read(Uint8List data) {
    final Tags tags = Tags();
    if (!isApe(data)) return tags;
    final Map<String, _Item>? root = _readItems(data);
    if (root == null) return tags;
    for (final MapEntry<String, _Item> e in root.entries) {
      final String? field = _fieldOf(e.key);
      if (field == null || e.value.binary) continue;
      final String value = e.value.text().trim();
      if (value.isNotEmpty && tags.get(field).isEmpty) tags.put(field, value);
    }
    return tags;
  }

  /// 读任意键（大小写不敏感，含自定义键）。
  static String readRaw(Uint8List data, String key) {
    final Map<String, _Item>? bag = _readItems(data);
    if (bag == null) return '';
    for (final MapEntry<String, _Item> e in bag.entries) {
      if (e.key.toLowerCase() == key.toLowerCase()) {
        return e.value.binary ? '' : e.value.text();
      }
    }
    return '';
  }

  static bool hasCover(Uint8List data) {
    final Map<String, _Item>? root = _readItems(data);
    if (root == null) return false;
    for (final MapEntry<String, _Item> e in root.entries) {
      if (e.key.toLowerCase().startsWith('cover art') && e.value.binary) {
        return true;
      }
    }
    return false;
  }

  /// 写入字段（合并语义）。cover: null=不动 / 空=删除 / 非空=替换。返回新文件字节。
  static Uint8List rewrite(Uint8List data, Map<String, String> values,
      {Uint8List? cover}) {
    if (!isApe(data)) {
      throw const FormatException('不是有效的 APE / WavPack / Musepack 文件');
    }
    final _Loc loc = _find(data);
    final int id3v1Start = loc.id3v1Start;
    final int audioEnd = loc.tagStart >= 0 ? loc.tagStart : id3v1Start;

    final Map<String, _Item> merged =
        _readItems(data) ?? <String, _Item>{};
    for (final MapEntry<String, String> e in values.entries) {
      final String? apexKey = _keys[e.key];
      if (apexKey == null) continue;
      _removeKeyIgnoreCase(merged, apexKey);
      String value = e.value;
      if (e.key != 'lyrics') value = value.trim();
      if (value.isNotEmpty) merged[apexKey] = _Item.text(value);
    }
    if (cover != null) {
      _removeCover(merged);
      if (cover.isNotEmpty) {
        merged['Cover Art (Front)'] = _Item.binary(_coverWithName(cover));
      }
    }
    final Uint8List tag = _buildTag(merged);

    final BytesBuilder out = BytesBuilder();
    out.add(Uint8List.sublistView(data, 0, audioEnd));
    out.add(tag);
    if (id3v1Start < data.length) {
      out.add(Uint8List.sublistView(data, id3v1Start, id3v1Start + 128));
    }
    return out.toBytes();
  }

  static Uint8List _coverWithName(Uint8List image) {
    final Uint8List name = Uint8List.fromList('cover.jpg'.codeUnits);
    final Uint8List out = Uint8List(name.length + 1 + image.length);
    out.setRange(0, name.length, name);
    out[name.length] = 0;
    out.setRange(name.length + 1, name.length + 1 + image.length, image);
    return out;
  }

  static void _removeKeyIgnoreCase(Map<String, _Item> map, String key) {
    final List<String> drop = <String>[];
    for (final String k in map.keys) {
      if (k.toLowerCase() == key.toLowerCase()) drop.add(k);
    }
    for (final String k in drop) {
      map.remove(k);
    }
  }

  static void _removeCover(Map<String, _Item> map) {
    final List<String> drop = <String>[];
    for (final String k in map.keys) {
      if (k.toLowerCase().startsWith('cover art')) drop.add(k);
    }
    for (final String k in drop) {
      map.remove(k);
    }
  }

  static String? _fieldOf(String key) {
    final String k = key.toLowerCase();
    for (final MapEntry<String, String> e in _keys.entries) {
      if (e.value.toLowerCase() == k) return e.key;
    }
    return null;
  }

  static Uint8List _buildTag(Map<String, _Item> items) {
    final BytesBuilder body = BytesBuilder();
    for (final MapEntry<String, _Item> e in items.entries) {
      final _Item it = e.value;
      final Uint8List key = Uint8List.fromList(e.key.codeUnits);
      body.add(_le32(it.value.length));
      body.add(_le32(it.binary ? 2 : 0));
      body.add(key);
      body.addByte(0);
      body.add(it.value);
    }
    final Uint8List itemsBytes = body.toBytes();
    final BytesBuilder out = BytesBuilder();
    out.add(itemsBytes);
    out.add(_footer(itemsBytes.length + _footerSize, items.length, 0));
    return out.toBytes();
  }

  static Uint8List _footer(int tagSize, int count, int flags) {
    final Uint8List f = Uint8List(_footerSize);
    f.setRange(0, 8, Uint8List.fromList('APETAGEX'.codeUnits));
    _putLe32(f, 8, 2000);
    _putLe32(f, 12, tagSize);
    _putLe32(f, 16, count);
    _putLe32(f, 20, flags);
    return f;
  }

  static _Loc _find(Uint8List data) {
    final _Loc loc = _Loc();
    final int len = data.length;
    loc.id3v1Start = _hasId3v1(data, len) ? len - 128 : len;
    final int searchEnd = loc.id3v1Start;
    if (searchEnd < _footerSize) return loc;
    final Uint8List tail =
        Uint8List.sublistView(data, searchEnd - _footerSize, searchEnd);
    if (!_isMagic(tail)) return loc;
    final int tagSize = _u32(tail, 12);
    final int flags = _u32(tail, 20);
    final bool hasHeader = (flags & _flagHasHeader) != 0;
    final int start = searchEnd - tagSize;
    if (start < 0) return loc;
    loc.tagStart = start;
    if (hasHeader && start >= _footerSize) loc.tagStart = start - _footerSize;
    return loc;
  }

  static bool _hasId3v1(Uint8List data, int len) {
    if (len < 128) return false;
    return data[len - 128] == 0x54 &&
        data[len - 127] == 0x41 &&
        data[len - 126] == 0x47;
  }

  static Map<String, _Item>? _readItems(Uint8List data) {
    final _Loc loc = _find(data);
    if (loc.tagStart < 0) return null;
    final int itemsEnd = loc.id3v1Start;
    final Uint8List tail =
        Uint8List.sublistView(data, itemsEnd - _footerSize, itemsEnd);
    final int tagSize = _u32(tail, 12);
    final int count = _u32(tail, 16);
    final int flags = _u32(tail, 20);
    int start = itemsEnd - tagSize;
    if ((flags & _flagHasHeader) != 0) start += _footerSize;
    final int itemsStart = start;
    final int len = itemsEnd - _footerSize - itemsStart;
    if (len <= 0 || len > 64 * 1024 * 1024) return null;
    final Uint8List buf = Uint8List.sublistView(data, itemsStart, itemsStart + len);
    final Map<String, _Item> root = <String, _Item>{};
    int pos = 0;
    for (int i = 0; i < count && pos + 8 <= buf.length; i++) {
      final int valueSize = _u32(buf, pos);
      final int itemFlags = _u32(buf, pos + 4);
      pos += 8;
      final int keyStart = pos;
      while (pos < buf.length && buf[pos] != 0) {
        pos++;
      }
      if (pos >= buf.length) break;
      final String key = String.fromCharCodes(buf.sublist(keyStart, pos));
      pos++;
      if (valueSize < 0 || pos + valueSize > buf.length) break;
      final _Item it = _Item.binary(Uint8List(0))..binary = (itemFlags & 2) != 0;
      it.value = Uint8List.fromList(buf.sublist(pos, pos + valueSize));
      pos += valueSize;
      if (!_containsIgnoreCase(root, key)) root[key] = it;
    }
    return root;
  }

  static bool _containsIgnoreCase(Map<String, _Item> map, String key) {
    for (final String k in map.keys) {
      if (k.toLowerCase() == key.toLowerCase()) return true;
    }
    return false;
  }

  static bool _isMagic(Uint8List b) {
    if (b.length < 8) return false;
    const String magic = 'APETAGEX';
    for (int i = 0; i < 8; i++) {
      if (b[i] != magic.codeUnitAt(i)) return false;
    }
    return true;
  }

  static int _u32(Uint8List b, int off) =>
      b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24);

  static void _putLe32(Uint8List b, int off, int v) {
    b[off] = v & 0xFF;
    b[off + 1] = (v >> 8) & 0xFF;
    b[off + 2] = (v >> 16) & 0xFF;
    b[off + 3] = (v >> 24) & 0xFF;
  }

  static Uint8List _le32(int v) {
    final Uint8List out = Uint8List(4);
    _putLe32(out, 0, v);
    return out;
  }
}
