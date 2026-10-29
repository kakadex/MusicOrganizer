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

/// 全字段统一策略：这几条用例测的是 diff / describe 本身，
/// 与「默认只补标题与艺术家」无关，显式传全字段避免被默认值变化牵连。
Map<String, int> allModes(int mode) => <String, int>{
      for (final String f in TagFill.candidateFields) f: mode,
    };

void main() {
  test('只补空缺：已有值一律不动', () {
    final Map<String, String> before = <String, String>{
      'title': '晴天（旧）',
      'artist': '周杰伦',
    };
    final Map<String, String> d1 =
        TagFill.diff(before, candidate(), modes: allModes(TagFill.supplement));
    expect(render(d1), '{album=叶惠美, year=2003}');
  });

  test('覆盖已有：不同才写，相同跳过', () {
    final Map<String, String> before = <String, String>{
      'title': '晴天（旧）',
      'artist': '周杰伦',
    };
    final Map<String, String> d2 =
        TagFill.diff(before, candidate(), modes: allModes(TagFill.overwrite));
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

  test('默认策略：只补标题与艺术家，其余不写', () {
    final Map<String, int> m = TagFill.defaultModes(false);
    expect(m['title'], TagFill.supplement);
    expect(m['artist'], TagFill.supplement);
    for (final String f in <String>[
      'albumArtist', 'album', 'year', 'track', 'genre',
    ]) {
      expect(m[f], TagFill.disabled, reason: '$f 默认不该写');
    }
    // 老的「整体覆盖」开关只影响这两个默认字段，别的一律不写
    expect(TagFill.defaultModes(true)['title'], TagFill.overwrite);
    expect(TagFill.defaultModes(true)['album'], TagFill.disabled);
    // 取不到时也按同一默认
    expect(TagFill.modeOf(null, 'title'), TagFill.supplement);
    expect(TagFill.modeOf(null, 'album'), TagFill.disabled);
  });

  test('摘要文案', () {
    final Map<String, String> before = <String, String>{
      'title': '晴天（旧）',
      'artist': '周杰伦',
    };
    final Map<String, String> d1 =
        TagFill.diff(before, candidate(), modes: allModes(TagFill.supplement));
    expect(TagFill.describe(d1), '专辑、年份');
    expect(TagFill.describe(<String, String>{}), '');
  });

  test('字段级三态策略（不写 / 只补空 / 覆盖）', () {
    final Map<String, String> before2 = <String, String>{
      'title': '晴天（旧）',
      'artist': '周杰伦',
    };
    final Map<String, int> modes = allModes(TagFill.supplement)
      ..['title'] = TagFill.disabled
      ..['artist'] = TagFill.overwrite;
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
