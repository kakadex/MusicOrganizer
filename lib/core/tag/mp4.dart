/// MP4 / M4A 标签读写（moov > udta > meta > ilst）。
///
/// 写：重建 udta>meta>ilst，算出新 moov 与旧 moov 长度差 delta；若 mdat 在 moov 之后，
/// 把 stco/co64 里 offset >= moov 末尾的项全部加上 delta（偏移修正）。
library;

import 'dart:convert';
import 'dart:typed_data';

import '../model/tags.dart';
import 'tag_text.dart';

/// MP4/M4A 标签读写（纯 Dart，工作在内存字节上）。
abstract final class Mp4 {
  static const Map<String, String> _atomFields = <String, String>{
    '\u00a9nam': 'title',
    '\u00a9ART': 'artist',
    '\u00a9alb': 'album',
    '\u00a9day': 'year',
    'trkn': 'track',
    '\u00a9gen': 'genre',
    'gnre': 'genre',
    '\u00a9cmt': 'comment',
    '\u00a9lyr': 'lyrics',
  };

  static const Map<String, String> _fieldAtoms = <String, String>{
    'title': '\u00a9nam',
    'artist': '\u00a9ART',
    'album': '\u00a9alb',
    'year': '\u00a9day',
    'track': 'trkn',
    'genre': '\u00a9gen',
    'comment': '\u00a9cmt',
    'lyrics': '\u00a9lyr',
  };

  static bool isMp4(Uint8List data) =>
      data.length >= 8 &&
      data[4] == 0x66 &&
      data[5] == 0x74 &&
      data[6] == 0x79 &&
      data[7] == 0x70;

  static Tags read(Uint8List data) {
    final Tags tags = Tags();
    _walk(data, 0, data.length, tags, 0);
    return tags;
  }

  static void _walk(Uint8List b, int start, int end, Tags tags, int depth) {
    if (depth > 8) return;
    int pos = start;
    while (pos + 8 <= end) {
      int size = (b[pos] << 24) | (b[pos + 1] << 16) | (b[pos + 2] << 8) | b[pos + 3];
      final String type = _type(b, pos);
      if (size == 1) {
        size = _be64(b, pos + 8);
        pos += 8;
      } else if (size == 0) {
        size = end - pos;
      }
      if (size < 8 || pos + size > end) break;
      if (type == 'moov' || type == 'udta') {
        _walk(b, pos + 8, pos + size, tags, depth + 1);
      } else if (type == 'meta') {
        _walk(b, pos + 12, pos + size, tags, depth + 1);
      } else if (type == 'ilst') {
        _parseIlst(b, pos + 8, pos + size, tags);
        return;
      }
      pos += size;
    }
  }

  static void _parseIlst(Uint8List b, int start, int end, Tags tags) {
    int pos = start;
    while (pos + 8 <= end) {
      final int size = (b[pos] << 24) | (b[pos + 1] << 16) | (b[pos + 2] << 8) | b[pos + 3];
      final String atomName = _type(b, pos);
      if (size < 8 || pos + size > end) break;
      final String? field = _atomFields[atomName];
      if (field != null) {
        int p = pos + 8;
        while (p + 8 <= pos + size) {
          final int dsize = (b[p] << 24) | (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3];
          final String dtype = _type(b, p);
          if (dsize >= 16 && dtype == 'data') {
            final Uint8List payload =
                Uint8List.sublistView(b, p + 16, p + dsize);
            _apply(tags, field, atomName, payload);
            break;
          }
          if (dsize < 8) break;
          p += dsize;
        }
      }
      pos += size;
    }
  }

  static void _apply(Tags tags, String field, String atom, Uint8List payload) {
    if (atom == 'trkn') {
      if (payload.length >= 4) {
        final int value = (payload[2] << 8) | payload[3];
        if (value > 0) tags.put('track', '$value');
      }
      return;
    }
    if (atom == 'gnre') {
      if (payload.length >= 2) {
        final int id = (payload[0] << 8) | payload[1];
        if (id >= 1 && id <= 80) tags.put('genre', 'ID3 Genre ${id - 1}');
      }
      return;
    }
    final String v = TagText.decodeUtf8(payload).trim();
    if (v.isNotEmpty) tags.put(field, v);
  }

  // ------------------------------------------------------------------
  // 写入
  // ------------------------------------------------------------------

