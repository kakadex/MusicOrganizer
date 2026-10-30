/// 标签繁转简：只做「哪些字段要改」的纯逻辑（T-13 同批）。
library;

import 'package:flutter_test/flutter_test.dart' hide Tags;
import 'package:musicorganizer/core/model/tags.dart';
import 'package:musicorganizer/core/tag/tag_zh.dart';

void main() {
  test('繁体字段会被挑出来，简体字段不动', () {
    final Tags t = Tags();
    t.put('artist', '張學友');
    t.put('title', '她來聽我的演唱會');
    t.put('album', '走過1999');
    t.put('year', '1999');
    final Map<String, String> c = TagZh.changes(t);
    expect(c['artist'], '张学友');
    expect(c['title'], '她来听我的演唱会');
    expect(c['album'], '走过1999');
    expect(c.containsKey('year'), isFalse);
  });

  test('本来就是简体的不动，返回空', () {
    final Tags t = Tags();
    t.put('artist', '张学友');
    t.put('title', '她来听我的演唱会');
    expect(TagZh.changes(t), isEmpty);
    expect(TagZh.hasChange(t), isFalse);
  });

  test('英文与数字原样保留', () {
    final Tags t = Tags();
    t.put('artist', 'Beyond');
    t.put('title', '光輝歲月');
    final Map<String, String> c = TagZh.changes(t);
    expect(c['title'], '光辉岁月');
    expect(c.containsKey('artist'), isFalse);
  });

  test('内嵌歌词也参与转换', () {
    final Tags t = Tags();
    t.put(Tags.lyrics, '[00:01]後來 我總算學會了');
    final Map<String, String> c = TagZh.changes(t);
    expect(c[Tags.lyrics], '[00:01]后来 我总算学会了');
  });

  test('空字段不进计划', () {
    final Tags t = Tags();
    t.put('artist', '');
    t.put('title', '  ');
    expect(TagZh.changes(t), isEmpty);
  });
}
