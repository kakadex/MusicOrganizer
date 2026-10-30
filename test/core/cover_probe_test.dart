/// 读封面时的「先读 256KB」快路径（0.2.59）。
///
/// 目标：封面在文件头一小段里时只读 256KB；被截断才补读到 512KB / 2MB。
/// 这里用假存储记录每次 `headBytes` 请求了多大，直接断言读盘量。
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/fs/file_store.dart';
import 'package:musicorganizer/core/model/vfile.dart';
import 'package:musicorganizer/core/scan/scanner.dart';

/// 只实现 `headBytes`，并记录每次请求的字节数。
class _MemStore implements FileStore {
  _MemStore(this.data);

  final Uint8List data;

  /// 每次 headBytes 请求的上限（按调用顺序）。
  final List<int> requests = <int>[];

  @override
  Future<Uint8List> headBytes(VFile f, int maxBytes) async {
    requests.add(maxBytes);
    final int end = maxBytes < data.length ? maxBytes : data.length;
    return Uint8List.sublistView(data, 0, end);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 一个带 ID3v2.3 APIC 的假 MP3：封面是 [coverSize] 字节的完整 JPEG。
Uint8List fakeMp3({required int coverSize}) {
  // JPEG：SOI + APP0 头 + 填充 + EOI，长度正好 coverSize
  final List<int> jpeg = <int>[0xFF, 0xD8, 0xFF, 0xE0];
  while (jpeg.length < coverSize - 2) {
    jpeg.add(0x00);
  }
  jpeg.addAll(<int>[0xFF, 0xD9]);

  final List<int> frame = <int>[
    0x00, // 编码
    0x69, 0x6D, 0x61, 0x67, 0x65, 0x2F, 0x6A, 0x70, 0x65, 0x67, 0x00, // image/jpeg
    0x03, // 图片类型：front cover
    0x00, // 描述：空串
  ];
  frame.addAll(jpeg);

  final List<int> body = <int>[
    0x41, 0x50, 0x49, 0x43, // 'APIC'
    (frame.length >> 24) & 0xFF,
    (frame.length >> 16) & 0xFF,
    (frame.length >> 8) & 0xFF,
    frame.length & 0xFF,
    0x00, 0x00, // 帧标志
  ];
  body.addAll(frame);

  final int tagSize = body.length;
  final List<int> out = <int>[
    0x49, 0x44, 0x33, // 'ID3'
    0x03, 0x00, // 版本 2.3
    0x00, // 标志
    (tagSize >> 21) & 0x7F,
    (tagSize >> 14) & 0x7F,
    (tagSize >> 7) & 0x7F,
    tagSize & 0x7F,
  ];
  out.addAll(body);
  // 后面随便补一点音频数据，模拟真实文件
  out.addAll(List<int>.filled(4096, 0x55));
  return Uint8List.fromList(out);
}

VFile song(int size) =>
    VFile(docId: 'r/示例歌名.mp3', parentId: 'r', name: '示例歌名.mp3', size: size);

void main() {
  test('封面落在前 256KB：只读一次 256KB，不补读', () async {
    final Uint8List data = fakeMp3(coverSize: 60 * 1024);
    final _MemStore store = _MemStore(data);
    final Uint8List? art =
        await Scanner.readCover(store, song(data.length));

    expect(art, isNotNull);
    expect(art!.length, 60 * 1024);
    expect(store.requests, <int>[Scanner.coverProbeBytes]);
  });

  test('封面被 256KB 截断：补读一次更大的一块，结果仍然完整', () async {
    // 封面 300KB > 256KB，第一次必然读不全
    final Uint8List data = fakeMp3(coverSize: 300 * 1024);
    final _MemStore store = _MemStore(data);
    final Uint8List? art =
        await Scanner.readCover(store, song(data.length));

    expect(art, isNotNull);
    expect(art!.length, 300 * 1024);
    expect(store.requests.first, Scanner.coverProbeBytes);
    expect(store.requests.length, greaterThan(1),
        reason: '被截断后必须补读，不能拿半张图');
    expect(store.requests.last, greaterThanOrEqualTo(512 * 1024));
  });

  test('文件本身就不到 256KB 且没有封面：只读一次就收手', () async {
    final Uint8List data = Uint8List.fromList(List<int>.filled(4096, 0x55));
    final _MemStore store = _MemStore(data);
    final Uint8List? art = await Scanner.readCover(store, song(data.length));

    expect(art, isNull);
    expect(store.requests, <int>[Scanner.coverProbeBytes]);
  });
}
