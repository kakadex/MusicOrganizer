/// OGG Vorbis / Opus 的 Vorbis Comment 读写 —— 移植自旧 core/Ogg.java。
///
/// 每页头 27 字节 + 段表（lacing）；段值 255 表示「本包未结束」，<255 表示包结束。
/// 注释包固定是第 2 个包。写入只重建「包含注释包的那一页」，仅拆页时才顺移后续页序号并重算 CRC。
library;

import 'dart:convert';
import 'dart:typed_data';

import '../model/tags.dart';
import 'tag_text.dart';

class _Page {
  int index = 0;
  int offset = 0;
  int headerType = 0;
  int granule = 0;
  int serial = 0;
  int seq = 0;
  int totalLen = 0;
}

class _Packet {
  _Packet(this.data);

  final Uint8List data;
  int indexInPage = 0;
  int startPage = 0;
  int endPage = 0;
  int granule = 0;
}

/// OGG Vorbis Comment 读写（纯 Dart）。
abstract final class Ogg {
  static bool isOgg(Uint8List data) =>
      data.length >= 27 &&
      data[0] == 0x4F &&
      data[1] == 0x67 &&
      data[2] == 0x67 &&
      data[3] == 0x53;

  static Tags read(Uint8List data) {
    final Tags tags = Tags();
    if (!isOgg(data)) return tags;
    final List<_Packet> packets = _packets(data);
    if (packets.length < 2) return tags;
    _applyComments(tags, packets[1].data);
    return tags;
  }

