import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/tag/flac.dart';
import 'package:musicorganizer/core/tag/id3.dart';
import 'package:musicorganizer/core/tag/tag_io.dart';

import '../support/gen.dart';

void main() {
  test('MP3 没有 ID3 标签 —— 头部就够', () {
    final Uint8List plain =
        Uint8List.fromList(List<int>.filled(4096, 0xFF));
    expect(TagIO.tagFitsCopy(plain, '.mp3'), isTrue);
  });

  test('MP3 写好 ID3 —— 完整文件判定为够', () {
    Uint8List mp3 = Uint8List.fromList(List<int>.filled(4096, 0xFF));
    mp3 = Id3.rewrite(mp3, <String, String>{'title': '头部测试', 'artist': '测试歌手'});
    expect(TagIO.tagFitsCopy(mp3, '.mp3'), isTrue);
    expect(Id3.read(mp3).get('title'), '头部测试');
  });

  test('MP3 头部被截断在标签中间 —— 判为不够', () {
    Uint8List mp3 = Uint8List.fromList(List<int>.filled(4096, 0xFF));
    mp3 = Id3.rewrite(mp3, <String, String>{'title': '头部测试', 'artist': '测试歌手'});
    final int tagLen = mp3.length;
    final int n = (12 > (10 + (tagLen - 4096) ~/ 2)) ? 12 : (10 + (tagLen - 4096) ~/ 2);
    final Uint8List cut = Uint8List.fromList(mp3.sublist(0, n));
    expect(TagIO.tagFitsCopy(cut, '.mp3'), isFalse);
  });

  test('FLAC 有 Vorbis Comment —— 判定为够', () {
    Uint8List flac = concat(<Uint8List>[
      Uint8List.fromList(<int>[0x66, 0x4C, 0x61, 0x43]),
      Uint8List.fromList(<int>[0x80, 0, 0, 34]),
      Uint8List(34),
      Uint8List.fromList(List<int>.filled(8192, 0x11)),
    ]);
    flac = Flac.rewrite(flac, <String, String>{'title': 'FLAC 标题'});
    expect(TagIO.tagFitsCopy(flac, '.flac'), isTrue);
    expect(Flac.read(flac).get('title'), 'FLAC 标题');
  });

  test('FLAC 只留 6 字节 —— 判为不够', () {
    final Uint8List flac = Uint8List.fromList(<int>[0x66, 0x4C, 0x61, 0x43, 0x80, 0x00]);
    expect(TagIO.tagFitsCopy(flac, '.flac'), isFalse);
  });

  test('M4A/MP4 —— moov 可能在尾部，一律判为不够', () {
    final Uint8List plain =
        Uint8List.fromList(List<int>.filled(4096, 0xFF));
    expect(TagIO.tagFitsCopy(plain, '.m4a'), isFalse);
  });

  test('encoding=0 却存 GBK 的中文标签 —— 兜底解码', () {
    expect(Id3.decodeLatin1OrGbk(Uint8List.fromList(<int>[208, 187, 246, 170, 183, 230])),
        '谢霆锋');
    expect(Id3.decodeLatin1OrGbk(ascii('Hello')), 'Hello');
    expect(Id3.decodeLatin1OrGbk(Uint8List.fromList(<int>[0x63, 0x61, 0x66, 0xE9])), 'café');
    expect(Id3.decodeLatin1OrGbk(Uint8List.fromList(<int>[187, 198, 213, 247])), '黄征');
  });
}
