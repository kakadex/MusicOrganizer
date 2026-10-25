import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/match/artist_rules.dart';

void main() {
  test('占位歌手标签必须被识别出来', () {
    expect(ArtistRules.isGenericArtist('华语群星'), isTrue);
    expect(ArtistRules.isGenericArtist('群星'), isTrue);
    expect(ArtistRules.isGenericArtist('Various Artists'), isTrue);
    expect(ArtistRules.isGenericArtist('未知歌手'), isTrue);
    expect(ArtistRules.isGenericArtist(''), isTrue);
    expect(ArtistRules.isGenericArtist('周杰伦'), isFalse);
    expect(ArtistRules.isGenericArtist('张学友'), isFalse);
  });

  test('同义写法归一到同一个目录', () {
    expect(ArtistRules.folderKey('示例乐队 & China Blue'),
        ArtistRules.folderKey('示例乐队 And China Blue'));
    expect(ArtistRules.folderKey('示例乐队＆China Blue'),
        ArtistRules.folderKey('示例乐队 & China Blue'));
    expect(ArtistRules.folderKey('周杰伦、方文山'),
        ArtistRules.folderKey('周杰伦&方文山'));
    expect(ArtistRules.folderKey('BEYOND'), ArtistRules.folderKey('beyond'));
    expect(ArtistRules.folderKey(''), isEmpty);
  });

  test('不能过度合并：Simon & Garfunkel 与 Simon 是两个键', () {
    expect(ArtistRules.folderKey('Simon & Garfunkel'),
        isNot(ArtistRules.folderKey('Simon')));
  });

  test('normalizeCandidate / artistsCompatible（补充）', () {
    expect(ArtistRules.normalizeCandidate('周杰倫 _1'), '周杰伦');
    expect(ArtistRules.artistsCompatible('周杰伦', '周杰伦'), isTrue);
    expect(ArtistRules.artistsCompatible('周杰伦', '林俊杰'), isFalse);
    expect(ArtistRules.isReasonableArtistReturn('周杰伦', '晴天', '周杰伦 - 晴天', null),
        isTrue);
  });
}
