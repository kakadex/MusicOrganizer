import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart' hide Tags;
import 'package:musicorganizer/core/model/tags.dart';
import 'package:musicorganizer/core/tag/ogg.dart';
import 'package:musicorganizer/core/tag/tag_io.dart';

import '../support/gen.dart';

Uint8List assemble(int headerType, int granule, int serial, int seq,
    List<int> segs, Uint8List payload) {
  final BytesBuilder b = BytesBuilder();
  b.add(ascii('OggS'));
  b.addByte(0);
  b.addByte(headerType);
  b.add(le64(granule));
  b.add(le32(serial));
  b.add(le32(seq));
  b.add(Uint8List(4));
  b.addByte(segs.length);
  for (final int s in segs) {
    b.addByte(s & 0xFF);
  }
  b.add(payload);
  final Uint8List page = b.toBytes();
  final int crc = Ogg.crc(page, 0, page.length);
  page[22] = crc & 0xFF;
  page[23] = (crc >> 8) & 0xFF;
  page[24] = (crc >> 16) & 0xFF;
  page[25] = (crc >> 24) & 0xFF;
  return page;
}

Uint8List page(int headerType, int granule, int serial, int seq,
    List<Uint8List> packets) {
  final List<int> segs = <int>[];
  final BytesBuilder payload = BytesBuilder();
  for (final Uint8List p in packets) {
    int left = p.length;
    while (left >= 255) {
      segs.add(255);
      left -= 255;
    }
    segs.add(left);
    payload.add(p);
  }
  return assemble(headerType, granule, serial, seq, segs, payload.toBytes());
}

Uint8List commentPacket(bool opus, String vendor) {
  final BytesBuilder b = BytesBuilder();
  if (opus) {
    b.add(ascii('OpusTags'));
  } else {
    b.add(<int>[0x03, 0x76, 0x6F, 0x72, 0x62, 0x69, 0x73]);
  }
  final Uint8List v = Uint8List.fromList(vendor.codeUnits);
  b.add(le32(v.length));
  b.add(v);
  b.add(le32(0));
  if (!opus) b.addByte(0x01);
  return b.toBytes();
}

Uint8List writeVorbis(List<Uint8List> audio) {
  final Uint8List ident = Uint8List.fromList(<int>[0x01, 0x76, 0x6F, 0x72, 0x62, 0x69, 0x73]);
  final Uint8List setup = Uint8List.fromList(<int>[0x05, 0x76, 0x6F, 0x72, 0x62, 0x69, 0x73]);
  final BytesBuilder out = BytesBuilder();
  out.add(page(0x02, 0, 0, 0, <Uint8List>[ident]));
  out.add(page(0, 0, 0, 1, <Uint8List>[
    commentPacket(false, 'test-vendor'),
    concat(<Uint8List>[setup, Uint8List(900)]),
  ]));
  int granule = 0;
  for (int i = 0; i < audio.length; i++) {
    granule += 44100;
    out.add(page(i == audio.length - 1 ? 0x04 : 0, granule, 0, 2 + i, <Uint8List>[audio[i]]));
  }
  return out.toBytes();
}

Uint8List writeOpus(List<Uint8List> audio) {
  final BytesBuilder out = BytesBuilder();
  out.add(page(0x02, 0, 0, 0, <Uint8List>[ascii('OpusHead')]));
  out.add(page(0, 0, 0, 1, <Uint8List>[commentPacket(true, 'test-vendor')]));
  int granule = 0;
  for (int i = 0; i < audio.length; i++) {
    granule += 960;
    out.add(page(i == audio.length - 1 ? 0x04 : 0, granule, 0, 2 + i, <Uint8List>[audio[i]]));
  }
  return out.toBytes();
}

List<Uint8List> rawPackets(Uint8List data) {
  final List<Uint8List> out = <Uint8List>[];
  BytesBuilder cur = BytesBuilder();
  int pos = 0;
  while (pos + 27 <= data.length) {
    final int nsegs = data[pos + 26];
    int payloadPos = pos + 27 + nsegs;
    for (int i = 0; i < nsegs; i++) {
      final int seg = data[pos + 27 + i];
      cur.add(Uint8List.sublistView(data, payloadPos, payloadPos + seg));
      payloadPos += seg;
      if (seg < 255) {
        out.add(cur.toBytes());
        cur = BytesBuilder();
      }
    }
    int payload = 0;
    for (int i = 0; i < nsegs; i++) {
      payload += data[pos + 27 + i];
    }
    pos += 27 + nsegs + payload;
  }
  return out;
}

