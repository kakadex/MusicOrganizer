import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart' hide Tags;
import 'package:musicorganizer/core/model/tags.dart';
import 'package:musicorganizer/core/tag/mp4.dart';

import '../support/gen.dart';

Uint8List synth(bool moovFirst) {
  final Uint8List ftyp =
      atom('ftyp', concat(<Uint8List>[ascii('M4A '), be32(0x200), ascii('M4A mp42')]));
  final Uint8List mdatPayload = Uint8List(64);
  for (int i = 0; i < mdatPayload.length; i++) {
    mdatPayload[i] = (i * 3) & 0xFF;
  }
  final Uint8List mdat = atom('mdat', mdatPayload);
  Uint8List moov = buildMoov(0);
  final int mdatPayloadOffset =
      moovFirst ? ftyp.length + moov.length + 8 : ftyp.length + 8;
  moov = buildMoov(mdatPayloadOffset);
  final BytesBuilder out = BytesBuilder();
  out.add(ftyp);
  if (moovFirst) {
    out.add(moov);
    out.add(mdat);
  } else {
    out.add(mdat);
    out.add(moov);
  }
  return out.toBytes();
}

Uint8List buildMoov(int chunkOffset) {
  final Uint8List stco =
      atom('stco', concat(<Uint8List>[be32(0), be32(1), be32(chunkOffset)]));
  return atom('moov', concat(<Uint8List>[
    atom('mvhd', Uint8List(100)),
    atom('trak', atom('mdia', atom('minf', atom('stbl', stco)))),
  ]));
}

int mdatPayloadOffset(Uint8List data) {
  int pos = 0;
  while (pos + 8 <= data.length) {
    final int size = (data[pos] << 24) | (data[pos + 1] << 16) | (data[pos + 2] << 8) | data[pos + 3];
    final String type = String.fromCharCodes(data.sublist(pos + 4, pos + 8));
    if (type == 'mdat') return pos + 8;
    if (size <= 0) break;
    pos += size;
  }
  return -1;
}

void main() {
  test('moov 在前：stco 偏移必须跟着挪', () {
    Uint8List f = synth(true);
    final int beforeOffset = Mp4.chunkOffsets(f)[0];
    final int beforeLen = f.length;
    expect(beforeOffset, mdatPayloadOffset(f));
    f = Mp4.write(f, <String, String>{'title': '晴天', 'artist': '周杰伦'});
    final Tags tags = Mp4.read(f);
    expect(tags.get('title'), '晴天');
    expect(tags.get('artist'), '周杰伦');
    expect(f.length, greaterThan(beforeLen));
    expect(Mp4.chunkOffsets(f)[0], mdatPayloadOffset(f));
    expect(Mp4.chunkOffsets(f)[0], isNot(beforeOffset));
  });

  test('moov 在尾：偏移不应变化', () {
    Uint8List f = synth(false);
    final int before = Mp4.chunkOffsets(f)[0];
    f = Mp4.write(f, <String, String>{'album': '叶惠美'});
    expect(Mp4.read(f).get('album'), '叶惠美');
    expect(Mp4.chunkOffsets(f)[0], before);
    expect(Mp4.chunkOffsets(f)[0], mdatPayloadOffset(f));
  });

  test('meta 不是 full atom（子原子从 +8 开始）也能读到标签', () {
    final Uint8List ftyp = atom('ftyp',
        concat(<Uint8List>[ascii('M4A '), be32(0x200), ascii('M4A mp42')]));
    final Uint8List mdat = atom('mdat', Uint8List(16));
    final Uint8List data = atom('data', concat(<Uint8List>[
      be32(1),
      be32(0),
      Uint8List.fromList(utf8.encode('非标准 meta')),
    ]));
    final Uint8List ilst = atom('ilst', atom('\u00a9nam', data));
    // 故意不写 4 字节 version/flags：QuickTime / 部分老写入器就是这个结构
    final Uint8List meta = atom('meta', ilst);
    final Uint8List moov = atom('moov', atom('udta', meta));
    final Uint8List f = concat(<Uint8List>[ftyp, mdat, moov]);
    expect(Mp4.read(f).get('title'), '非标准 meta');
  });

  test('合并语义', () {
    Uint8List f = synth(true);
    f = Mp4.write(f, <String, String>{
      'title': 'A', 'artist': 'B', 'album': 'C', 'year': '2003', 'genre': 'Pop'
    });
    f = Mp4.write(f, <String, String>{'title': 'A2'});
    final Tags t = Mp4.read(f);
    expect(t.get('title'), 'A2');
    expect(t.get('artist'), 'B');
    expect(t.get('album'), 'C');
    expect(t.get('year'), '2003');
    expect(t.get('genre'), 'Pop');
    expect(Mp4.chunkOffsets(f)[0], mdatPayloadOffset(f));
    f = Mp4.write(f, <String, String>{'genre': ''});
    expect(Mp4.read(f).get('genre'), isEmpty);
    expect(Mp4.read(f).get('title'), 'A2');
  });

  test('封面写入 / 替换 / 删除', () {
    Uint8List f = synth(true);
    final Uint8List jpeg = fakeJpeg(120, 90);
    expect(Mp4.hasCover(f), isFalse);
    f = Mp4.write(f, <String, String>{'title': '有封面'}, cover: jpeg);
    expect(Mp4.hasCover(f), isTrue);
    expect(Mp4.read(f).get('title'), '有封面');
    expect(Mp4.chunkOffsets(f)[0], mdatPayloadOffset(f));
    final int sizeWithCover = f.length;

    final Uint8List png = fakePng(200, 200);
    f = Mp4.write(f, <String, String>{}, cover: png);
    expect(Mp4.hasCover(f), isTrue);
    expect(f.length, isNot(sizeWithCover));
    expect(Mp4.chunkOffsets(f)[0], mdatPayloadOffset(f));

    f = Mp4.write(f, <String, String>{}, cover: Uint8List(0));
    expect(Mp4.hasCover(f), isFalse);
    expect(Mp4.read(f).get('title'), '有封面');
    expect(Mp4.chunkOffsets(f)[0], mdatPayloadOffset(f));
  });

  test('中文 / 音轨号 / 类型', () {
    Uint8List f = synth(true);
    f = Mp4.write(f, <String, String>{
      'title': '打上花火', 'artist': 'DAOKO × 米津玄師', 'track': '3/12'
    });
    final Tags t = Mp4.read(f);
    expect(t.get('title'), '打上花火');
    expect(t.get('artist'), 'DAOKO × 米津玄師');
    expect(t.get('track'), '3');
    f = Mp4.write(f, <String, String>{'lyrics': '[00:01.00]第一句\n[00:02.00]第二句'});
    expect(Mp4.read(f).get('lyrics').contains('第二句'), isTrue);
  });
}