  /// 写入字段（合并语义）。cover: null=不动 / 空=删除 / 非空=替换。返回新文件字节。
  static Uint8List write(Uint8List data, Map<String, String> values,
      {Uint8List? cover}) {
    final List<int> starts = <int>[];
    final List<int> sizes = <int>[];
    final List<String> types = <String>[];
    int pos = 0;
    while (pos + 8 <= data.length) {
      int size = (data[pos] << 24) | (data[pos + 1] << 16) | (data[pos + 2] << 8) | data[pos + 3];
      final String type = _type(data, pos);
      int headerLen = 8;
      if (size == 1) {
        size = _be64(data, pos + 8);
        headerLen = 16;
      } else if (size == 0) {
        size = data.length - pos;
      }
      if (size < headerLen || pos + size > data.length) break;
      starts.add(pos);
      sizes.add(size);
      types.add(type);
      pos += size;
    }
    final int moovIdx = types.indexOf('moov');
    if (moovIdx < 0) throw const FormatException('MP4 里找不到 moov 块');
    final int moovStart = starts[moovIdx];
    final int moovSize = sizes[moovIdx];
    final Uint8List moov = Uint8List.sublistView(data, moovStart, moovStart + moovSize);

    final Uint8List newMoov = _rebuildMoov(moov, values, cover);
    final int delta = newMoov.length - moovSize;
    if (delta != 0) {
      _patchChunkOffsets(newMoov, moovStart + moovSize, delta);
    }

    final BytesBuilder out = BytesBuilder();
    for (int i = 0; i < types.length; i++) {
      if (types[i] == 'moov') {
        out.add(newMoov);
      } else {
        out.add(Uint8List.sublistView(data, starts[i], starts[i] + sizes[i]));
      }
    }
    return out.toBytes();
  }

  static bool hasCover(Uint8List data) {
    final Uint8List? moov = _readAtomOrNull(data, 'moov');
    if (moov == null) return false;
    final Uint8List? ilst = _findIlst(moov);
    if (ilst == null) return false;
    return _findChild(ilst, 8, ilst.length, 'covr') != null;
  }

  /// 第一个 stco/co64 的偏移列表（诊断/测试用）。
  static List<int> chunkOffsets(Uint8List data) {
    final Uint8List? moov = _readAtomOrNull(data, 'moov');
    if (moov == null) return <int>[];
    final List<List<int>> found = <List<int>>[];
    _collectChunkOffsets(moov, 0, moov.length, found);
    if (found.isEmpty) return <int>[];
    return found.first;
  }

  // ---- 内部：重建 moov ----

  static Uint8List _rebuildMoov(
      Uint8List moov, Map<String, String> values, Uint8List? cover) {
    if (moov.length < 8) throw const FormatException('moov 块损坏');
    final List<Uint8List> children = _split(moov, 8, moov.length);
    final Uint8List? udta = _findChildList(children, 'udta');
    Uint8List? oldMeta;
    if (udta != null) {
      oldMeta = _findChildList(_split(udta, 8, udta.length), 'meta');
    }
    List<Uint8List> metaChildren = <Uint8List>[];
    Uint8List? hdlr;
    Uint8List? oldIlst;
    if (oldMeta != null) {
      metaChildren = _split(oldMeta, 12, oldMeta.length);
      for (final Uint8List child in metaChildren) {
        final String t = _typeOf(child);
        if (t == 'hdlr') {
          hdlr = child;
        } else if (t == 'ilst') {
          oldIlst = child;
        }
      }
    }
    final Uint8List newIlst = _rebuildIlst(oldIlst, values, cover);
    final Uint8List newMeta = _atom(
        'meta',
        _concat(<Uint8List>[
          Uint8List(4),
          hdlr ?? _defaultHdlr(),
          newIlst,
        ]));
    final Uint8List newUdta = udta == null
        ? _atom('udta', newMeta)
        : _atom('udta', _concat(<Uint8List>[_withoutChild(udta, 'meta'), newMeta]));
    final Uint8List newMoov = _atom(
        'moov',
        udta == null
            ? _concat(<Uint8List>[_join(children), newUdta])
            : _concat(<Uint8List>[_withoutChild(moov, 'udta'), newUdta]));
    return newMoov;
  }

  static Uint8List _rebuildIlst(
      Uint8List? oldIlst, Map<String, String> values, Uint8List? cover) {
    final List<Uint8List> children =
        oldIlst == null ? <Uint8List>[] : _split(oldIlst, 8, oldIlst.length);
    final List<String> remove = <String>[];
    final List<Uint8List> add = <Uint8List>[];
    for (final MapEntry<String, String> e in values.entries) {
      final String? atomName = _fieldAtoms[e.key];
      if (atomName == null) continue;
      remove.add(atomName);
      final String v = e.value.trim();
      if (v.isEmpty) continue;
      if (atomName == 'trkn') {
        add.add(_trackAtom(v));
      } else if (atomName == '\u00a9gen') {
        add.add(_textAtom(atomName, v));
        remove.add('gnre');
      } else {
        add.add(_textAtom(atomName, v));
      }
    }
    if (cover != null) {
      remove.add('covr');
      if (cover.isNotEmpty) add.add(_coverAtom(cover));
    }
    final List<Uint8List> kept = <Uint8List>[];
    for (final Uint8List child in children) {
      if (!remove.contains(_typeOf(child))) kept.add(child);
    }
    kept.addAll(add);
    return _atom('ilst', _join(kept));
  }

