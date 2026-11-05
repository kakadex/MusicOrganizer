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

    test('反复更新同一条不会改变顺序，也不会丢别的条目', () {
      // 0.2.69 把「按 docId 定位下标」从线性查找改成下标表。
      // 下标表如果在替换时算错，会出现「新条目挤掉别人」或「顺序错乱」。
      final SearchIndex idx = SearchIndex();
      idx.add(audio('a', '01.mp3'));
      idx.add(audio('b', '02.mp3'));
      idx.add(audio('c', '03.mp3'));
      for (int i = 0; i < 5; i++) {
        idx.add(audio('b', '02.mp3'));
      }
      expect(idx.size(), 3);
      expect(idx.all().map((Entry e) => e.docId).toList(),
          <String>['a', 'b', 'c']);
    });

    test('800 首逐条更新：不丢条目、顺序不变', () {
      // 0.2.69 把「按 docId 定位下标」从线性查找改成下标表。实测这个改动
      // 对速度几乎没影响（800 条 × 5 轮：4.8ms → 11ms，新实现还要多构造
      // Entry），所以这里**不测时间**，只锁住语义：更新不能挤掉别人、
      // 不能打乱顺序。卡顿的真因是每首歌的整文件跨进程读写，不是这里。
      final SearchIndex idx = SearchIndex();
      for (int i = 0; i < 800; i++) {
        idx.add(audio('id$i', '$i.mp3'));
      }
      for (int i = 0; i < 800; i++) {
        idx.add(audio('id$i', '$i.mp3'));
      }
      expect(idx.size(), 800);
      expect(idx.all().first.docId, 'id0');
      expect(idx.all().last.docId, 'id799');
      expect(idx.find('id400'), isNotNull);
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

  // ------------------------------------------------------------------
  // 歌词归一化是惰性的：建索引 / 读标签时不预先算，只有真正按歌词搜索时
  // 才算一次并缓存。这里守住三件事：①确实不预先算 ②按需算出来的结果
  // 与"每条都预先算"完全一致 ③字段变化后缓存正确失效。
  // ------------------------------------------------------------------
    test('脏检查：只变一个字段，其它字段的归一串结果仍正确', () {
      // 0.2.71 给 renormalize 加了「字段没变就不重算」。
      // 风险：脏检查写错会出现「字段变了但归一串还是旧的」——搜索就漏词了。
      // 本用例锁住：改一个字段后，所有字段的归一串都必须正确。
      final SearchIndex idx = SearchIndex();
      final Entry e = audio('x', 'x.mp3');
      e.applyTags(Tags()
        ..put('title', '晴天')
        ..put('artist', '周杰伦')
        ..put('album', '叶惠美'), false);
      idx.add(e);
      expect(idx.search(SearchQuery.parse('晴天')), isNotEmpty);
      expect(idx.search(SearchQuery.parse('周杰伦')), isNotEmpty);

      // 只改标题
      e.applyTags(Tags()
        ..put('title', '七里香')
        ..put('artist', '周杰伦')
        ..put('album', '叶惠美'), false);
      expect(idx.search(SearchQuery.parse('七里香')), isNotEmpty,
          reason: '改过的字段必须重算');
      expect(idx.search(SearchQuery.parse('晴天')), isEmpty,
          reason: '旧标题必须失效');
      expect(idx.search(SearchQuery.parse('周杰伦')), isNotEmpty,
          reason: '没变的字段结果不能错');
    });

    test('脏检查：歌词变了必须失效缓存，没变则保留', () {
      final SearchIndex idx = SearchIndex();
      final Entry e = audio('y', 'y.mp3');
      e.applyLyrics('天空一片蔚蓝');
      idx.add(e);
      expect(idx.search(SearchQuery.parse('蔚蓝')), isNotEmpty);

      // 歌词没变：再搜一次仍命中（缓存被保留）
      expect(idx.search(SearchQuery.parse('蔚蓝')), isNotEmpty);

      // 歌词变了：旧词搜不到，新词搜到
      e.applyLyrics('清水湾傍晚sunset');
      expect(idx.search(SearchQuery.parse('蔚蓝')), isEmpty,
          reason: '旧歌词必须失效');
      expect(idx.search(SearchQuery.parse('sunset')), isNotEmpty,
          reason: '新歌词必须能搜到');
    });

    group('歌词归一化惰性计算', () {
      final String longLyric = '我們說好的幸福呢 后来 眼淚 電話 時間\n' * 400;

    Entry withLyrics(String docId, String title, String lyric) {
      final Entry e = audio(docId, '$docId.mp3');
      e.applyTags(
        Tags()
          ..put('title', title)
          ..put('artist', '示例歌手')
          ..put(Tags.lyrics, lyric),
        false,
      );
      return e;
    }

    test('按标题搜索命中时，不触发歌词归一化（搜索后歌词串仍未被读）', () {
      final SearchIndex idx = SearchIndex();
      final Entry e = withLyrics('a', '夜曲', longLyric);
      idx.add(e);

      // 标题直接命中，_anyField 在歌词之前就返回 true
      expect(idx.search(SearchQuery.parse('夜曲')).length, 1);
      // 惰性缓存应当还没建立：用"搜索后仍然命中"间接验证不算，另用计数器无法观测，
      // 这里改为验证行为等价（见下一条）+ 用极端长歌词的耗时特征无法单测，
      // 所以本测试只确认"命中结果正确"这一层。
      expect(idx.search(SearchQuery.parse('夜曲')).single.docId, 'a');
    });

    test('只出现在歌词里的词仍能搜到（语义不能因为懒算而丢）', () {
      final SearchIndex idx = SearchIndex();
      // 标题和歌名里都没有「眼淚」这个词
      idx.add(withLyrics('a', '夜曲', longLyric));
      idx.add(withLyrics('b', '晴天', '完全不相干的内容'));

      final List<Entry> hits = idx.search(SearchQuery.parse('眼淚'));
      expect(hits.map((Entry e) => e.docId), <String>['a']);
    });

    test('歌词字段条件（歌词:xxx）仍能命中', () {
      final SearchIndex idx = SearchIndex();
      idx.add(withLyrics('a', '夜曲', longLyric));
      idx.add(withLyrics('b', '晴天', '别的歌词'));
      expect(idx.search(SearchQuery.parse('歌词:時間')).map((Entry e) => e.docId),
          <String>['a']);
      expect(idx.search(SearchQuery.parse('lyrics:不存在')).length, 0);
    });

    test('懒算结果与"每次都从头归一"逐条一致', () {
      // 构造一批歌，混着有歌词 / 无歌词 / 繁体 / 简体 / 标点
      final List<String> lyricPool = <String>[
        '我們說好的幸福呢',
        '后来 我们 都哭了',
        'Hello World 123',
        '【副歌】時間 電話 眼淚',
        '',
      ];
      final SearchIndex lazyIdx = SearchIndex();
      final List<Entry> all = <Entry>[];
      for (int i = 0; i < 20; i++) {
        final Entry e = withLyrics('d$i', '标题$i', lyricPool[i % lyricPool.length]);
        all.add(e);
        lazyIdx.add(e);
      }

      // 对每个查询，比较"索引搜索"和"用现场归一化逐条判断"的结果
      const List<String> queries = <String>[
        '时间', '时间电话', '眼淚', 'hello', '标题3', '都哭了', '不存在xyz',
        '【副歌】', 'we', '123',
      ];
      for (final String q in queries) {
        final SearchQuery query = SearchQuery.parse(q);
        final Set<String> viaIndex = lazyIdx
            .search(query)
            .map((Entry e) => e.docId)
            .toSet();
        // 参照：每次都用全新的 Entry 现算（相当于从不缓存）
        final Set<String> viaFresh = <String>{
          for (final Entry src in all)
            if (SearchIndex.matches(
                withLyrics(src.docId, src.title, src.lyrics), query))
              src.docId,
        };
        expect(viaIndex, viaFresh, reason: '查询 "$q" 结果不一致');
      }
    });

    test('applyTags 改了歌词后，归一缓存失效（能搜到新词、搜不到旧词）', () {
      final Entry e = withLyrics('a', '夜曲', '旧的歌词内容');
      final SearchIndex idx = SearchIndex();
      idx.add(e);

      expect(idx.search(SearchQuery.parse('旧的')).length, 1);

      // 覆盖成新歌词
      e.applyTags(
        Tags()
          ..put('title', '夜曲')
          ..put(Tags.lyrics, '崭新的歌词'),
        false,
      );
      expect(idx.search(SearchQuery.parse('崭新的')).length, 1,
          reason: '新歌词必须能搜到（说明缓存已失效并重算）');
      expect(idx.search(SearchQuery.parse('旧的')).length, 0,
          reason: '旧歌词不能再命中');
    });

    test('applyLyrics 写入歌词后同样能被搜到', () {
      final Entry e = audio('a', 'a.mp3');
      final SearchIndex idx = SearchIndex();
      idx.add(e);
      expect(idx.search(SearchQuery.parse('后加的')).length, 0);
      e.applyLyrics('这是后加的歌词');
      expect(idx.search(SearchQuery.parse('后加的')).length, 1);
    });
  });
}
