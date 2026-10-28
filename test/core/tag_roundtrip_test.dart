import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart' hide Tags;
import 'package:musicorganizer/core/model/tags.dart';
import 'package:musicorganizer/core/tag/flac.dart';
import 'package:musicorganizer/core/tag/id3.dart';

import '../support/gen.dart';

void main() {
  Uint8List mkMp3() => Uint8List.fromList(List<int>.filled(2048, 0xFF));

  test('专辑艺术家不与艺术家互相覆盖（ID3 / FLAC）', () {
    Uint8List mp3 = mkMp3();
    mp3 = Id3.rewrite(mp3, <String, String>{
      'artist': '周杰伦',
      'albumArtist': '群星',
      'album': '合辑',
    });
    final Tags t = Id3.read(mp3);
    expect(t.get('artist'), '周杰伦');
    expect(t.get('albumArtist'), '群星');
    expect(t.get('album'), '合辑');

    // 只改专辑艺术家，歌手不能被动到
    mp3 = Id3.rewrite(mp3, <String, String>{'albumArtist': '群星二号'});
    expect(Id3.read(mp3).get('albumArtist'), '群星二号');
    expect(Id3.read(mp3).get('artist'), '周杰伦');
  });

  test('清空歌手后读回仍为空（专辑艺术家不该顶上）', () {
    Uint8List mp3 = mkMp3();
    mp3 = Id3.rewrite(mp3, <String, String>{
      'artist': '周杰伦',
      'albumArtist': '群星',
    });
    expect(Id3.read(mp3).get('artist'), '周杰伦');
    expect(Id3.read(mp3).get('albumArtist'), '群星');

    // 清空歌手（写空 TPE1）：读回来 artist 必须还是空，不能被 TPE2 填回
    mp3 = Id3.rewrite(mp3, <String, String>{'artist': ''});
    expect(Id3.read(mp3).get('artist'), '');
    expect(Id3.read(mp3).get('albumArtist'), '群星');
  });

  test('ID3v2.3 首次写入全字段', () {
    Uint8List mp3 = mkMp3();
    mp3 = Id3.rewrite(mp3, <String, String>{
      'title': '原歌名',
      'artist': '原歌手',
      'album': '原专辑',
      'year': '2020',
      'track': '3',
      'genre': 'Pop',
      'comment': '备注',
    });
    final Tags t = Id3.read(mp3);
    expect(t.get('title'), '原歌名');
    expect(t.get('artist'), '原歌手');
    expect(t.get('album'), '原专辑');
    expect(t.get('year'), '2020');
  });

  test('只改 title —— 其余字段必须保留（合并语义）', () {
    Uint8List mp3 = mkMp3();
    mp3 = Id3.rewrite(mp3, <String, String>{
      'title': '原歌名',
      'artist': '原歌手',
      'album': '原专辑',
      'genre': 'Pop',
    });
    mp3 = Id3.rewrite(mp3, <String, String>{'title': '新歌名'});
    final Tags t = Id3.read(mp3);
    expect(t.get('title'), '新歌名');
    expect(t.get('artist'), '原歌手');
    expect(t.get('album'), '原专辑');
    expect(t.get('genre'), 'Pop');
  });

  test('只写歌词 —— 其它字段保留', () {
    Uint8List mp3 = mkMp3();
    mp3 = Id3.rewrite(mp3, <String, String>{'title': '新歌名', 'artist': '原歌手'});
    const String text = '[00:01.00]第一行\n[00:05.50]第二行 中文';
    mp3 = Id3.rewrite(mp3, <String, String>{'lyrics': text});
    final Tags t = Id3.read(mp3);
    expect(t.get('lyrics'), text);
    expect(t.get('title'), '新歌名');
    expect(t.get('artist'), '原歌手');
  });

  test('清除歌词（空字符串）', () {
    Uint8List mp3 = mkMp3();
    mp3 = Id3.rewrite(mp3, <String, String>{
      'album': '原专辑',
      'lyrics': '[00:01.00]A',
    });
    mp3 = Id3.rewrite(mp3, <String, String>{'lyrics': ''});
    final Tags t = Id3.read(mp3);
    expect(t.get('lyrics'), '');
    expect(t.get('album'), '原专辑');
  });

  test('FLAC LYRICS 写入 + 其它 Vorbis 注释保留', () {
    Uint8List flac = concat(<Uint8List>[
      Uint8List.fromList(<int>[0x66, 0x4C, 0x61, 0x43]),
      Uint8List.fromList(<int>[0x80, 0, 0, 34]),
      Uint8List(34),
      Uint8List.fromList(List<int>.filled(4096, 0x11)),
    ]);
    flac = Flac.rewrite(flac, <String, String>{'title': 'F歌名', 'artist': 'F歌手'});
    expect(Flac.read(flac).get('title'), 'F歌名');
    const String text = '[00:01.00]第一行\n[00:05.50]第二行 中文';
    flac = Flac.rewrite(flac, <String, String>{'lyrics': text});
    final Tags ft = Flac.read(flac);
    expect(ft.get('lyrics'), text);
    expect(ft.get('artist'), 'F歌手');
  });

  test('MP3 封面（APIC）写入 / 替换 / 删除', () {
    Uint8List mp3 = mkMp3();
    mp3 = Id3.rewrite(mp3, <String, String>{'title': '新歌名'});
    final Uint8List jpeg = fakeJpeg(120, 90);
    expect(Id3.hasCover(mp3), isFalse);
    mp3 = Id3.rewrite(mp3, <String, String>{}, cover: jpeg);
    expect(Id3.hasCover(mp3), isTrue);
    expect(Id3.read(mp3).get('title'), '新歌名');
    final Uint8List png = fakePng(200, 200);
    mp3 = Id3.rewrite(mp3, <String, String>{}, cover: png);
    expect(Id3.hasCover(mp3), isTrue);
    expect(Id3.read(mp3).get('title'), '新歌名');
    mp3 = Id3.rewrite(mp3, <String, String>{}, cover: Uint8List(0));
    expect(Id3.hasCover(mp3), isFalse);
    expect(Id3.read(mp3).get('title'), '新歌名');
  });

  test('FLAC 封面（PICTURE 块）写入 / 删除', () {
    Uint8List flac = concat(<Uint8List>[
      Uint8List.fromList(<int>[0x66, 0x4C, 0x61, 0x43]),
      Uint8List.fromList(<int>[0x80, 0, 0, 34]),
      Uint8List(34),
      Uint8List.fromList(List<int>.filled(4096, 0x11)),
    ]);
    flac = Flac.rewrite(flac, <String, String>{'title': 'F歌名'});
    final Uint8List jpeg = fakeJpeg(120, 90);
    expect(Flac.hasPicture(flac), isFalse);
    flac = Flac.rewrite(flac, <String, String>{}, cover: jpeg);
    expect(Flac.hasPicture(flac), isTrue);
    expect(Flac.read(flac).get('title'), 'F歌名');
    flac = Flac.rewrite(flac, <String, String>{}, cover: Uint8List(0));
    expect(Flac.hasPicture(flac), isFalse);
  });

  test('FLAC 改注释替换旧 COMMENT、清空能清掉', () {
    // 造一个「已有 COMMENT 键」的 FLAC（外部工具常写 COMMENT 而不是 DESCRIPTION）
    final BytesBuilder body = BytesBuilder();
    final Uint8List vendor = ascii('test-vendor');
    body.add(le32(vendor.length));
    body.add(vendor);
    final Uint8List entry = Uint8List.fromList(utf8.encode('COMMENT=旧注释'));
    body.add(le32(1));
    body.add(le32(entry.length));
    body.add(entry);
    final Uint8List vc = body.toBytes();
    final BytesBuilder out = BytesBuilder();
    out.add(ascii('fLaC'));
    out.addByte(0x84); // type 4（VORBIS_COMMENT）+ 末位块
    out.add(<int>[(vc.length >> 16) & 0xFF, (vc.length >> 8) & 0xFF, vc.length & 0xFF]);
    out.add(vc);
    out.add(Uint8List.fromList(List<int>.filled(256, 0x11)));
    Uint8List flac = out.toBytes();

    expect(Flac.read(flac).get('comment'), '旧注释');
    // 改注释：旧的 COMMENT 要被替换，不能残留成两套字段
    flac = Flac.rewrite(flac, <String, String>{'comment': '新注释'});
    expect(Flac.read(flac).get('comment'), '新注释');
    // 清空注释：读回必须为空
    flac = Flac.rewrite(flac, <String, String>{'comment': ''});
    expect(Flac.read(flac).get('comment'), '');
  });
}
