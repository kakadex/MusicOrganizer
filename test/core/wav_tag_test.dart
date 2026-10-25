import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart' hide Tags;
import 'package:musicorganizer/core/model/tags.dart';
import 'package:musicorganizer/core/tag/tag_io.dart';
import 'package:musicorganizer/core/tag/wav.dart';

import '../support/gen.dart';

Uint8List writeWav(Uint8List pcm, Map<String, String>? info) {
  final BytesBuilder body = BytesBuilder();
  body.add(ascii('fmt '));
  body.add(le32(16));
  body.add(le16(1));
  body.add(le16(1));
  body.add(le32(8000));
  body.add(le32(16000));
  body.add(le16(2));
  body.add(le16(16));
  if (info != null && info.isNotEmpty) {
    final BytesBuilder sub = BytesBuilder();
    for (final MapEntry<String, String> e in info.entries) {
      final Uint8List v = Uint8List.fromList(utf8.encode('${e.value}\u0000'));
      sub.add(ascii(e.key));
      sub.add(le32(v.length));
      sub.add(v);
      if ((v.length & 1) == 1) sub.addByte(0);
    }
    body.add(ascii('LIST'));
    body.add(le32(4 + sub.length));
    body.add(ascii('INFO'));
    body.add(sub.toBytes());
  }
  body.add(ascii('data'));
  body.add(le32(pcm.length));
  body.add(pcm);
  if ((pcm.length & 1) == 1) body.addByte(0);
  final Uint8List payload = body.toBytes();
  final BytesBuilder out = BytesBuilder();
  out.add(ascii('RIFF'));
  out.add(le32(4 + payload.length));
  out.add(ascii('WAVE'));
  out.add(payload);
  return out.toBytes();
}

Uint8List readData(Uint8List data) {
  int pos = 12;
  while (pos + 8 <= data.length) {
    final String id = String.fromCharCodes(data.sublist(pos, pos + 4));
    final int size =
        data[pos + 4] | (data[pos + 5] << 8) | (data[pos + 6] << 16) | (data[pos + 7] << 24);
    if (id == 'data') return Uint8List.fromList(data.sublist(pos + 8, pos + 8 + size));
    pos = pos + 8 + size + (size & 1);
  }
  return Uint8List(0);
}

int countChunk(Uint8List data, String id) {
  int n = 0;
  int pos = 12;
  while (pos + 8 <= data.length) {
    final String got = String.fromCharCodes(data.sublist(pos, pos + 4));
    final int size =
        data[pos + 4] | (data[pos + 5] << 8) | (data[pos + 6] << 16) | (data[pos + 7] << 24);
    if (id == got) n++;
    pos = pos + 8 + size + (size & 1);
  }
  return n;
}

bool riffSizeOk(Uint8List data) {
  final int size =
      data[4] | (data[5] << 8) | (data[6] << 16) | (data[7] << 24);
  return size == data.length - 8;
}

void main() {
  final Uint8List pcm = Uint8List.fromList(List<int>.generate(1024, (int i) => i));

  test('WAV 识别与空读', () {
    final Uint8List wav = writeWav(pcm, null);
    expect(Wav.isWav(wav), isTrue);
    expect(TagIO.canWrite('.wav'), isTrue);
    expect(Wav.read(wav).anyValue(), isFalse);
  });

  test('写全字段并回读 + PCM 未被破坏 + RIFF 长度回填', () {
    Uint8List wav = writeWav(pcm, null);
    final Map<String, String> values = <String, String>{
      'title': '测试标题', 'artist': '张三', 'album': '专辑名',
      'year': '2024', 'track': '3', 'genre': 'Pop', 'comment': '备注',
    };
    wav = Wav.rewrite(wav, values);
    final Tags t = Wav.read(wav);
    expect(t.get('title'), '测试标题');
    expect(t.get('artist'), '张三');
    expect(t.get('album'), '专辑名');
    expect(t.get('year'), '2024');
    expect(t.get('track'), '3');
    expect(t.get('genre'), 'Pop');
    expect(sameBytes(readData(wav), pcm), isTrue);
    expect(riffSizeOk(wav), isTrue);
  });

  test('二次写入：不重复 id3、旧值被替换、PCM 完好', () {
    Uint8List wav = writeWav(pcm, null);
    final Map<String, String> values = <String, String>{
      'title': '测试标题', 'artist': '张三', 'album': '专辑名',
      'year': '2024', 'track': '3', 'genre': 'Pop', 'comment': '备注',
    };
    wav = Wav.rewrite(wav, values);
    values['title'] = '新标题';
    wav = Wav.rewrite(wav, values);
    expect(countChunk(wav, 'id3 ') + countChunk(wav, 'ID3 '), 1);
    expect(Wav.read(wav).get('title'), '新标题');
    expect(Wav.read(wav).get('artist'), '张三');
    expect(sameBytes(readData(wav), pcm), isTrue);
  });

  test('读 RIFF LIST/INFO 标签 + 覆盖后清理 INFO', () {
    final Uint8List infoWav =
        writeWav(pcm, <String, String>{'INAM': 'INFO 标题', 'IART': 'INFO 歌手'});
    expect(Wav.read(infoWav).get('title'), 'INFO 标题');
    expect(Wav.read(infoWav).get('artist'), 'INFO 歌手');
    final Uint8List rewritten = Wav.rewrite(infoWav, <String, String>{'title': '新标题'});
    expect(countChunk(rewritten, 'LIST'), 0);
    expect(countChunk(rewritten, 'id3 '), 1);
    expect(Wav.read(rewritten).get('title'), '新标题');
    expect(sameBytes(readData(rewritten), pcm), isTrue);
  });

  test('走 TagIO 分发', () {
    final Uint8List viaIo = writeWav(pcm, null);
    final (String err, Uint8List? out) =
        TagIO.writeLocal(viaIo, '.wav', <String, String>{'title': '新标题'});
    expect(err, isEmpty);
    expect(TagIO.readLocal(out!, '.wav').get('title'), '新标题');
  });

  test('非 WAV 拒绝', () {
    final Uint8List notWav = ascii('not a wav file at all');
    expect(Wav.isWav(notWav), isFalse);
    final (String err, _) =
        TagIO.writeLocal(notWav, '.wav', <String, String>{'title': 'x'});
    expect(err, isNotEmpty);
  });
}
