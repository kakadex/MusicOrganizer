import 'package:flutter_test/flutter_test.dart' hide Tags;
import 'package:musicorganizer/core/model/tags.dart';
import 'package:musicorganizer/core/organize/folder_template.dart';

Tags tags({String artist = '', String album = '', String year = ''}) {
  final Tags t = Tags();
  if (artist.isNotEmpty) t.put('artist', artist);
  if (album.isNotEmpty) t.put('album', album);
  if (year.isNotEmpty) t.put('year', year);
  return t;
}

void main() {
  test('默认模板 = 歌手', () {
    expect(FolderTemplate.builtin.first.pattern, '{artist}');
    expect(
      FolderTemplate.builtin.first.apply(tags(artist: '周杰伦', album: '叶惠美')),
      '周杰伦',
    );
    // 只保留两套：歌手 / 歌手+专辑；「年代/歌手」「专辑/歌手」已下线
    expect(
      FolderTemplate.builtin.map((FolderTemplate t) => t.pattern).toList(),
      <String>['{artist}', '{artist}/{album}'],
    );
  });

  test('空值所在层整层丢掉，不产生空目录', () {
    const FolderTemplate t = FolderTemplate(name: 'x', pattern: '{artist}/{album}');
    // 没有专辑：只用歌手这一层
    expect(t.apply(tags(artist: '周杰伦')), '周杰伦');
    // 没有歌手：专辑层顶上（不产生前导斜杠）
    expect(t.apply(tags(album: '叶惠美')), '叶惠美');
    // 都没有：归不了类
    expect(t.apply(tags()), '');
  });

  test('年代 / 歌手', () {
    const FolderTemplate t = FolderTemplate(name: '年代 / 歌手', pattern: '{year}/{artist}');
    expect(t.apply(tags(artist: '张宇', year: '2003')), '2003/张宇');
    // 年份空 → 只剩歌手
    expect(t.apply(tags(artist: '张宇')), '张宇');
  });

  test('非法字符换成空格并折叠，超长截断', () {
    const FolderTemplate t = FolderTemplate(name: 'x', pattern: '{artist}');
    expect(t.apply(tags(artist: 'AC/DC')), 'AC DC');
    final String long = 'A' * 120;
    expect(t.apply(tags(artist: long)).length, FolderTemplate.maxSegment);
    // 全是非法字符 → 该层丢弃
    expect(t.apply(tags(artist: '///')), '');
  });

  test('validate：认占位符、认层数、认括号', () {
    expect(FolderTemplate.validate('{artist}/{album}'), isNull);
    expect(FolderTemplate.validate('{year}/{artist}'), isNull);
    expect(FolderTemplate.validate(''), isNotNull);
    expect(FolderTemplate.validate('歌手/专辑'), isNotNull);
    expect(FolderTemplate.validate('{nope}'), isNotNull);
    expect(FolderTemplate.validate('{artist'), isNotNull);
    expect(FolderTemplate.validate('{a}/{b}/{c}/{d}'), isNotNull);
  });

  test('of()：内置按 pattern 命中，自定义原样封装', () {
    expect(FolderTemplate.of('{artist}').name, '歌手');
    expect(FolderTemplate.of('{genre}/{artist}').pattern, '{genre}/{artist}');
  });
}
