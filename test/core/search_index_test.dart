import 'package:flutter_test/flutter_test.dart' hide Tags;
import 'package:musicorganizer/core/model/tags.dart';
import 'package:musicorganizer/core/scan/search_index.dart';
import 'package:musicorganizer/core/scan/search_query.dart';

Entry audio(String docId, String name) => Entry(
      docId: docId,
      name: name,
      relPath: name,
      size: 1024,
      modified: 1,
    );

void main() {
  group('Entry', () {
    test('标题优先标签，其次文件名', () {
      final Entry e = audio('a', '01.mp3');
      expect(e.displayTitle(), '01');
      e.applyTags(Tags()..put('title', '测试标题'), false);
      expect(e.displayTitle(), '测试标题');
      expect(e.metaLoaded, isTrue);
    });

    test('副标题拼艺人 · 专辑', () {
      final Entry e = audio('a', '01.mp3');
      expect(e.displaySub(), '');
      e.applyTags(Tags()..put('artist', '示例歌手'), false);
      expect(e.displaySub(), '示例歌手');
      // 只有艺术家、没有标题 → 不算齐
      expect(e.tagComplete(), isFalse);
      e.applyTags(
          Tags()
            ..put('artist', '示例歌手')
            ..put('album', '示例专辑'),
          false);
      expect(e.displaySub(), '示例歌手 · 示例专辑');
    });

    test('标签完整只看标题与艺术家：缺专辑也算齐', () {
    final Entry e = audio('a', '01.mp3');
    e.applyTags(
        Tags()
          ..put('title', '测试标题')
          ..put('artist', '示例歌手'),
        false);
    expect(e.tagComplete(), isTrue, reason: '缺专辑不算无标签');

    // 缺艺术家
    e.applyTags(Tags()..put('title', '测试标题'), false);
    expect(e.tagComplete(), isFalse);

    // 只有文件名、没有标签标题：文件名不算标题
    final Entry bare = audio('b', '02.mp3');
    expect(bare.displayTitle(), '02');
    bare.applyTags(Tags(), false);
    expect(bare.tagComplete(), isFalse, reason: '文件名不能顶替标签标题');
  });

  test('歌词只留前若干字符并标有歌词', () {
      final Entry e = audio('a', '01.mp3');
      final String long = '啊' * (SearchIndex.lyricsHead + 500);
      e.applyLyrics(long);
      expect(e.lyrics.length, SearchIndex.lyricsHead);
      expect(e.hasLyrics, isTrue);
    });

    test('扩展名与标签齐', () {
      final Entry e = audio('a', '01.MP3');
      expect(e.ext(), 'mp3');
      e.applyTags(
          Tags()
            ..put('title', '测试标题')
            ..put('artist', '示例歌手')
            ..put('album', '示例专辑'),
          false);
      expect(e.tagComplete(), isTrue);
    });
  });

  group('SearchIndex', () {
    test('同一个 docId 只保留一条（重复会让列表出现两遍）', () {
      final SearchIndex idx = SearchIndex();
      idx.add(audio('a', '01.mp3'));
      idx.add(audio('a', '01.mp3'));
      expect(idx.size(), 1);
      expect(idx.find('a'), isNotNull);
      expect(idx.find('b'), isNull);
    });

    test('空查询返回全部且保持插入顺序', () {
      final SearchIndex idx = SearchIndex();
      idx.add(audio('b', '02.mp3'));
      idx.add(audio('a', '01.mp3'));
      expect(idx.search(null).map((Entry e) => e.docId).toList(),
          <String>['b', 'a']);
      expect(idx.search(SearchQuery.parse('')).length, 2);
    });

    test('未读标签时按文件名也能命中', () {
      final SearchIndex idx = SearchIndex();
      idx.add(audio('a', '示例歌名.mp3'));
      expect(idx.search(SearchQuery.parse('示例歌名')).length, 1);
      expect(idx.search(SearchQuery.parse('title:示例歌名')).length, 1);
      expect(idx.loadedCount(), 0);
    });

    test('字段条件命中标签内容', () {
      final SearchIndex idx = SearchIndex();
      final Entry e = audio('a', '01.mp3');
      e.applyTags(
          Tags()
            ..put('artist', '示例歌手')
            ..put('album', '示例专辑')
            ..put('year', '2020'),
          true);
      idx.add(e);
      expect(idx.loadedCount(), 1);
      expect(idx.search(SearchQuery.parse('歌手:示例')).length, 1);
      expect(idx.search(SearchQuery.parse('专辑:别的')).length, 0);
      expect(idx.search(SearchQuery.parse('年份:2020')).length, 1);
      expect(idx.search(SearchQuery.parse('ext:mp3')).length, 1);
    });

    test('大小条件与路径条件', () {
      final SearchIndex idx = SearchIndex();
      final Entry small = audio('a', 'a.mp3');
      idx.add(small);
      final Entry big = Entry(
          docId: 'b', name: 'b.mp3', relPath: '子目录/b.mp3', size: 8 * 1024 * 1024);
      idx.add(big);

      expect(idx.search(SearchQuery.parse('size:>4m')).map((Entry e) => e.docId),
          <String>['b']);
      expect(idx.search(SearchQuery.parse('size:<4m')).map((Entry e) => e.docId),
          <String>['a']);
      expect(idx.search(SearchQuery.parse('路径:子目录')).map((Entry e) => e.docId),
          <String>['b']);
    });

    test('多个条件同时满足才算命中', () {
      final SearchIndex idx = SearchIndex();
      final Entry e = audio('a', '01.mp3');
      e.applyTags(
          Tags()
            ..put('artist', '示例歌手')
            ..put('album', '示例专辑'),
          false);
      idx.add(e);
      expect(idx.search(SearchQuery.parse('示例歌手 示例专辑')).length, 1);
      expect(idx.search(SearchQuery.parse('示例歌手 不存在的词')).length, 0);
    });

    test('clear 清空', () {
      final SearchIndex idx = SearchIndex();
      idx.add(audio('a', 'a.mp3'));
      idx.clear();
      expect(idx.size(), 0);
      expect(idx.all(), isEmpty);
    });
  });
}
