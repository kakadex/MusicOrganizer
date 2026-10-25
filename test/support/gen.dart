/// 合成样本生成器（dart:typed_data 直写字节）—— 供标签编解码测试复用。
library;

import 'dart:typed_data';

/// 最小合法 JPEG（含 SOF0，带尺寸）。
Uint8List fakeJpeg(int w, int h) {
  final Uint8List sof = Uint8List.fromList(<int>[
    0xFF, 0xC0, 0x00, 0x11, 0x08,
    (h >> 8) & 0xFF, h & 0xFF,
    (w >> 8) & 0xFF, w & 0xFF,
    0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01,
  ]);
  return concat(<Uint8List>[
    Uint8List.fromList(<int>[0xFF, 0xD8]),
    sof,
    Uint8List.fromList(<int>[0xFF, 0xD9]),
  ]);
}

/// 最小 PNG 头（含 IHDR 尺寸）。
Uint8List fakePng(int w, int h) {
  return Uint8List.fromList(<int>[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52,
    (w >> 24) & 0xFF, (w >> 16) & 0xFF, (w >> 8) & 0xFF, w & 0xFF,
    (h >> 24) & 0xFF, (h >> 16) & 0xFF, (h >> 8) & 0xFF, h & 0xFF,
    8, 6, 0, 0, 0,
  ]);
}

Uint8List concat(List<Uint8List> parts) {
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

/// 生成 MP4 atom（4 字节大端 size + 4 字节 type + payload）。
Uint8List atom(String type, Uint8List payload) {
  final Uint8List out = Uint8List(8 + payload.length);
  final int size = out.length;
  out[0] = (size >> 24) & 0xFF;
  out[1] = (size >> 16) & 0xFF;
  out[2] = (size >> 8) & 0xFF;
  out[3] = size & 0xFF;
  for (int i = 0; i < 4; i++) {
    out[4 + i] = type.codeUnitAt(i);
  }
  out.setRange(8, 8 + payload.length, payload);
  return out;
}

Uint8List be32(int v) => Uint8List.fromList(<int>[
      (v >> 24) & 0xFF,
      (v >> 16) & 0xFF,
      (v >> 8) & 0xFF,
      v & 0xFF,
    ]);

Uint8List le32(int v) => Uint8List.fromList(<int>[
      v & 0xFF,
      (v >> 8) & 0xFF,
      (v >> 16) & 0xFF,
      (v >> 24) & 0xFF,
    ]);

Uint8List le16(int v) => Uint8List.fromList(<int>[v & 0xFF, (v >> 8) & 0xFF]);

Uint8List le64(int v) {
  final Uint8List out = Uint8List(8);
  for (int i = 0; i < 8; i++) {
    out[i] = (v >> (8 * i)) & 0xFF;
  }
  return out;
}

Uint8List ascii(String s) => Uint8List.fromList(s.codeUnits);

/// 造一个重复字节包（OGG 音频包样本）。
Uint8List packet(int seed, int size) {
  final Uint8List out = Uint8List(size);
  for (int i = 0; i < size; i++) {
    out[i] = (seed + i * 31) & 0xFF;
  }
  return out;
}

bool sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
