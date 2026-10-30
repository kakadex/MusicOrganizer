/// 封面图片「是不是完整的」判定（0.2.59）。
///
/// 作用：读封面先只读 256KB，只有能解出**完整**图片才不再补读。
/// 只判「能解出一半像素」是不够的——截断的 JPEG 同样能解出上半张图，
/// 用户看到的会是灰块 / 花屏。
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/tag/cover_art.dart';

/// 一个最小的完整 JPEG：SOI + APP0 + SOS 片段 + EOI。
Uint8List jpeg({bool complete = true, int pad = 64}) {
  final List<int> bytes = <int>[
    0xFF, 0xD8, // SOI
    0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00,
    0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
    0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00, // SOS
  ];
  for (int i = 0; i < pad; i++) {
    bytes.add(0x00);
  }
  if (complete) bytes.addAll(<int>[0xFF, 0xD9]); // EOI
  return Uint8List.fromList(bytes);
}

/// 最小 PNG：签名 + IHDR + IEND（中间补零，仅用于结尾标记判定）。
Uint8List png({bool complete = true}) {
  final List<int> b = <int>[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // 签名
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR
    0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x10, // 16×16
    0x08, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  ];
  if (complete) {
    b.addAll(<int>[0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]);
  }
  return Uint8List.fromList(b);
}

/// 最小 WebP：RIFF + 长度字段 + WEBP + VP8 块占位。
Uint8List webp({bool complete = true}) {
  final List<int> b = <int>[
    0x52, 0x49, 0x46, 0x46, // RIFF
    0x00, 0x00, 0x00, 0x00, // 长度占位，下面回填
    0x57, 0x45, 0x42, 0x50, // WEBP
    0x56, 0x50, 0x38, 0x20, // VP8
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  ];
  // RIFF 的长度字段 = 完整文件大小 - 8。
  // 截断时就先写好「完整」的长度再砍尾巴，校验方据此发现对不上。
  final int bodyLen = b.length - 8;
  b[4] = bodyLen & 0xFF;
  b[5] = (bodyLen >> 8) & 0xFF;
  b[6] = (bodyLen >> 16) & 0xFF;
  b[7] = (bodyLen >> 24) & 0xFF;
  if (!complete) b.removeRange(b.length - 4, b.length);
  return Uint8List.fromList(b);
}

void main() {
  test('完整 JPEG 判完整；少掉结尾 FFD9 的判截断', () {
    expect(CoverArt.isComplete(jpeg()), isTrue);
    expect(CoverArt.isComplete(jpeg(complete: false)), isFalse);
  });

  test('完整 PNG 判完整；缺 IEND 的判截断', () {
    expect(CoverArt.isComplete(png()), isTrue);
    expect(CoverArt.isComplete(png(complete: false)), isFalse);
  });

  test('WebP 按 RIFF 长度校验：长度对得上才算完整', () {
    expect(CoverArt.isComplete(webp()), isTrue);
    expect(CoverArt.isComplete(webp(complete: false)), isFalse);
  });

  test('不是图片 / 太短 / 空 一律不算完整', () {
    expect(CoverArt.isComplete(null), isFalse);
    expect(CoverArt.isComplete(Uint8List(0)), isFalse);
    expect(CoverArt.isComplete(Uint8List.fromList(<int>[1, 2, 3, 4, 5])), isFalse);
    expect(
        CoverArt.isComplete(Uint8List.fromList(
            List<int>.filled(64, 0x41))),
        isFalse);
  });
}