  static Uint8List _textAtom(String name, String value) {
    final Uint8List body = Uint8List.fromList(utf8.encode(value));
    final Uint8List data = Uint8List(8 + body.length);
    _putBe32(data, 0, 1);
    data.setRange(8, 8 + body.length, body);
    return _atom(name, _atom('data', data));
  }

  static Uint8List _trackAtom(String value) {
    int track = 0;
    int total = 0;
    final String v = value.trim();
    final int slash = v.indexOf('/');
    track = int.tryParse((slash >= 0 ? v.substring(0, slash) : v).trim()) ?? 0;
    if (slash >= 0) {
      total = int.tryParse(v.substring(slash + 1).trim()) ?? 0;
    }
    final Uint8List data = Uint8List(16);
    _putBe32(data, 0, 0);
    data[10] = (track >> 8) & 0xFF;
    data[11] = track & 0xFF;
    data[12] = (total >> 8) & 0xFF;
    data[13] = total & 0xFF;
    return _atom('trkn', _atom('data', data));
  }

  static Uint8List _coverAtom(Uint8List image) {
    final bool png = image.length > 4 &&
        image[0] == 0x89 &&
        image[1] == 0x50 &&
        image[2] == 0x4E &&
        image[3] == 0x47;
    final Uint8List data = Uint8List(8 + image.length);
    _putBe32(data, 0, png ? 14 : 13);
    data.setRange(8, 8 + image.length, image);
    return _atom('covr', _atom('data', data));
  }

  static Uint8List _defaultHdlr() {
    final Uint8List p = Uint8List(25);
    const String s = 'mdirappl';
    for (int i = 0; i < s.length; i++) {
      p[8 + i] = s.codeUnitAt(i);
    }
    return _atom('hdlr', p);
  }

  // ---- atom 工具 ----

  static String _typeOf(Uint8List a) =>
      a.length < 8 ? '' : _type(a, 0);

  static String _type(Uint8List b, int pos) =>
      String.fromCharCodes(b.sublist(pos + 4, pos + 8));

  static Uint8List _atom(String type, Uint8List payload) {
    final int size = 8 + payload.length;
    final Uint8List out = Uint8List(size);
    _putBe32(out, 0, size);
    for (int i = 0; i < 4; i++) {
      out[4 + i] = type.codeUnitAt(i);
    }
    out.setRange(8, 8 + payload.length, payload);
    return out;
  }

  static List<Uint8List> _split(Uint8List buf, int start, int end) {
    final List<Uint8List> out = <Uint8List>[];
    int pos = start;
    while (pos + 8 <= end) {
      final int size = _be32(buf, pos);
      if (size < 8 || pos + size > end) break;
      out.add(Uint8List.fromList(buf.sublist(pos, pos + size)));
      pos += size;
    }
    return out;
  }

  static Uint8List? _findChildList(List<Uint8List> children, String type) {
    for (final Uint8List child in children) {
      if (type == _typeOf(child)) return child;
    }
    return null;
  }

  static Uint8List? _findChild(Uint8List parent, int start, int end, String type) {
    for (final Uint8List child in _split(parent, start, end)) {
      if (type == _typeOf(child)) return child;
    }
    return null;
  }

  static List<Uint8List> _childrenWithout(List<Uint8List> children, String type) {
    final List<Uint8List> out = <Uint8List>[];
    for (final Uint8List child in children) {
      if (type != _typeOf(child)) out.add(child);
    }
    return out;
  }

  static Uint8List _withoutChild(Uint8List parent, String type) {
    final List<Uint8List> keep = _childrenWithout(_split(parent, 8, parent.length), type);
    return _atom(_typeOf(parent), keep.isEmpty ? Uint8List(0) : _join(keep));
  }

  static Uint8List _join(List<Uint8List> parts) {
    int total = 0;
    for (final Uint8List p in parts) {
      total += p.length;
    }
    final Uint8List out = Uint8List(total);
    int off = 0;
    for (final Uint8List p in parts) {
      out.setRange(off, off + p.length, p);
      off += p.length;
    }
    return out;
  }

  static Uint8List _concat(List<Uint8List> parts) {
    int total = 0;
    for (final Uint8List p in parts) {
      total += p.length;
    }
    final Uint8List out = Uint8List(total);
    int off = 0;
    for (final Uint8List p in parts) {
      out.setRange(off, off + p.length, p);
      off += p.length;
    }
    return out;
  }

