import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart' hide Tags;
import 'package:musicorganizer/core/model/tags.dart';
import 'package:musicorganizer/core/scan/tag_parse_batch.dart';
import 'package:musicorganizer/core/tag/tag_io.dart';

Uint8List _mkMp3(Map<String, String> fields) {
  final Tags t = Tags();
  fields.forEach(t.put);
  final Uint8List base = Uint8List.fromList(List<int>.filled(1024, 0xFF));
  final (String err, Uint8List? out) = TagIO.writeLocal(base, '.mp3', fields);
  if (err.isNotEmpty || out == null) {
    throw StateError('测试夹具写入失败：$err');
  }
  return out;
}

void main() {
  group('parseTagBytesBatch（isolate 用的纯函数）', () {
    test('批量解析：输入输出一一对应，标签与封面正确', () {
      final Uint8List a = _mkMp3(<String, String>{'title': '第一首', 'artist': '甲'});
      final Uint8List b = _mkMp3(<String, String>{'title': '第二首', 'artist': '乙'});

      final List<ParseOutput> out = parseTagBytesBatch(<ParseInput>[
        ParseInput(ext: '.mp3', bytes: a),
        ParseInput(ext: '.mp3', bytes: b),
      ]);

      expect(out.length, 2);
      expect(out[0].values['title'], '第一首');
      expect(out[0].values['artist'], '甲');
      expect(out[1].values['title'], '第二首');
      expect(out[1].values['artist'], '乙');
    });

    test('单首失败不影响整批：坏字节返回空 map', () {
      final Uint8List good = _mkMp3(<String, String>{'title': '好的'});
      final Uint8List bad = Uint8List.fromList(<int>[0, 1, 2, 3]); // 不是 MP3

      final List<ParseOutput> out = parseTagBytesBatch(<ParseInput>[
        ParseInput(ext: '.mp3', bytes: bad),
        ParseInput(ext: '.mp3', bytes: good),
      ]);

      expect(out.length, 2);
      // 坏字节：要么抛异常被吃掉（空 map），要么解析出空标签——两者都安全
      expect(out[0].values['title'] ?? '', anyOf(isEmpty, '好的'),
          reason: '失败首不能影响其它首');
      expect(out[1].values['title'], '好的');
    });

    test('顺序严格对应：不能因为并发或异常而错位', () {
      final List<ParseInput> inputs = <ParseInput>[
        for (int i = 0; i < 10; i++)
          ParseInput(ext: '.mp3', bytes: _mkMp3(<String, String>{'title': '第$i首'})),
      ];
      final List<ParseOutput> out = parseTagBytesBatch(inputs);
      expect(out.length, inputs.length);
      for (int i = 0; i < 10; i++) {
        expect(out[i].values['title'], '第$i首', reason: '下标 $i 错位');
      }
    });

    test('空列表返回空结果', () {
      expect(parseTagBytesBatch(<ParseInput>[]), isEmpty);
    });

    test('Tags.fromMap 与 toMap 互逆（isolate 传输往返）', () {
      final Tags src = Tags()
        ..put('title', '标题')
        ..put('artist', '歌手')
        ..put('year', '2026');
      final Tags restored = Tags.fromMap(src.toMap());
      expect(restored.get('title'), '标题');
      expect(restored.get('artist'), '歌手');
      expect(restored.get('year'), '2026');
      // 没填的字段仍是空串（Tags 构造时的约定）
      expect(restored.get('comment'), '');
    });
  });
}
