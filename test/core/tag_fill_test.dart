import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/match/tag_fill.dart';

Map<String, String> candidate() => <String, String>{
      'title': '晴天',
      'artist': '周杰伦',
      'album': '叶惠美',
      'year': '2003',
      'track': '',
      'genre': '',
    };

/// 固定顺序输出，便于断言（等价 Java TreeMap.toString()）。
String render(Map<String, String> m) {
  final List<String> keys = m.keys.toList()..sort();
  final StringBuffer sb = StringBuffer('{');
  for (int i = 0; i < keys.length; i++) {
    if (i > 0) sb.write(', ');
    sb.write('${keys[i]}=${m[keys[i]]}');
  }
  sb.write('}');
  return sb.toString();
}

void main() {
  test('只补空缺：已有值一律不动', () {
    final Map<String, String> before = <String, String>{
      'title': '晴天（旧）',
      'artist': '周杰伦',
    };
    final Map<String, String> d1 =
        TagFill.diff(before, candidate(), overwrite: false);
    expect(render(d1), '{album=叶惠美, year=2003}');
  });

  test('覆盖已有：不同才写，相同跳过', () {
    final Map<String, String> before = <String, String>{
      'title': '晴天（旧）',
      'artist': '周杰伦',
    };
    final Map<String, String> d2 =
        TagFill.diff(before, candidate(), overwrite: true);
    expect(render(d2), '{album=叶惠美, title=晴天, year=2003}');
  });

  test('候选里的空值永远不写（不会把已有标签清空）', () {
    final Map<String, String> full = <String, String>{};
    for (final String k in TagFill.candidateFields) {
      full[k] = '原值-$k';
    }
    final Map<String, String> cand = <String, String>{'title': '', 'artist': ''};
    expect(TagFill.diff(full, cand, overwrite: true), isEmpty);
  });

  test('标签已完整：默认视为饱和，跳过联网', () {
    final Map<String, String> full = <String, String>{};
    for (final String k in TagFill.candidateFields) {
      full[k] = '原值-$k';
    }
    expect(TagFill.isSaturated(full, overwrite: false), isTrue);
    expect(TagFill.isSaturated(full, overwrite: true), isFalse);
    expect(TagFill.isSaturated(<String, String>{'title': 'x'}, overwrite: false),
        isFalse);
  });

  test('摘要文案', () {
    final Map<String, String> before = <String, String>{
      'title': '晴天（旧）',
      'artist': '周杰伦',
    };
    final Map<String, String> d1 =
        TagFill.diff(before, candidate(), overwrite: false);
    expect(TagFill.describe(d1), '专辑、年份');
    expect(TagFill.describe(<String, String>{}), '');
  });

  test('字段级三态策略（不写 / 只补空 / 覆盖）', () {
    final Map<String, String> before2 = <String, String>{
      'title': '晴天（旧）',
      'artist': '周杰伦',
    };
    final Map<String, int> modes = <String, int>{
      'title': TagFill.disabled,
      'artist': TagFill.overwrite,
    };
    final Map<String, String> d3 =
        TagFill.diff(before2, candidate(), modes: modes);
    expect(render(d3), '{album=叶惠美, year=2003}');

    final Map<String, String> cand2 = candidate()..['artist'] = '周杰伦(新)';
    final Map<String, String> d4 = TagFill.diff(before2, cand2, modes: modes);
    expect(render(d4), '{album=叶惠美, artist=周杰伦(新), year=2003}');

    final Map<String, String> full2 = <String, String>{};
    for (final String k in TagFill.candidateFields) {
      full2[k] = '原值-$k';
    }
    expect(TagFill.isSaturated(full2, modes: TagFill.defaultModes(false)), isTrue);
    final Map<String, int> hasOverwrite = TagFill.defaultModes(false)
      ..['genre'] = TagFill.overwrite;
    expect(TagFill.isSaturated(full2, modes: hasOverwrite), isFalse);
    final Map<String, int> disableAndSupp = TagFill.defaultModes(false)
      ..['genre'] = TagFill.disabled;
    expect(TagFill.isSaturated(full2, modes: disableAndSupp), isTrue);
  });
}