bool audioIntact(Uint8List data, List<Uint8List> audio) {
  final List<Uint8List> packets = rawPackets(data);
  if (packets.length < audio.length) return false;
  final int base = packets.length - audio.length;
  for (int i = 0; i < audio.length; i++) {
    if (!sameBytes(packets[base + i], audio[i])) return false;
  }
  return packets[1][0] == 0x03 || packets[1][0] == 0x4F;
}

bool allCrcValid(Uint8List data) {
  int pos = 0;
  while (pos + 27 <= data.length) {
    final int nsegs = data[pos + 26];
    int payload = 0;
    for (int i = 0; i < nsegs; i++) {
      payload += data[pos + 27 + i];
    }
    final int total = 27 + nsegs + payload;
    final int stored = data[pos + 22] | (data[pos + 23] << 8) | (data[pos + 24] << 16) | (data[pos + 25] << 24);
    final Uint8List copy = Uint8List.fromList(data.sublist(pos, pos + total));
    copy[22] = 0;
    copy[23] = 0;
    copy[24] = 0;
    copy[25] = 0;
    if (Ogg.crc(copy, 0, total) != stored) return false;
    pos += total;
  }
  return true;
}

int pageCount(Uint8List data) {
  int n = 0;
  int pos = 0;
  while (pos + 27 <= data.length) {
    final int nsegs = data[pos + 26];
    int payload = 0;
    for (int i = 0; i < nsegs; i++) {
      payload += data[pos + 27 + i];
    }
    pos += 27 + nsegs + payload;
    n++;
  }
  return n;
}

void main() {
  final List<Uint8List> audioPackets = <Uint8List>[
    packet(0x11, 600),
    packet(0x22, 1500),
  ];
  final Map<String, String> values = <String, String>{
    'title': '夜曲', 'artist': '周杰伦', 'album': '十一月的萧邦',
    'year': '2005', 'track': '1', 'genre': 'Pop', 'comment': '测试',
  };

  test('Vorbis 读写与音频包完整', () {
    final Uint8List vorbis = writeVorbis(audioPackets);
    expect(Ogg.isOgg(vorbis), isTrue);
    expect(TagIO.canWrite('.ogg'), isTrue);
    expect(Ogg.read(vorbis).anyValue(), isFalse);

    Uint8List w = Ogg.rewrite(vorbis, values);
    final Tags t = Ogg.read(w);
    expect(t.get('title'), '夜曲');
    expect(t.get('artist'), '周杰伦');
    expect(t.get('album'), '十一月的萧邦');
    expect(t.get('year'), '2005');
    expect(t.get('track'), '1');
    expect(t.get('genre'), 'Pop');
    expect(audioIntact(w, audioPackets), isTrue);
    expect(allCrcValid(w), isTrue);

    values['title'] = '夜曲（重制）';
    w = Ogg.rewrite(w, values);
    expect(Ogg.read(w).get('title'), '夜曲（重制）');
    expect(Ogg.read(w).get('artist'), '周杰伦');
    expect(audioIntact(w, audioPackets), isTrue);
  });

  test('大歌词触发拆页', () {
    final Uint8List big = writeVorbis(audioPackets);
    final int pagesBefore = pageCount(big);
    final StringBuffer lyr = StringBuffer();
    for (int i = 0; i < 4000; i++) {
      lyr.write('[00:${(i % 60).toString().padLeft(2, '0')}.00]第 $i 行歌词\n');
    }
    final Uint8List w = Ogg.rewrite(big, <String, String>{'lyrics': lyr.toString()});
    expect(pageCount(w), greaterThan(pagesBefore));
    expect(audioIntact(w, audioPackets), isTrue);
    expect(allCrcValid(w), isTrue);
    expect(Ogg.read(w).get('lyrics').length, lyr.toString().trim().length);
  });

  test('Opus 读写', () {
    final Uint8List opus = writeOpus(audioPackets);
    expect(Ogg.isOgg(opus), isTrue);
    final Uint8List w = Ogg.rewrite(opus, values);
    expect(Ogg.read(w).get('title'), '夜曲（重制）');
    expect(audioIntact(w, audioPackets), isTrue);
    expect(allCrcValid(w), isTrue);
  });

  test('TagIO 分发 + 非 OGG 拒绝', () {
    final Uint8List viaIo = writeVorbis(audioPackets);
    final (String err, Uint8List? out) = TagIO.writeLocal(viaIo, '.ogg', values);
    expect(err, isEmpty);
    expect(TagIO.readLocal(out!, '.ogg').get('title'), '夜曲（重制）');

    final Uint8List fake = ascii('ID3 not ogg');
    expect(Ogg.isOgg(fake), isFalse);
    final (String err2, _) = TagIO.writeLocal(fake, '.ogg', values);
    expect(err2, isNotEmpty);
  });
}
