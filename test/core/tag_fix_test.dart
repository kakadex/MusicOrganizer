import 'package:flutter_test/flutter_test.dart' hide Tags;
import 'package:musicorganizer/core/match/tag_fix.dart';
import 'package:musicorganizer/core/model/tags.dart';

Tags tagsOf(Map<String, String> values) {
  final Tags t = Tags();
  values.forEach(t.put);
  return t;
}

void main() {
  test('clean：全角转半角 + 折叠空格 + 去首尾空白', () {
    expect(TagFix.clean(' 示例　歌名 ', TagFix.trim | TagFix.spaces | TagFix.width),
        '示例 歌名');
    expect(TagFix.clean('示例  歌名', TagFix.spaces), '示例 歌名');
    expect(TagFix.clean('  示例歌名  ', TagFix.trim), '示例歌名');
    // 未勾选的动作位不动
    expect(TagFix.clean(' 示例歌名 ', TagFix.width), ' 示例歌名 ');
    expect(TagFix.clean(' 示例歌名 ', 0), ' 示例歌名 ');
  });

  test('fullToHalf 只换全角字母数字标点，汉字不动', () {
    expect(TagFix.fullToHalf('ＡＢＣ１２３！'), 'ABC123!');
    expect(TagFix.fullToHalf('示例　歌名'), '示例 歌名');
    expect(TagFix.fullToHalf('示例歌名'), '示例歌名');
  });

  test('track：单位数补零，非纯数字不动', () {
    expect(TagFix.track('1'), '01');
    expect(TagFix.track('1/12'), '01/12');
    expect(TagFix.track('10'), '10');
    expect(TagFix.track('A1'), 'A1');
    expect(TagFix.track(' 3 '), '03');
    expect(TagFix.track(''), '');
  });

  test('plan：只返回真正需要改的字段', () {
    final Tags tags = tagsOf(<String, String>{
      'title': '示例  歌名',
      'artist': '示例歌手',
      'year': '２０２０',
      'track': '3',
    });
    final Map<String, String> plan = TagFix.plan(
        tags, TagFix.trim | TagFix.spaces | TagFix.width | TagFix.padTrack);
    expect(plan, <String, String>{
      'title': '示例 歌名',
      'year': '2020',
      'track': '03',
    });
    expect(plan.containsKey('artist'), isFalse);
  });

  test('plan：只勾空格时不动音轨与年份', () {
    final Tags tags = tagsOf(<String, String>{
      'genre': '示例  流派',
      'track': '1',
      'year': '２０２０',
    });
    expect(TagFix.plan(tags, TagFix.spaces), <String, String>{
      'genre': '示例 流派',
    });
  });

  test('plan：干净的标签返回空计划', () {
    final Tags tags = tagsOf(<String, String>{
      'title': '示例歌名',
      'artist': '示例歌手',
      'track': '01',
    });
    expect(TagFix.plan(tags, TagFix.trim | TagFix.spaces | TagFix.width | TagFix.padTrack),
        isEmpty);
    expect(TagFix.plan(Tags(), TagFix.trim), isEmpty);
  });
}
