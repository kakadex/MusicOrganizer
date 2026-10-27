import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/match/artist_rules.dart';
import 'package:musicorganizer/core/scan/search_query.dart';
import 'package:musicorganizer/core/tag/cover_art.dart';
import 'package:musicorganizer/core/tag/tag_io.dart';

/// 针对全量代码审查报告修复项的最小回归：
/// MP4 头/尾判定、封面类型识别、搜索大写单位、通用目录名。
void main() {
  Uint8List atom(String type, int size, [Uint8List? body]) {
    final int bodyLen = body?.length ?? 0;
    final int total = size > 0 ? size : 8 + bodyLen;
    final Uint8List b = Uint8List(total);
    b[0] = (total >> 24) & 0xff;
    b[1] = (total >> 16) & 0xff;
    b[2] = (total >> 8) & 0xff;
    b[3] = total & 0xff;
    b.setRange(4, 8, type.codeUnits);
    if (body != null && total > 8) b.setRange(8, 8 + bodyLen, body);
    return b;
  }

  test('MP4 moov 在头部时 needsMore=false', () {
    final Uint8List moov = atom('moov', 16, atom('udta', 8));
    final Uint8List buf = atom('ftyp', 8, Uint8List(0));
    final Uint8List full = Uint8List(buf.length + moov.length)
      ..setRange(0, buf.length, buf)
      ..setRange(buf.length, buf.length + moov.length, moov);
    expect(TagIO.needsMore(full, '.m4a'), isFalse);
  });

  test('MP4 moov 在尾部时能从 tail 切出 moov', () {
    final Uint8List moov = atom('moov', 16, atom('udta', 8));
    // 模拟 mdat 占大头、moov 在最后 2MB 里
    final Uint8List tail = Uint8List(24)
      ..setRange(8, 24, moov);
    final Uint8List? slice = TagIO.mp4MoovFromTail(tail);
    expect(slice, isNotNull);
    expect(slice!.length, 16);
    expect(String.fromCharCodes(slice, 4, 8), 'moov');
  });

  test('封面类型识别覆盖 GIF/BMP/WebP', () {
    expect(CoverArt.isGif(Uint8List.fromList('GIF89a'.codeUnits)), isTrue);
    expect(CoverArt.isBmp(Uint8List.fromList('BM'.codeUnits)), isTrue);
    final Uint8List webp = Uint8List(12)
      ..setRange(0, 4, 'RIFF'.codeUnits)
      ..setRange(8, 12, 'WEBP'.codeUnits);
    expect(CoverArt.isWebp(webp), isTrue);
    expect(CoverArt.isImage(webp), isTrue);
  });

  test('搜索大小单位支持大写', () {
    expect(SearchQuery.parseBytes('10M'), SearchQuery.parseBytes('10m'));
    expect(SearchQuery.parseBytes('1K'), 1024);
    expect(SearchQuery.parseBytes('1G'), 1024 * 1024 * 1024);
  });

  test('通用目录名不算歌手目录', () {
    for (final String n in <String>['Music', 'Download', '歌曲', '我的音乐', '新建文件夹']) {
      expect(ArtistRules.isGenericFolder(n), isTrue, reason: n);
    }
    expect(ArtistRules.isGenericFolder('周杰伦'), isFalse);
  });
}
