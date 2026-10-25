import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/tag/cover_art.dart';
import 'package:musicorganizer/core/tag/cover_reader.dart';
import 'package:musicorganizer/core/tag/flac.dart';
import 'package:musicorganizer/core/tag/id3.dart';

import '../support/gen.dart';

void main() {
  Uint8List mp3() => Uint8List.fromList(List<int>.filled(834, 0xFF));

  Uint8List flac() => concat(<Uint8List>[
        Uint8List.fromList(<int>[0x66, 0x4C, 0x61, 0x43]),
        Uint8List.fromList(<int>[0x80, 0, 0, 34]),
        Uint8List(34),
        Uint8List(64),
      ]);

  test('MP3 APIC 封面往返', () {
    final Uint8List jpeg = fakeJpeg(320, 240);
    final Uint8List png = fakePng(600, 600);
    Uint8List m = mp3();
    expect(CoverReader.has(m, '.mp3'), isFalse);
    expect(CoverReader.read(m, '.mp3'), isNull);
    m = Id3.rewrite(m, <String, String>{}, cover: jpeg);
    expect(CoverReader.has(m, '.mp3'), isTrue);
    expect(sameBytes(jpeg, CoverReader.read(m, '.mp3')!), isTrue);
    m = Id3.rewrite(m, <String, String>{}, cover: png);
    expect(sameBytes(png, CoverReader.read(m, '.mp3')!), isTrue);
    m = Id3.rewrite(m, <String, String>{}, cover: Uint8List(0));
    expect(CoverReader.has(m, '.mp3'), isFalse);
  });

  test('FLAC PICTURE 封面往返', () {
    final Uint8List jpeg = fakeJpeg(320, 240);
    Uint8List f = flac();
    expect(CoverReader.has(f, '.flac'), isFalse);
    f = Flac.rewrite(f, <String, String>{}, cover: jpeg);
    expect(CoverReader.has(f, '.flac'), isTrue);
    expect(sameBytes(jpeg, CoverReader.read(f, '.flac')!), isTrue);
    f = Flac.rewrite(f, <String, String>{}, cover: Uint8List(0));
    expect(CoverReader.has(f, '.flac'), isFalse);
  });

  test('格式识别与容错', () {
    expect(CoverArt.isJpeg(fakeJpeg(320, 240)), isTrue);
    expect(CoverArt.isPng(fakePng(600, 600)), isTrue);
    expect(CoverReader.read(Uint8List(4), '.mp3'), isNull);
  });
}
