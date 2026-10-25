import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart' hide Tags;
import 'package:musicorganizer/core/model/tags.dart';
import 'package:musicorganizer/core/tag/ape.dart';
import 'package:musicorganizer/core/tag/tag_io.dart';

import '../support/gen.dart';

void putLe32(Uint8List b, int off, int v) {
  b[off] = v & 0xFF;
  b[off + 1] = (v >> 8) & 0xFF;
  b[off + 2] = (v >> 16) & 0xFF;
  b[off + 3] = (v >> 24) & 0xFF;
}

Uint8List buildTag(Map<String, String> tag) {
  final BytesBuilder body = BytesBuilder();
  for (final MapEntry<String, String> e in tag.entries) {
    final Uint8List key = ascii(e.key);
    final Uint8List value = Uint8List.fromList(utf8.encode(e.value));
    body.add(le32(value.length));
    body.add(le32(0));
    body.add(key);
    body.addByte(0);
    body.add(value);
  }
  final Uint8List items = body.toBytes();
  final BytesBuilder out = BytesBuilder();
  out.add(items);
  final Uint8List footer = Uint8List(32);
  footer.setRange(0, 8, ascii('APETAGEX'));
  putLe32(footer, 8, 2000);
  putLe32(footer, 12, items.length + 32);
  putLe32(footer, 16, tag.length);
  putLe32(footer, 20, 0);
  out.add(footer);
  return out.toBytes();
}

Uint8List writeApe(Uint8List audio, Map<String, String>? tag, bool withId3v1) {
  final BytesBuilder out = BytesBuilder();
  out.add(ascii('MAC '));
  out.add(audio);
  if (tag != null && tag.isNotEmpty) out.add(buildTag(tag));
  if (withId3v1) {
    final Uint8List v1 = Uint8List(128);
    v1[0] = 0x54;
    v1[1] = 0x41;
    v1[2] = 0x47;
    final Uint8List title = ascii('ID3V1 TITLE');
    v1.setRange(3, 3 + title.length, title);
    out.add(v1);
  }
  return out.toBytes();
}

bool audioSame(Uint8List data, Uint8List audio) {
  if (data.length < 4 + audio.length) return false;
  if (!(data[0] == 0x4D && data[1] == 0x41 && data[2] == 0x43 && data[3] == 0x20)) {
    return false;
  }
  for (int i = 0; i < audio.length; i++) {
    if (data[4 + i] != audio[i]) return false;
  }
  return true;
}

int countMagic(Uint8List data) {
  int n = 0;
  for (int i = 0; i + 8 <= data.length; i++) {
    if (data[i] == 0x41 && data[i + 1] == 0x50 && data[i + 2] == 0x45 &&
        data[i + 3] == 0x54 && data[i + 4] == 0x41 && data[i + 5] == 0x47 &&
        data[i + 6] == 0x45 && data[i + 7] == 0x58) {
      n++;
    }
  }
  return n;
}

bool hasId3v1(Uint8List data) {
  if (data.length < 128) return false;
  return data[data.length - 128] == 0x54 &&
      data[data.length - 127] == 0x41 &&
      data[data.length - 126] == 0x47;
}

void main() {
  final Uint8List audio = Uint8List.fromList(List<int>.generate(1000, (int i) => (i * 7) & 0xFF));
  final Map<String, String> values = <String, String>{
    'title': '加州旅馆', 'artist': 'Eagles', 'album': 'Hotel California',
    'year': '1976', 'track': '1', 'genre': 'Rock',
  };

  test('APE 读写与音频段完整', () {
    final Uint8List ape = writeApe(audio, null, false);
    expect(Ape.isApe(ape), isTrue);
    expect(TagIO.canWrite('.ape'), isTrue);
    expect(Ape.read(ape).anyValue(), isFalse);

    Uint8List w = Ape.rewrite(ape, values);
    final Tags t = Ape.read(w);
    expect(t.get('title'), '加州旅馆');
    expect(t.get('artist'), 'Eagles');
    expect(t.get('album'), 'Hotel California');
    expect(t.get('year'), '1976');
    expect(t.get('track'), '1');
    expect(t.get('genre'), 'Rock');
    expect(audioSame(w, audio), isTrue);

    values['title'] = '加州旅馆（现场）';
    w = Ape.rewrite(w, values);
    expect(Ape.read(w).get('title'), '加州旅馆（现场）');
    expect(countMagic(w), 1);
    expect(audioSame(w, audio), isTrue);
  });

  test('ID3v1 保留', () {
    final Uint8List withV1 = writeApe(audio, null, true);
    expect(Ape.isApe(withV1), isTrue);
    final Uint8List w = Ape.rewrite(withV1, values);
    expect(hasId3v1(w), isTrue);
    expect(audioSame(w, audio), isTrue);
  });

  test('保留自定义键（合并语义）', () {
    final Uint8List custom = writeApe(
        audio, <String, String>{'Album Artist': 'Various', 'Title': '旧标题'}, false);
    expect(Ape.readRaw(custom, 'Album Artist'), 'Various');
    final Uint8List w = Ape.rewrite(custom, <String, String>{'title': '新标题'});
    expect(Ape.readRaw(w, 'Album Artist'), 'Various');
    expect(Ape.read(w).get('title'), '新标题');
  });

  test('封面写入', () {
    final Uint8List cov = writeApe(audio, null, false);
    expect(Ape.hasCover(cov), isFalse);
    final Uint8List img = Uint8List.fromList(List<int>.generate(64, (int i) => 0xFF - i));
    final Uint8List w = Ape.rewrite(cov, values, cover: img);
    expect(Ape.hasCover(w), isTrue);
    expect(Ape.read(w).get('title'), '加州旅馆（现场）');
  });

  test('非 APE 拒绝', () {
    final Uint8List fake = ascii('just some bytes');
    expect(Ape.isApe(fake), isFalse);
    final (String err, _) = TagIO.writeLocal(fake, '.ape', values);
    expect(err, isNotEmpty);
  });
}
