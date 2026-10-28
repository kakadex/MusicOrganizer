/// FLAC Vorbis Comment 读写（纯手写实现）。
///
/// 元数据块结构：4 字节 magic + [1 字节(最后块标志<<7|类型) + 3 字节长度]。
/// 类型 4 = VORBIS_COMMENT（全部小端）。重写时只替换该块，PICTURE 等其余块原样保留。
library;

import 'dart:convert';
import 'dart:typed_data';

import '../model/tags.dart';
import 'cover_art.dart';
import 'tag_text.dart';

/// FLAC Vorbis Comment 读写（纯 Dart）。
abstract final class Flac {
  static const int typeVorbisComment = 4;
  static const int typePicture = 6;

  static const Map<String, String> readKeys = <String, String>{
    'TITLE': 'title',
    'ARTIST': 'artist',
    'ALBUM': 'album',
    'DATE': 'year',
    'TRACKNUMBER': 'track',
    'GENRE': 'genre',
    'DESCRIPTION': 'comment',
    'COMMENT': 'comment',
    'LYRICS': 'lyrics',
    'UNSYNCEDLYRICS': 'lyrics',
    'LYRIC': 'lyrics',
    'UNSYNCED LYRICS': 'lyrics',
    'UNSYNCED_LYRICS': 'lyrics',
  };

  /// 读端会把各种歌词键都映射成 lyrics，写端替换时也要认全，别留冗余。
  static const Set<String> _lyricKeys = <String>{
    'LYRICS', 'UNSYNCEDLYRICS', 'LYRIC', 'UNSYNCED LYRICS', 'UNSYNCED_LYRICS',
  };

  static const Map<String, String> writeKeys = <String, String>{
    'title': 'TITLE',
    'artist': 'ARTIST',
    'album': 'ALBUM',
    'year': 'DATE',
    'track': 'TRACKNUMBER',
    'genre': 'GENRE',
    'comment': 'DESCRIPTION',
    'lyrics': 'LYRICS',
  };

  static bool isFlac(Uint8List data) =>
      data.length >= 4 &&
      data[0] == 0x66 &&
      data[1] == 0x4C &&
      data[2] == 0x61 &&
      data[3] == 0x43;

  static Tags read(Uint8List data) {
    final Tags tags = Tags();
    if (!isFlac(data)) return tags;
    int pos = 4;
    while (pos + 4 <= data.length) {
      final int b = data[pos];
      final bool last = (b & 0x80) != 0;
      final int type = b & 0x7F;
      final int len = (data[pos + 1] << 16) | (data[pos + 2] << 8) | data[pos + 3];
      if (pos + 4 + len > data.length) break;
      if (type == typeVorbisComment) {
        _parseComments(tags, Uint8List.sublistView(data, pos + 4, pos + 4 + len));
        return tags;
      }
      pos += 4 + len;
      if (last) break;
    }
    return tags;
  }

  static void _parseComments(Tags tags, Uint8List data) {
    int p = 0;
    if (p + 4 > data.length) return;
    final int vendorLen = _le32(data, p);
    p += 4 + vendorLen;
    if (p + 4 > data.length) return;
    final int count = _le32(data, p);
    p += 4;
    for (int i = 0; i < count && p + 4 <= data.length; i++) {
      final int len = _le32(data, p);
      p += 4;
      if (len < 0 || p + len > data.length) break;
      final String entry =
          TagText.decodeUtf8(Uint8List.sublistView(data, p, p + len));
      p += len;
      final int eq = entry.indexOf('=');
      if (eq <= 0) continue;
      final String key = entry.substring(0, eq).toUpperCase();
      final String value = entry.substring(eq + 1).trim();
      final String? field = readKeys[key];
      if (field != null && value.isNotEmpty) {
        if (field == 'artist' && tags.get('artist').isNotEmpty) {
          tags.put('artist', '${tags.get('artist')},$value');
        } else {
          tags.put(field, value);
        }
      }
    }
  }

