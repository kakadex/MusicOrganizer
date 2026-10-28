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

  test('清空注释后读回仍为空（ID3v1 尾部不能顶回来）', () {
    Uint8List mp3 = withV1(mkMp3());
    mp3 = Id3.rewrite(mp3, <String, String>{
      'title': '测试歌名',
      'comment': 'Packed by Bilibili XCoder v2.0.2',
    });
    expect(Id3.read(mp3).get('comment'), 'Packed by Bilibili XCoder v2.0.2');

    // 清空注释：写端删了 COMM 帧，但文件尾的 ID3v1 还留着同一段文字，
    // 读端会从 v1 把它补回来 —— 「删除标签」就永远失败
    mp3 = Id3.rewrite(mp3, <String, String>{'comment': ''});
    expect(Id3.read(mp3).get('comment'), '',
        reason: '清空后不能被 ID3v1 尾部顶回来');
  });

  test('删除全部标签后回读全为空', () {
    Uint8List mp3 = withV1(mkMp3(), track: 7);
    mp3 = Id3.rewrite(mp3, <String, String>{
      'title': '测试歌名',
      'artist': '测试歌手',
      'album': '测试专辑',
      'year': '1989',
      'track': '3',
      'genre': '摇滚',
      'comment': 'Packed by Bilibili XCoder v2.0.2',
    });
    // 与「清空标签」功能一致：每个字段写空串
    mp3 = Id3.rewrite(mp3, <String, String>{
      for (final String k in Tags.keys) k: '',
    });
    for (final String k in Tags.keys) {
      expect(Id3.read(mp3).get(k), '', reason: '清空后 $k 不该还在');
    }
  });

  test('清空注释不能顺手抹掉 ID3v1 的音轨号', () {
    Uint8List mp3 = withV1(mkMp3(), track: 7);
    mp3 = Id3.rewrite(mp3, <String, String>{'comment': 'old'});
    mp3 = Id3.rewrite(mp3, <String, String>{'comment': ''});
    final int base = mp3.length - 128;
    expect(mp3[base + 125], 0, reason: 'ID3v1.1 的音轨高字节必须是 0');
    expect(mp3[base + 126], 7, reason: '音轨号被注释的清理波及了');
  });

  test('清空歌词要连 SYLT（同步歌词）一起清', () {
    final Uint8List mp3 = mp3WithFrames(<String, List<int>>{
      // SYLT：编码 + 语言 + 时间格式(2=毫秒) + 内容类型 + 描述\0 + (文本\0 + 毫秒)
      'SYLT': <int>[
        3, ...'chi'.codeUnits, 2, 1, 0,
        ...utf8.encode('第一句'), 0, 0, 0, 0x03, 0xE8,
      ],
    });
    expect(Id3.read(mp3).get('lyrics'), contains('第一句'));

    final Uint8List cleared = Id3.rewrite(mp3, <String, String>{'lyrics': ''});
    expect(Id3.read(cleared).get('lyrics'), '',
        reason: '只删 USLT 不删 SYLT，歌词就永远清不掉');
  });

  test('清空歌词要连 TXXX(LYRICS) 一起清', () {
    final Uint8List mp3 = mp3WithFrames(<String, List<int>>{
      'TXXX': <int>[3, ...utf8.encode('LYRICS'), 0, ...utf8.encode('旧歌词')],
    });
    expect(Id3.read(mp3).get('lyrics'), '旧歌词');

    final Uint8List cleared = Id3.rewrite(mp3, <String, String>{'lyrics': ''});
    expect(Id3.read(cleared).get('lyrics'), '');
  });
}

/// 手工拼一个 ID3v2.4 标签（只给帧数据体，帧头与填充自动生成）。
Uint8List mp3WithFrames(Map<String, List<int>> frames) {
  final BytesBuilder body = BytesBuilder();
  for (final MapEntry<String, List<int>> e in frames.entries) {
    final List<int> data = e.value;
    body.add(Id3.asciiBytes(e.key));
    body.add(<int>[
      (data.length >> 21) & 0x7F,
      (data.length >> 14) & 0x7F,
      (data.length >> 7) & 0x7F,
      data.length & 0x7F,
    ]);
    body.add(<int>[0, 0]);
    body.add(data);
  }
  final int size = body.length + 64;
  return Uint8List.fromList(<int>[
    0x49, 0x44, 0x33, 4, 0, 0, //
    (size >> 21) & 0x7F, (size >> 14) & 0x7F, (size >> 7) & 0x7F, size & 0x7F,
    ...body.toBytes(),
    ...List<int>.filled(64, 0),
    ...List<int>.filled(1024, 0xFF),
  ]);
}

/// 在音频字节末尾挂一个 ID3v1 标签（title/artist/album/year 留空）。
Uint8List withV1(Uint8List audio,
    {String comment = 'Packed by Bilibili XCoder v2.0.2', int track = 0}) {
  final Uint8List tail = Uint8List(128);
  tail[0] = 0x54; // T
  tail[1] = 0x41; // A
  tail[2] = 0x47; // G
  for (int i = 0; i < comment.length && i < 28; i++) {
    tail[97 + i] = comment.codeUnitAt(i);
  }
  if (track > 0) {
    tail[125] = 0;
    tail[126] = track;
  }
  return Uint8List.fromList(<int>[...audio, ...tail]);
}
