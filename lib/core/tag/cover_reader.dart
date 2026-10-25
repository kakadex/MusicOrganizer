/// 读内嵌封面（MP3 APIC / FLAC PICTURE / MP4 covr）—— 移植自旧 core/CoverReader.java。
///
/// 只读，纯字节，失败也只是「没有封面」，绝不拖累写入逻辑。
library;

import 'dart:typed_data';

/// 内嵌封面读取（纯 Dart）。
abstract final class CoverReader {
  /// 单张封面最多读这么多字节。
  static const int maxBytes = 12 * 1024 * 1024;

  static bool has(Uint8List data, String ext) => _read(data, ext, true) != null;

  static Uint8List? read(Uint8List data, String ext) => _read(data, ext, false);

  static Uint8List? _read(Uint8List data, String ext, bool probeOnly) {
    if (data.length < 16) return null;
    if (ext == '.mp3') return _readId3(data, probeOnly);
    if (ext == '.flac') return _readFlac(data, probeOnly);
    if (ext == '.m4a' || ext == '.mp4') return _readMp4(data, probeOnly);
    return null;
  }

  static Uint8List? _readId3(Uint8List data, bool probeOnly) {
    if (data.length < 10 ||
        data[0] != 0x49 ||
        data[1] != 0x44 ||
        data[2] != 0x33) {
      return null;
    }
    final int version = data[3];
    final int flags = data[5];
    final int size = _syncsafe(data, 6);
    int pos = 10;
    final int tagEnd = 10 + size;
    if ((flags & 0x40) != 0) {
      if (pos + 4 > data.length) return null;
      final int extSize = version >= 4 ? _syncsafe(data, pos) : _be32(data, pos);
      pos += 4 + extSize;
    }
    while (pos + 10 <= tagEnd && pos + 10 <= data.length) {
      if (data[pos] == 0) break;
      final String id = String.fromCharCodes(data.sublist(pos, pos + 4));
      final int frameSize =
          version >= 4 ? _syncsafe(data, pos + 4) : _be32(data, pos + 4);
      if (frameSize <= 0 || pos + 10 + frameSize > tagEnd || frameSize > maxBytes + 1024) {
        return null;
      }
      if (id == 'APIC') {
        if (probeOnly) return Uint8List(0);
        return parseApic(Uint8List.sublistView(data, pos + 10, pos + 10 + frameSize));
      }
      pos += 10 + frameSize;
    }
    return null;
  }

  /// APIC：编码(1) + MIME(0 结尾) + 图片类型(1) + 描述(0 结尾) + 图片数据。
  static Uint8List? parseApic(Uint8List frame) {
    if (frame.length < 4) return null;
    final int enc = frame[0];
    int p = 1;
    while (p < frame.length && frame[p] != 0) {
      p++;
    }
    if (p >= frame.length) return null;
    p++; // MIME 结尾 0
    if (p >= frame.length) return null;
    p++; // 图片类型
    if (enc == 1 || enc == 2) {
      while (p + 1 < frame.length && !(frame[p] == 0 && frame[p + 1] == 0)) {
        p += 2;
      }
      p += 2;
    } else {
      while (p < frame.length && frame[p] != 0) {
        p++;
      }
      p++;
    }
    if (p >= frame.length) return null;
    final int len = (frame.length - p) < maxBytes ? frame.length - p : maxBytes;
    return Uint8List.fromList(frame.sublist(p, p + len));
  }

  static Uint8List? _readFlac(Uint8List data, bool probeOnly) {
    if (data.length < 4 ||
        data[0] != 0x66 ||
        data[1] != 0x4C ||
        data[2] != 0x61 ||
        data[3] != 0x43) {
      return null;
    }
    int pos = 4;
    while (pos + 4 <= data.length) {
      final int b = data[pos];
      final bool last = (b & 0x80) != 0;
      final int type = b & 0x7F;
      final int blockLen =
          (data[pos + 1] << 16) | (data[pos + 2] << 8) | data[pos + 3];
      if (type == 6) {
        if (probeOnly) return Uint8List(0);
        if (blockLen > maxBytes + 4096) return null;
        return parseFlacPicture(
            Uint8List.sublistView(data, pos + 4, pos + 4 + blockLen));
      }
      if (last) return null;
      pos += 4 + blockLen;
    }
    return null;
  }

