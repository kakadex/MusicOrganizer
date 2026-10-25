import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart' hide Tags;
import 'package:musicorganizer/core/model/tags.dart';
import 'package:musicorganizer/core/tag/tag_io.dart';
import 'package:musicorganizer/core/tag/wma.dart';

import '../support/gen.dart';

Uint8List _word(int v) => le16(v);
Uint8List _dword(int v) => le32(v);
Uint8List _qword(int v) => le64(v);

Uint8List _object(Uint8List guid, Uint8List body) =>
    concat(<Uint8List>[guid, _qword(24 + body.length), body]);

Uint8List _writeExtString(String name, String value) {
  final Uint8List n = Wma.utf16Bytes(name);
  final Uint8List v = Wma.utf16Bytes(value);
  return concat(<Uint8List>[_word(n.length), n, _word(0), _word(v.length), v]);
}

Uint8List _writeExtDword(String name, int value) {
  final Uint8List n = Wma.utf16Bytes(name);
  return concat(<Uint8List>[_word(n.length), n, _word(3), _word(4), _dword(value)]);
}

Uint8List _writeWma() {
  final Uint8List guidHeader = Uint8List.fromList(<int>[
    0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11,
    0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C,
  ]);
  final Uint8List guidContent = Uint8List.fromList(<int>[
    0x33, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11,
    0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C,
  ]);
  final Uint8List guidExt = Uint8List.fromList(<int>[
    0x40, 0xA4, 0xD0, 0xD2, 0x07, 0xE3, 0xD2, 0x11,
    0x97, 0xF0, 0x00, 0xA0, 0xC9, 0x5E, 0xA8, 0x50,
  ]);

  final List<String> cd = <String>['晴天', '周杰伦', '', '选自专辑', ''];
  final Uint8List title = Wma.utf16Bytes(cd[0]);
  final Uint8List author = Wma.utf16Bytes(cd[1]);
  final Uint8List copyright = Wma.utf16Bytes(cd[2]);
  final Uint8List desc = Wma.utf16Bytes(cd[3]);
  final Uint8List rating = Wma.utf16Bytes(cd[4]);
  final Uint8List cbody = concat(<Uint8List>[
    _word(title.length), _word(author.length), _word(copyright.length),
    _word(desc.length), _word(rating.length),
    title, author, copyright, desc, rating,
  ]);

  final Uint8List ext = concat(<Uint8List>[
    _word(4),
    _writeExtString('WM/AlbumTitle', '叶惠美'),
    _writeExtString('WM/Genre', 'Pop'),
    _writeExtString('WM/Year', '2003'),
    _writeExtDword('WM/TrackNumber', 3),
  ]);

  final Uint8List contentObj = _object(guidContent, cbody);
  final Uint8List extObj = _object(guidExt, ext);
  final int headerSize = 30 + contentObj.length + extObj.length;
  return concat(<Uint8List>[
    guidHeader,
    _qword(headerSize),
    _dword(2),
    Uint8List.fromList(<int>[1, 2]),
    contentObj,
    extObj,
    Uint8List(64),
  ]);
}

void main() {
  test('WMA 只读标签', () {
    final Uint8List wma = _writeWma();
    expect(Wma.isWma(wma), isTrue);
    final Tags t = Wma.read(wma);
    expect(t.get('title'), '晴天');
    expect(t.get('artist'), '周杰伦');
    expect(t.get('album'), '叶惠美');
    expect(t.get('genre'), 'Pop');
    expect(t.get('year'), '2003');
    expect(t.get('track'), '3');

    expect(TagIO.canWrite('.wma'), isFalse);
    final (String err, _) = TagIO.writeLocal(wma, '.wma', <String, String>{});
    expect(err, isNotEmpty);
    expect(TagIO.readLocal(wma, '.wma').get('title'), '晴天');
  });

  test('非 WMA 不误判', () {
    final Uint8List fake = ascii('not asf');
    expect(Wma.isWma(fake), isFalse);
    expect(Wma.read(fake).anyValue(), isFalse);
  });
}