  static bool hasCover(Uint8List data) {
    try {
      final List<_Packet> packets = _packets(data);
      if (packets.length < 2) return false;
      final Map<String, String> c = parseComments(packets[1].data);
      for (final String key in c.keys) {
        final String k = key.toUpperCase();
        if (k.startsWith('METADATA_BLOCK_PICTURE') || k.startsWith('COVERART')) {
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  static void _applyComments(Tags tags, Uint8List packet) {
    final Map<String, String> c = parseComments(packet);
    _putIfPresent(tags, c, 'title', 'TITLE');
    _putIfPresent(tags, c, 'artist', 'ARTIST');
    _putIfPresent(tags, c, 'album', 'ALBUM');
    _putIfPresent(tags, c, 'year', 'DATE');
    _putIfPresent(tags, c, 'genre', 'GENRE');
    _putIfPresent(tags, c, 'comment', 'COMMENT');
    _putIfPresent(tags, c, 'track', 'TRACKNUMBER');
    for (final String k in <String>[
      'LYRICS',
      'UNSYNCEDLYRICS',
      'LYRIC',
      'SYNCEDLYRICS'
    ]) {
      final String? v = c[k];
      if (v != null && v.trim().isNotEmpty) {
        tags.put('lyrics', v);
        break;
      }
    }
  }

  static void _putIfPresent(
      Tags tags, Map<String, String> c, String field, String key) {
    final String? v = c[key];
    if (v != null) tags.put(field, v);
  }

  /// 解析 Vorbis Comment 包（键大写 → 值，同名只留第一个）。
  static Map<String, String> parseComments(Uint8List packet) {
    final Map<String, String> out = <String, String>{};
    int pos;
    if (_startsWith(packet, <int>[0x03, 0x76, 0x6F, 0x72, 0x62, 0x69, 0x73])) {
      pos = 7;
    } else if (_startsWith(packet, _ascii('OpusTags'))) {
      pos = 8;
    } else {
      return out;
    }
    final int vendorLen = _readInt(packet, pos);
    pos += 4 + vendorLen;
    final int count = _readInt(packet, pos);
    pos += 4;
    for (int i = 0; i < count && pos + 4 <= packet.length; i++) {
      final int len = _readInt(packet, pos);
      pos += 4;
      if (len < 0 || pos + len > packet.length) break;
      final String entry =
          TagText.decodeUtf8(Uint8List.sublistView(packet, pos, pos + len));
      pos += len;
      final int eq = entry.indexOf('=');
      if (eq <= 0) continue;
      final String key = entry.substring(0, eq).toUpperCase();
      final String value = entry.substring(eq + 1);
      out.putIfAbsent(key, () => value);
    }
    return out;
  }

  static String vendorOf(Uint8List packet) {
    int pos;
    if (_startsWith(packet, <int>[0x03, 0x76, 0x6F, 0x72, 0x62, 0x69, 0x73])) {
      pos = 7;
    } else if (_startsWith(packet, _ascii('OpusTags'))) {
      pos = 8;
    } else {
      return '';
    }
    if (pos + 4 > packet.length) return '';
    final int len = _readInt(packet, pos);
    if (len < 0 || pos + 4 + len > packet.length) return '';
    return TagText.decodeUtf8(
        Uint8List.sublistView(packet, pos + 4, pos + 4 + len));
  }

  /// 组装注释包：头 + vendor + 计数 + 「KEY=value」 + Vorbis 的 framed bit。
  static Uint8List buildComment(
      bool opus, String vendor, Map<String, String> comments) {
    final BytesBuilder body = BytesBuilder();
    if (opus) {
      body.add(_ascii('OpusTags'));
    } else {
      body.add(<int>[0x03, 0x76, 0x6F, 0x72, 0x62, 0x69, 0x73]);
    }
    final Uint8List vb = Uint8List.fromList(utf8.encode(vendor));
    body.add(_intBytes(vb.length));
    body.add(vb);
    body.add(_intBytes(comments.length));
    for (final MapEntry<String, String> e in comments.entries) {
      final Uint8List kv = Uint8List.fromList(utf8.encode('${e.key}=${e.value}'));
      body.add(_intBytes(kv.length));
      body.add(kv);
    }
    if (!opus) body.addByte(0x01);
    return body.toBytes();
  }

  /// 写入字段（合并语义）。cover 在 OGG 里忽略（封面走 METADATA_BLOCK_PICTURE 注释，本版不写）。
  static Uint8List rewrite(Uint8List data, Map<String, String> values,
      {Uint8List? cover}) {
    if (!isOgg(data)) throw const FormatException('不是有效的 OGG 文件');
    final List<_Page> pages = _pages(data);
    if (pages.isEmpty) throw const FormatException('OGG 文件没有可用页面');
    final List<_Packet> packets = _packets(data);
    if (packets.length < 2) throw const FormatException('OGG 文件缺少注释包');
    final bool opus = _startsWith(packets[0].data, _ascii('OpusHead'));
    final bool vorbis = _startsWith(packets[0].data,
        <int>[0x01, 0x76, 0x6F, 0x72, 0x62, 0x69, 0x73]);
    if (!opus && !vorbis) {
      throw const FormatException('只支持 OGG Vorbis / Opus');
    }

    final _Packet comment = packets[1];
    if (comment.startPage != comment.endPage) {
      throw const FormatException('歌词体积过大（注释跨页），暂不支持写入');
    }
    final _Page hostPage = pages[comment.startPage];

    final Map<String, String> merged = parseComments(comment.data);
    String vendor = vendorOf(comment.data);
    if (vendor.isEmpty) vendor = 'MusicOrganizer';
    for (final MapEntry<String, String> e in values.entries) {
      final String? key = _vorbisKey(e.key);
      if (key == null) continue;
      merged.remove(key);
      final String raw = e.value;
      final String v = e.key == 'lyrics' ? raw : raw.trim();
      if (v.isNotEmpty) merged[key] = v;
    }
    final Uint8List newComment = buildComment(opus, vendor, merged);
    if (newComment.length > 255 * 255 * 8) {
      throw const FormatException('标签数据过大（超过 500KB）');
    }

    final List<Uint8List> tail = <Uint8List>[];
    for (int i = 1; i < packets.length; i++) {
      final _Packet p = packets[i];
      if (p.startPage == hostPage.index && p.indexInPage > comment.indexInPage) {
        tail.add(p.data);
      }
    }
    final List<Uint8List> newPackets = <Uint8List>[newComment, ...tail];
    final List<Uint8List> newPages = _buildPages(hostPage, newPackets);
    final int extra = newPages.length - 1;

    final BytesBuilder out = BytesBuilder();
    out.add(Uint8List.sublistView(data, 0, hostPage.offset));
    for (final Uint8List page in newPages) {
      out.add(page);
    }
    final int afterOffset = hostPage.offset + hostPage.totalLen;
    final Uint8List rest = Uint8List.fromList(data.sublist(afterOffset));
    if (extra == 0) {
      out.add(rest);
    } else {
      int pos = 0;
      while (pos + 27 <= rest.length) {
        final int total = _pageTotalLen(rest, pos);
        if (total <= 0 || pos + total > rest.length) break;
        final int seq = _readU32(rest, pos + 18);
        _writeU32(rest, pos + 18, seq + extra);
        _writeU32(rest, pos + 22, 0);
        _writeU32(rest, pos + 22, crc(rest, pos, total));
        pos += total;
      }
      out.add(rest);
    }

    final Uint8List result = out.toBytes();
    _verify(result, packets, 1);
    return result;
  }

  static void _verify(Uint8List rewritten, List<_Packet> before, int commentIndex) {
    final List<_Packet> after = _packets(rewritten);
    if (after.length != before.length) {
      throw const FormatException('OGG 校验失败：包数量变化，已取消写入');
    }
    for (int i = 0; i < before.length; i++) {
      if (i == commentIndex) continue;
      if (!_sameBytes(before[i].data, after[i].data)) {
        throw const FormatException('OGG 校验失败：数据包被改动，已取消写入');
      }
    }
  }

  static String? _vorbisKey(String field) {
    switch (field) {
      case 'title':
        return 'TITLE';
      case 'artist':
        return 'ARTIST';
      case 'album':
        return 'ALBUM';
      case 'year':
        return 'DATE';
      case 'track':
        return 'TRACKNUMBER';
      case 'genre':
        return 'GENRE';
      case 'comment':
        return 'COMMENT';
      case 'lyrics':
        return 'LYRICS';
      default:
        return null;
    }
  }

  // ------------------------------------------------------------------
  // 页 / 包
  // ------------------------------------------------------------------

  static List<Uint8List> _buildPages(_Page host, List<Uint8List> packets) {
    final List<Uint8List> out = <Uint8List>[];
    List<int> segs = <int>[];
    BytesBuilder payload = BytesBuilder();
    bool startsContinued = false;
    bool midPacket = false;
    for (final Uint8List p in packets) {
      int off = 0;
      while (true) {
        if (segs.length == 255) {
          out.add(_emitPage(
              host, out.length, segs, payload.toBytes(), startsContinued, midPacket));
          segs = <int>[];
          payload = BytesBuilder();
          startsContinued = midPacket;
        }
        final int remain = p.length - off;
        final int take = 255 < remain ? 255 : remain;
        segs.add(take);
        payload.add(Uint8List.sublistView(p, off, off + take));
        off += take;
        midPacket = (p.length - off) > 0;
        if (take < 255) break;
        if (off == p.length) {
          if (segs.length == 255) {
            out.add(_emitPage(
                host, out.length, segs, payload.toBytes(), startsContinued, true));
            segs = <int>[];
            payload = BytesBuilder();
            startsContinued = true;
          }
          segs.add(0);
          midPacket = false;
          break;
        }
      }
    }
    out.add(_emitPage(host, out.length, segs, payload.toBytes(), startsContinued, false));
    return out;
  }

  static Uint8List _emitPage(_Page host, int indexOffset, List<int> segs,
      Uint8List payload, bool startsContinued, bool midPacket) {
    final BytesBuilder b = BytesBuilder();
    b.add(<int>[0x4F, 0x67, 0x67, 0x53, 0]);
    final int type;
    final int granule;
    if (indexOffset == 0) {
      type = host.headerType;
      granule = host.granule;
    } else {
      type = startsContinued ? 0x01 : 0;
      granule = 0;
    }
    b.addByte(type);
    b.add(_longBytes(granule));
    b.add(_intBytes(host.serial));
    b.add(_intBytes(host.seq + indexOffset));
    b.add(<int>[0, 0, 0, 0]);
    b.addByte(segs.length);
    for (final int s in segs) {
      b.addByte(s & 0xFF);
    }
    b.add(payload);
    final Uint8List page = b.toBytes();
    _writeU32(page, 22, crc(page, 0, page.length));
    return page;
  }

  static List<_Page> _pages(Uint8List data) {
    final List<_Page> out = <_Page>[];
    int pos = 0;
    int index = 0;
    while (pos + 27 <= data.length) {
      if (data[pos] != 0x4F ||
          data[pos + 1] != 0x67 ||
          data[pos + 2] != 0x67 ||
          data[pos + 3] != 0x53) {
        break;
      }
      final int nsegs = data[pos + 26];
      int payloadLen = 0;
      for (int i = 0; i < nsegs; i++) {
        payloadLen += data[pos + 27 + i];
      }
      final int total = 27 + nsegs + payloadLen;
      if (pos + total > data.length) break;
      final _Page p = _Page()
        ..index = index++
        ..offset = pos
        ..headerType = data[pos + 5]
        ..granule = _readLong(data, pos + 6)
        ..serial = _readU32(data, pos + 14)
        ..seq = _readU32(data, pos + 18)
        ..totalLen = total;
      out.add(p);
      pos += total;
    }
    return out;
  }

  static List<_Packet> _packets(Uint8List data) {
    final List<_Packet> out = <_Packet>[];
    BytesBuilder cur = BytesBuilder();
    bool open = false;
    int startPage = -1;
    for (final _Page page in _pages(data)) {
      final int segCount = data[page.offset + 26];
      int payloadPos = page.offset + 27 + segCount;
      int indexInPage = 0;
      for (int i = 0; i < segCount; i++) {
        final int seg = data[page.offset + 27 + i];
        if (!open) {
          open = true;
          startPage = page.index;
          cur = BytesBuilder();
        }
        cur.add(Uint8List.sublistView(data, payloadPos, payloadPos + seg));
        payloadPos += seg;
        if (seg < 255) {
          final _Packet p = _Packet(cur.toBytes())
            ..indexInPage = indexInPage++
            ..startPage = startPage
            ..endPage = page.index
            ..granule = page.granule;
          out.add(p);
          open = false;
        }
      }
    }
    return out;
  }

  // ------------------------------------------------------------------
  // 工具
  // ------------------------------------------------------------------

  /// Ogg 用的 CRC32：多项式 0x04C11DB7，初值 0，不反射、不取反。
  static int crc(Uint8List data, int off, int len) {
    int crc = 0;
    for (int i = off; i < off + len; i++) {
      crc = ((crc << 8) ^ _table[((crc >> 24) ^ data[i]) & 0xFF]) & 0xFFFFFFFF;
    }
    return crc;
  }

  static final List<int> _table = _buildCrcTable();

  static List<int> _buildCrcTable() {
    final List<int> t = List<int>.filled(256, 0);
    for (int i = 0; i < 256; i++) {
      int r = (i << 24) & 0xFFFFFFFF;
      for (int j = 0; j < 8; j++) {
        r = ((r & 0x80000000) != 0 ? (r << 1) ^ 0x04C11DB7 : (r << 1)) &
            0xFFFFFFFF;
      }
      t[i] = r;
    }
    return t;
  }

  static int _pageTotalLen(Uint8List buf, int pos) {
    final int nsegs = buf[pos + 26];
    int payload = 0;
    for (int i = 0; i < nsegs; i++) {
      payload += buf[pos + 27 + i];
    }
    return 27 + nsegs + payload;
  }

  static int _readInt(Uint8List b, int off) =>
      b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24);

  static int _readU32(Uint8List b, int off) =>
      b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24);

  static int _readLong(Uint8List b, int off) {
    int v = 0;
    for (int i = 7; i >= 0; i--) {
      v = (v << 8) | b[off + i];
    }
    return v;
  }

  static void _writeU32(Uint8List b, int off, int v) {
    b[off] = v & 0xFF;
    b[off + 1] = (v >> 8) & 0xFF;
    b[off + 2] = (v >> 16) & 0xFF;
    b[off + 3] = (v >> 24) & 0xFF;
  }

  static Uint8List _intBytes(int v) => Uint8List.fromList(<int>[
        v & 0xFF,
        (v >> 8) & 0xFF,
        (v >> 16) & 0xFF,
        (v >> 24) & 0xFF,
      ]);

  static Uint8List _longBytes(int v) {
    final Uint8List out = Uint8List(8);
    for (int i = 0; i < 8; i++) {
      out[i] = (v >> (8 * i)) & 0xFF;
    }
    return out;
  }

  static bool _startsWith(Uint8List data, List<int> prefix) {
    if (data.length < prefix.length) return false;
    for (int i = 0; i < prefix.length; i++) {
      if (data[i] != prefix[i]) return false;
    }
    return true;
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static Uint8List _ascii(String s) => Uint8List.fromList(s.codeUnits);
}