  /// FLAC PICTURE：type(4) mimeLen(4) mime descLen(4) desc w(4) h(4) depth(4) colors(4) dataLen(4) data。
  static Uint8List? parseFlacPicture(Uint8List block) {
    if (block.length < 32) return null;
    int p = 4;
    final int mimeLen = _be32(block, p);
    p += 4;
    if (mimeLen < 0 || p + mimeLen > block.length) return null;
    p += mimeLen;
    if (p + 4 > block.length) return null;
    final int descLen = _be32(block, p);
    p += 4;
    if (descLen < 0 || p + descLen > block.length) return null;
    p += descLen;
    p += 16;
    if (p + 4 > block.length) return null;
    final int dataLen = _be32(block, p);
    p += 4;
    if (dataLen <= 0 || p + dataLen > block.length) return null;
    final int len = dataLen < maxBytes ? dataLen : maxBytes;
    return Uint8List.fromList(block.sublist(p, p + len));
  }

  static Uint8List? _readMp4(Uint8List data, bool probeOnly) {
    final Uint8List? moov = _findTopAtom(data, 'moov');
    if (moov == null) return null;
    final List<int>? udta = _findChild(moov, 8, moov.length, 'udta');
    if (udta == null) return null;
    final List<int>? meta =
        _findChild(moov, udta[0] + 8, udta[0] + udta[1], 'meta');
    if (meta == null) return null;
    final List<int>? ilst =
        _findChild(moov, meta[0] + 12, meta[0] + meta[1], 'ilst');
    if (ilst == null) return null;
    final List<int>? covr =
        _findChild(moov, ilst[0] + 8, ilst[0] + ilst[1], 'covr');
    if (covr == null) return null;
    final List<int>? dataAtom =
        _findChild(moov, covr[0] + 8, covr[0] + covr[1], 'data');
    if (dataAtom == null) return probeOnly ? Uint8List(0) : null;
    if (probeOnly) return Uint8List(0);
    final int payloadLen = dataAtom[1] - 16;
    if (payloadLen <= 0) return null;
    final int len = payloadLen < maxBytes ? payloadLen : maxBytes;
    return Uint8List.fromList(
        data.sublist(dataAtom[0] + 16, dataAtom[0] + 16 + len));
  }

  static Uint8List? _findTopAtom(Uint8List data, String type) {
    int pos = 0;
    while (pos + 8 <= data.length) {
      int size = _be32(data, pos);
      final String t = String.fromCharCodes(data.sublist(pos + 4, pos + 8));
      if (size == 0) size = data.length - pos;
      if (size < 8 || pos + size > data.length) return null;
      if (t == type) return Uint8List.fromList(data.sublist(pos, pos + size));
      pos += size;
    }
    return null;
  }

  static List<int>? _findChild(
      Uint8List buf, int start, int end, String type) {
    int pos = start;
    while (pos + 8 <= end) {
      final int size = _be32(buf, pos);
      final String t = String.fromCharCodes(buf.sublist(pos + 4, pos + 8));
      if (size < 8 || pos + size > end) return null;
      if (t == type) return <int>[pos, size];
      pos += size;
    }
    return null;
  }

  static int _syncsafe(Uint8List b, int off) =>
      ((b[off] & 0x7F) << 21) |
      ((b[off + 1] & 0x7F) << 14) |
      ((b[off + 2] & 0x7F) << 7) |
      (b[off + 3] & 0x7F);

  static int _be32(Uint8List b, int off) =>
      (b[off] << 24) | (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3];
}
