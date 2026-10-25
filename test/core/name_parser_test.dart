import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/match/name_parser.dart';

void main() {
  test('stripNameNoise 去轨道前缀与书名号', () {
    expect(NameParser.stripNameNoise('01.晴天'), '晴天');
    expect(NameParser.stripNameNoise('《晴天》'), '晴天');
    expect(NameParser.stripNameNoise('  '), '');
  });

  test('splitArtistTitle 居中分隔符', () {
    final NameSplit? s = NameParser.splitArtistTitle('周杰伦 - 晴天');
    expect(s, isNotNull);
    expect(s!.left, '周杰伦');
    expect(s.right, '晴天');
    expect(s.style, 'F1');
  });

  test('nameCandidates 双向', () {
    final List<NameCandidate> c = NameParser.nameCandidates('周杰伦 - 晴天');
    expect(c.length, 2);
    expect(c[0].artist, '周杰伦');
    expect(c[0].title, '晴天');
    expect(c[1].artist, '晴天');
    expect(c[1].title, '周杰伦');
  });

  test('无分隔符 → 单段歌名候选', () {
    final List<NameCandidate> c = NameParser.nameCandidates('晴天');
    expect(c.length, 1);
    expect(c[0].artist, isNull);
    expect(c[0].title, '晴天');
    expect(c[0].style, 'F5/F6');
  });

  test('candidatePairs 双向去重', () {
    expect(NameParser.candidatePairs('周杰伦 - 晴天'), <List<String>>[
      ['周杰伦', '晴天'],
      ['晴天', '周杰伦'],
    ]);
  });
}
