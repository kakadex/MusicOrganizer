import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/scan/search_query.dart';

void main() {
  group('解析', () {
    test('空输入为空查询', () {
      final SearchQuery q = SearchQuery.parse('');
      expect(q.isEmpty, isTrue);
      expect(SearchQuery.parse(null).isEmpty, isTrue);
    });

    test('自由词按空白切分', () {
      final SearchQuery q = SearchQuery.parse('示例 曲目');
      expect(q.terms, <String>['示例', '曲目']);
      expect(q.raw, <String>['示例', '曲目']);
      expect(q.hasFieldFilter, isFalse);
    });

    test('双引号把带空格的内容并成一个词', () {
      final SearchQuery q = SearchQuery.parse('"示例 曲目" 其它');
      expect(q.raw, <String>['示例 曲目', '其它']);
    });

    test('字段前缀与中文别名', () {
      final SearchQuery q = SearchQuery.parse('artist:示例歌手 专辑:示例专辑');
      expect(q.fields['artist'], isNotNull);
      expect(q.fields['album'], isNotNull);
      expect(q.terms, isEmpty);

      final SearchQuery zh = SearchQuery.parse('歌手:示例 格式:mp3');
      expect(zh.fields['artist'], isNotNull);
      expect(zh.fields['ext'], isNotNull);
    });

    test('词会被归一：繁转简 + 去标点 + 小写', () {
      final SearchQuery q = SearchQuery.parse('Track-01（A）');
      expect(q.terms.first.toLowerCase(), 'track01a');
    });
  });

  group('大小条件', () {
    test('> / < / >= / <= 与无操作符区间', () {
      expect(SearchQuery.parse('size:>10m').minSize, 10 * 1024 * 1024 + 1);
      expect(SearchQuery.parse('size:>=1k').minSize, 1024);
      expect(SearchQuery.parse('size:<1k').maxSize, 1023);
      expect(SearchQuery.parse('size:<=1k').maxSize, 1024);

      final SearchQuery q = SearchQuery.parse('size:1000');
      expect(q.minSize, 900);
      expect(q.maxSize, 1100);
    });

    test('单位解析与非法值', () {
      expect(SearchQuery.parseBytes('2m'), 2 * 1024 * 1024);
      expect(SearchQuery.parseBytes('1.5k'), 1536);
      expect(SearchQuery.parseBytes('4096'), 4096);
      expect(SearchQuery.parseBytes('abc'), -1);
    });

    test('大小条件也算非空查询', () {
      expect(SearchQuery.parse('size:>1m').isEmpty, isFalse);
    });
  });

  group('描述', () {
    test('把输入还原成一行', () {
      final SearchQuery q =
          SearchQuery.parse('示例 title:标题 size:>=1m');
      final String s = q.describe();
      expect(s.contains('示例'), isTrue);
      expect(s.contains('title:'), isTrue);
      expect(s.contains('size>='), isTrue);
    });
  });
}
