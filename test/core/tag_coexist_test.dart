/// 同一个 MP3 里 ID3v2 / APEv2 / ID3v1 三套标签并存时的读写规则（T-11）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart' hide Tags;
import 'package:musicorganizer/core/model/tags.dart';
import 'package:musicorganizer/core/tag/ape.dart';
import 'package:musicorganizer/core/tag/id3.dart';

import '../support/gen.dart';

/// 造一个 APEv2 标签（不带 header，footer 在最后）。
Uint8List apeTag(Map<String, String> values) {
  final BytesBuilder items = BytesBuilder();
  values.forEach((String k, String v) {
    final Uint8List key = ascii(k);
    final Uint8List val = Uint8List.fromList(utf8.encode(v));
    items.add(le32(val.length));
    items.add(le32(0));
    items.add(key);
    items.add(Uint8List.fromList(<int>[0]));
    items.add(val);
  });
  final Uint8List body = items.toBytes();
  final BytesBuilder footer = BytesBuilder();
  footer.add(ascii('APETAGEX'));
  footer.add(le32(2000)); // version
  footer.add(le32(body.length + 32)); // tagSize 含 footer
  footer.add(le32(values.length));
  footer.add(le32(0)); // flags：没有 header
  footer.add(Uint8List(8));
  return concat(<Uint8List>[body, footer.toBytes()]);
}

/// 造一个 ID3v1（Latin-1，字段各自定长）。
Uint8List id3v1({
  String title = '',
  String artist = '',
  String album = '',
  String year = '',
  String comment = '',
}) {
  final Uint8List out = Uint8List(128);
  void put(int start, int length, String v) {
    final List<int> codes = v.codeUnits.take(length).toList();
    for (int i = 0; i < codes.length; i++) {
      out[start + i] = codes[i] & 0xFF;
    }
  }

  out[0] = 0x54;
  out[1] = 0x41;
  out[2] = 0x47;
  put(3, 30, title);
  put(33, 30, artist);
  put(63, 30, album);
  put(93, 4, year);
  put(97, 30, comment);
  return out;
}

String id3v1Field(Uint8List data, int start, int length) {
  int end = start;
  while (end < start + length && data[end] != 0) {
    end++;
  }
  return String.fromCharCodes(data, start, end);
}

void main() {
  /// 无标签的「音频」字节；内容不需要是真 MPEG，读写只看标签结构。
  final Uint8List audio = Uint8List.fromList(List<int>.filled(1024, 0xFF));

  Uint8List fullMp3() {
    final Uint8List v2 =
        Id3.rewrite(audio, <String, String>{'title': 'ID3标题', 'artist': 'ID3歌手'});
    return concat(<Uint8List>[
      v2,
      apeTag(<String, String>{'Title': 'APE标题', 'Album': 'APE专辑'}),
      // v1 只有 Latin-1：造数据时就得用 ASCII，否则测的是乱码本身
      id3v1(title: 'V1Title', artist: 'V1Artist', album: 'V1Album', year: '1999'),
    ]);
  }

  test('读取优先级：ID3v2 > APEv2 > ID3v1（只补空字段）', () {
    final Tags t = Id3.read(fullMp3());
    expect(t.get('title'), 'ID3标题', reason: 'v2 有值就不能被 APE / v1 覆盖');
    expect(t.get('artist'), 'ID3歌手');
    expect(t.get('album'), 'APE专辑', reason: 'v2 没有的字段回落到 APE');
    expect(t.get('year'), '1999', reason: 'APE 也没有才回落到 v1');
  });

  test('写入时同步 APEv2：两套标签不再各说各话', () {
    final Uint8List out =
        Id3.rewrite(fullMp3(), <String, String>{'album': '新专辑'});
    expect(Id3.read(out).get('album'), '新专辑');
    expect(Ape.readTail(out).get('album'), '新专辑');
    // 没动的字段也保持一致
    expect(Ape.readTail(out).get('title'), 'APE标题');
  });

  test('ID3v1 只在纯 ASCII 时同步；中文值保持原样（不写乱码）', () {
    final Uint8List ascii =
        Id3.rewrite(fullMp3(), <String, String>{'artist': 'NewArtist'});
    final int base = ascii.length - 128;
    expect(id3v1Field(ascii, base + 33, 30), 'NewArtist');

    final Uint8List chinese =
        Id3.rewrite(fullMp3(), <String, String>{'artist': '新歌手'});
    final int base2 = chinese.length - 128;
    expect(id3v1Field(chinese, base2 + 33, 30), 'V1Artist',
        reason: 'v1 只有 Latin-1，写中文会变成乱码，宁可保留原值');
  });

  test('没有 APE 标签的 MP3 不会被凭空加一个', () {
    final Uint8List plain = Id3.rewrite(audio, <String, String>{'title': '只有ID3'});
    expect(Ape.hasTailTag(plain), isFalse);
    final Uint8List out =
        Id3.rewrite(plain, <String, String>{'album': '专辑'});
    expect(Ape.hasTailTag(out), isFalse);
    expect(Id3.read(out).get('album'), '专辑');
  });

  test('APEv2 里的歌词也能读出来（v2 的 USLT 为空时）', () {
    final Uint8List data = concat(<Uint8List>[
      Id3.rewrite(audio, <String, String>{'title': '有APE歌词'}),
      apeTag(<String, String>{'Lyrics': '[00:01]第一句'}),
    ]);
    expect(Id3.read(data).get(Tags.lyrics), '[00:01]第一句');
  });
}