  /// 写入字段；cover: null=不动 / 空=删除 PICTURE / 非空=替换。返回新文件字节。
  static Uint8List rewrite(Uint8List data, Map<String, String> values,
      {Uint8List? cover}) {
    final List<int> types = <int>[];
    final List<Uint8List> blocks = <Uint8List>[];
    final List<int> pictureIndexes = <int>[];
    int vcIndex = -1;
    int audioStart = 0;
    int pos = 4;
    while (true) {
      if (pos + 4 > data.length) throw const FormatException('FLAC 块解析失败');
      final int b = data[pos];
      final bool last = (b & 0x80) != 0;
      final int type = b & 0x7F;
      final int len = (data[pos + 1] << 16) | (data[pos + 2] << 8) | data[pos + 3];
      if (pos + 4 + len > data.length) throw const FormatException('FLAC 块长度越界');
      final Uint8List block =
          Uint8List.fromList(data.sublist(pos + 4, pos + 4 + len));
      if (type == typeVorbisComment) vcIndex = types.length;
      if (type == typePicture) pictureIndexes.add(types.length);
      types.add(type);
      blocks.add(block);
      pos += 4 + len;
      if (last) break;
    }
    audioStart = pos;

    if (vcIndex < 0) {
      final int insertAt = 1 < types.length ? 1 : types.length;
      types.insert(insertAt, typeVorbisComment);
      blocks.insert(insertAt, Uint8List(0));
      vcIndex = insertAt;
    }

    Uint8List vendor = Uint8List(0);
    final Uint8List oldVc = blocks[vcIndex];
    final int vendorLen = oldVc.length >= 4 ? _le32(oldVc, 0) : 0;
    if (vendorLen > 0 && 4 + vendorLen <= oldVc.length) {
      vendor = Uint8List.fromList(oldVc.sublist(4, 4 + vendorLen));
    }

    final List<String> entries = <String>[];
    if (oldVc.length >= 4) {
      int p = 4 + _le32(oldVc, 0);
      if (p + 4 <= oldVc.length) {
        final int count = _le32(oldVc, p);
        p += 4;
        for (int i = 0; i < count && p + 4 <= oldVc.length; i++) {
          final int len = _le32(oldVc, p);
          p += 4;
          if (p + len > oldVc.length) break;
          final String entry =
              TagText.decodeUtf8(Uint8List.sublistView(oldVc, p, p + len));
          p += len;
          final int eq = entry.indexOf('=');
          final String key =
              eq > 0 ? entry.substring(0, eq).toUpperCase() : '';
          bool replaced = false;
          for (final MapEntry<String, String> e in values.entries) {
            final String? wk = writeKeys[e.key];
            if (e.key == 'lyrics') {
              // 老字段可能叫 LYRIC / UNSYNCED LYRICS / UNSYNCED_LYRICS，
              // 都要被新的 LYRICS 替换掉，否则文件里越堆越多
              if (_lyricKeys.contains(key)) {
                replaced = true;
                break;
              }
            } else if (wk != null && wk == key) {
              replaced = true;
              break;
            }
          }
          if (!replaced && entry.trim().isNotEmpty) entries.add(entry);
        }
      }
    }
    for (final MapEntry<String, String> e in values.entries) {
      final String? key = writeKeys[e.key];
      final String value = e.value.trim();
      if (key == null || value.isEmpty) continue;
      entries.add('$key=$value');
    }
    final Uint8List newBlock = _buildVorbisComment(vendor, entries);
    if (newBlock.length > 0xFFFFFF) {
      // FLAC 元数据块长度只有 3 字节；超限时写出去会被截断成错误长度，直接拒绝
      throw const FormatException('FLAC 标签块超过 16MB 限制');
    }

    if (cover != null) {
      for (int i = pictureIndexes.length - 1; i >= 0; i--) {
        final int idx = pictureIndexes[i];
        blocks.removeAt(idx);
        types.removeAt(idx);
        if (idx < vcIndex) vcIndex--;
      }
      if (cover.isNotEmpty) {
        final Uint8List pic = _buildPicture(cover);
        if (pic.length > 0xFFFFFF) {
          throw const FormatException('FLAC 封面块超过 16MB 限制');
        }
        types.add(typePicture);
        blocks.add(pic);
      }
    }

    final BytesBuilder out = BytesBuilder();
    out.add(<int>[0x66, 0x4C, 0x61, 0x43]); // fLaC
    for (int i = 0; i < types.length; i++) {
      final bool last = i == types.length - 1;
      final Uint8List d = i == vcIndex ? newBlock : blocks[i];
      out.addByte((last ? 0x80 : 0) | types[i]);
      out.add(<int>[
        (d.length >> 16) & 0xFF,
        (d.length >> 8) & 0xFF,
        d.length & 0xFF,
      ]);
      out.add(d);
    }
    out.add(Uint8List.sublistView(data, audioStart));
    return out.toBytes();
  }

  static Uint8List _buildPicture(Uint8List image) {
    final List<int> dim = CoverArt.dimensions(image);
    String mime = CoverArt.mimeOf(image);
    if (mime.isEmpty) mime = 'image/jpeg';
    final BytesBuilder out = BytesBuilder();
    out.add(_be32Bytes(3));
    final Uint8List m = Uint8List.fromList(mime.codeUnits);
    out.add(_be32Bytes(m.length));
    out.add(m);
    out.add(_be32Bytes(0));
    out.add(_be32Bytes(dim[0]));
    out.add(_be32Bytes(dim[1]));
    out.add(_be32Bytes(24));
    out.add(_be32Bytes(0));
    out.add(_be32Bytes(image.length));
    out.add(image);
    return out.toBytes();
  }

  static bool hasPicture(Uint8List data) {
    if (!isFlac(data)) return false;
    int pos = 4;
    while (pos + 4 <= data.length) {
      final int b = data[pos];
      final bool last = (b & 0x80) != 0;
      final int type = b & 0x7F;
      final int len = (data[pos + 1] << 16) | (data[pos + 2] << 8) | data[pos + 3];
      if (type == typePicture) return true;
      if (last) return false;
      pos += 4 + len;
    }
    return false;
  }

  static Uint8List _buildVorbisComment(
      Uint8List vendor, List<String> entries) {
    final BytesBuilder out = BytesBuilder();
    out.add(_le32Bytes(vendor.length));
    out.add(vendor);
    out.add(_le32Bytes(entries.length));
    for (final String entry in entries) {
      final Uint8List b = Uint8List.fromList(utf8.encode(entry));
      out.add(_le32Bytes(b.length));
      out.add(b);
    }
    return out.toBytes();
  }

  static int _le32(Uint8List b, int off) {
    if (off + 4 > b.length) return 0;
    return b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24);
  }

  static Uint8List _le32Bytes(int v) => Uint8List.fromList(<int>[
        v & 0xFF,
        (v >> 8) & 0xFF,
        (v >> 16) & 0xFF,
        (v >> 24) & 0xFF,
      ]);

  static Uint8List _be32Bytes(int v) => Uint8List.fromList(<int>[
        (v >> 24) & 0xFF,
        (v >> 16) & 0xFF,
        (v >> 8) & 0xFF,
        v & 0xFF,
      ]);
}