  static void _patchChunkOffsets(Uint8List moov, int threshold, int delta) {
    final List<List<int>> boxes = <List<int>>[];
    _collectBoxes(moov, 0, moov.length, 'stco', boxes);
    _collectBoxes(moov, 0, moov.length, 'co64', boxes);
    for (final List<int> box in boxes) {
      final bool is64 = box[2] == 1;
      int p = box[0] + 8 + 4;
      if (p + 4 > moov.length) continue;
      final int count = _be32(moov, p);
      p += 4;
      for (int i = 0; i < count; i++) {
        if (is64) {
          if (p + 8 > moov.length) break;
          final int v = _be64(moov, p);
          if (v >= threshold) _putBe64(moov, p, v + delta);
          p += 8;
        } else {
          if (p + 4 > moov.length) break;
          final int v = _be32(moov, p);
          if (v >= threshold) _putBe32(moov, p, v + delta);
          p += 4;
        }
      }
    }
  }

  static void _collectBoxes(
      Uint8List buf, int start, int end, String type, List<List<int>> out) {
    int pos = start;
    while (pos + 8 <= end) {
      final int size = _be32(buf, pos);
      final String t = _type(buf, pos);
      if (size < 8 || pos + size > end) return;
      if (t == type) {
        out.add(<int>[pos, size, type == 'co64' ? 1 : 0]);
      } else if (_isContainer(t)) {
        int inside = pos + 8;
        if (t == 'meta') inside += 4;
        _collectBoxes(buf, inside, pos + size, type, out);
      }
      pos += size;
    }
  }

  static void _collectChunkOffsets(
      Uint8List buf, int start, int end, List<List<int>> out) {
    int pos = start;
    while (pos + 8 <= end) {
      final int size = _be32(buf, pos);
      final String t = _type(buf, pos);
      if (size < 8 || pos + size > end) return;
      if (t == 'stco' || t == 'co64') {
        final bool is64 = t == 'co64';
        int p = pos + 8 + 4;
        if (p + 4 > buf.length) return;
        int count = _be32(buf, p);
        p += 4;
        if (count > 10000) count = 10000;
        if (count < 0) count = 0;
        final List<int> offsets = <int>[];
        for (int i = 0; i < count; i++) {
          if (is64) {
            if (p + 8 > buf.length) break;
            offsets.add(_be64(buf, p));
            p += 8;
          } else {
            if (p + 4 > buf.length) break;
            offsets.add(_be32(buf, p));
            p += 4;
          }
        }
        out.add(offsets);
      } else if (_isContainer(t)) {
        int inside = pos + 8;
        if (t == 'meta') inside += 4;
        _collectChunkOffsets(buf, inside, pos + size, out);
      }
      pos += size;
    }
  }

  static bool _isContainer(String type) =>
      type == 'moov' ||
      type == 'trak' ||
      type == 'mdia' ||
      type == 'minf' ||
      type == 'stbl' ||
      type == 'udta' ||
      type == 'meta' ||
      type == 'ilst' ||
      type == 'edts';

  static Uint8List? _readAtomOrNull(Uint8List data, String type) {
    int pos = 0;
    while (pos + 8 <= data.length) {
      int size = _be32(data, pos);
      final String t = _type(data, pos);
      if (size == 1) {
        size = _be64(data, pos + 8);
      } else if (size == 0) {
        size = data.length - pos;
      }
      if (size < 8 || pos + size > data.length) return null;
      if (t == type) return Uint8List.sublistView(data, pos, pos + size);
      pos += size;
    }
    return null;
  }

  static Uint8List? _findIlst(Uint8List moov) {
    final List<Uint8List> moovChildren = _split(moov, 8, moov.length);
    final Uint8List? udta = _findChildList(moovChildren, 'udta');
    if (udta == null) return null;
    final Uint8List? meta = _findChildList(_split(udta, 8, udta.length), 'meta');
    if (meta == null || meta.length < 12) return null;
    return _findChild(meta, 12, meta.length, 'ilst');
  }

  static int _be32(Uint8List b, int off) =>
      (b[off] << 24) | (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3];

  static int _be64(Uint8List b, int off) =>
      (_be32(b, off) << 32) | (_be32(b, off + 4) & 0xFFFFFFFF);

  static void _putBe32(Uint8List b, int off, int v) {
    b[off] = (v >> 24) & 0xFF;
    b[off + 1] = (v >> 16) & 0xFF;
    b[off + 2] = (v >> 8) & 0xFF;
    b[off + 3] = v & 0xFF;
  }

  static void _putBe64(Uint8List b, int off, int v) {
    _putBe32(b, off, v >> 32);
    _putBe32(b, off + 4, v & 0xFFFFFFFF);
  }
}
