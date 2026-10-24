import com.dsh.musicorganizer.core.SearchIndex;
import com.dsh.musicorganizer.core.SearchQuery;
import com.dsh.musicorganizer.core.Tags;

import java.util.List;

/**
 * 搜索解析 + 索引匹配回归（纯 JVM）。
 *
 * 覆盖：分词 / 引号 / 字段别名 / 大小比较 / 繁简归一 / 标签与歌词命中 /
 * 未读标签的降级 / 空查询。
 */
public final class SearchIndexTest {

    private static int passed = 0;
    private static int failed = 0;

    public static void main(String[] args) {
        parsing();
        sizes();
        matching();
        fields();
        robustness();
        dedupesSameDocId();

        System.out.println();
        System.out.println("结果：通过 " + passed + "，失败 " + failed);
        if (failed > 0) {
            System.exit(1);
        }
    }

    // ------------------------------------------------------------------

    private static void parsing() {
        section("查询解析");
        SearchQuery q = SearchQuery.parse("周杰伦 晴天");
        check("两个词", q.terms.size() == 2);
        check("第一个词", "周杰伦".equals(q.terms.get(0)));
        check("raw 保留原文", q.raw.size() == 2 && "晴天".equals(q.raw.get(1)));
        check("非空", !q.isEmpty());

        q = SearchQuery.parse("\"晴天 2004\"");
        check("引号内成一个词", q.terms.size() == 1 && q.raw.get(0).contains(" "));

        q = SearchQuery.parse("artist:周杰伦");
        check("字段被识别", q.fields.containsKey("artist"));
        check("字段不进词表", q.terms.isEmpty());
        check("字段值归一", "周杰伦".equals(q.fields.get("artist")));

        q = SearchQuery.parse("歌手：周杰伦");
        check("中文全角冒号不算字段（按普通词）", q.fields.isEmpty());

        q = SearchQuery.parse("歌手:周杰伦");
        check("中文别名可用", q.fields.containsKey("artist"));

        q = SearchQuery.parse("http://x.com/a");
        check("未知前缀按普通词", q.fields.isEmpty() && q.terms.size() == 1);

        check("空输入为空查询", SearchQuery.parse("   ").isEmpty());
        check("null 不崩", SearchQuery.parse(null).isEmpty());
    }

    private static void sizes() {
        section("大小条件");
        SearchQuery q = SearchQuery.parse("size:>10m");
        check("下界 10MB", q.minSize == 10L * 1024 * 1024 + 1);
        check("无上界", q.maxSize < 0);

        q = SearchQuery.parse("size:<1g");
        check("上界 1G", q.maxSize == 1024L * 1024 * 1024 - 1);

        q = SearchQuery.parse("size:800k");
        check("无比较符取 ±10%", q.minSize > 700 * 1024 && q.maxSize < 900 * 1024);

        q = SearchQuery.parse("size:abc");
        check("非法大小被忽略", q.minSize < 0 && q.maxSize < 0 && q.isEmpty());

        check("parseBytes 10m", SearchQuery.parseBytes("10m") == 10L * 1024 * 1024);
        check("parseBytes 1.5g", SearchQuery.parseBytes("1.5g") == (long) (1.5 * 1024 * 1024 * 1024));
        check("parseBytes 纯数字", SearchQuery.parseBytes("4096") == 4096);
        check("parseBytes 非法", SearchQuery.parseBytes("x") < 0);
    }

    private static void matching() {
        section("匹配");
        SearchIndex index = new SearchIndex();
        index.add(entry("Music/周杰伦/晴天.flac", 30_000_000, "晴天", "周杰伦", "叶惠美"));
        index.add(entry("Music/陈奕迅/十年.mp3", 8_000_000, "十年", "陈奕迅", "黑白灰"));
        index.add(entry("Music/杂/未命名.mp3", 2_000_000, "", "", ""));

        check("空查询返回全部", index.search(SearchQuery.parse("")).size() == 3);
        check("按标题词命中", index.search(SearchQuery.parse("晴天")).size() == 1);
        check("按艺人命中", index.search(SearchQuery.parse("周杰伦")).size() == 1);
        check("空格分词 AND", index.search(SearchQuery.parse("周杰伦 十年")).isEmpty());
        check("两个词都成立", index.search(SearchQuery.parse("周杰伦 晴天")).size() == 1);
        check("命中路径", index.search(SearchQuery.parse("杂")).size() == 1);

        // 繁体输入命中简体标签（归一）
        check("繁简归一", index.search(SearchQuery.parse("周傑倫")).size() == 1);

        // 未读标签时用文件名兜底
        SearchIndex raw = new SearchIndex();
        raw.add(new SearchIndex.Entry("primary:Music/x/夜曲.mp3", "夜曲.mp3",
                "Music/x/夜曲.mp3", 5_000_000, 0, null));
        check("未读标签也能按文件名搜", raw.search(SearchQuery.parse("夜曲")).size() == 1);
        check("未读标签的 title: 回退文件名",
                raw.search(SearchQuery.parse("title:夜曲")).size() == 1);
    }

    private static void fields() {
        section("字段与歌词");
        SearchIndex index = new SearchIndex();
        SearchIndex.Entry e = entry("Music/a/歌.mp3", 4_000_000, "歌", "某人", "专辑A");
        e.year = "2004";
        e.genre = "流行";
        e.applyLyrics("[00:01]如果那天没有下雨");
        index.add(e);
        index.add(entry("Music/a/另一首.mp3", 4_000_000, "另一首", "别人", "专辑B"));

        check("专辑字段", index.search(SearchQuery.parse("album:专辑A")).size() == 1);
        check("年份字段", index.search(SearchQuery.parse("year:2004")).size() == 1);
        check("流派字段", index.search(SearchQuery.parse("genre:流行")).size() == 1);
        check("歌词命中", index.search(SearchQuery.parse("歌词:下雨")).size() == 1);
        check("歌词自由词也能命中", index.search(SearchQuery.parse("下雨")).size() == 1);
        check("ext 字段", index.search(SearchQuery.parse("ext:mp3")).size() == 2);
        check("多个字段同时成立",
                index.search(SearchQuery.parse("artist:某人 album:专辑A")).size() == 1);
        check("字段冲突返回空",
                index.search(SearchQuery.parse("artist:某人 album:专辑B")).isEmpty());
        check("大小过滤", index.search(SearchQuery.parse("size:<1k")).isEmpty());
    }

    /** v0.1.57：同一个 docId 连加两次，索引里只能有一条（否则库页列两遍）。 */
    private static void dedupesSameDocId() {
        SearchIndex index = new SearchIndex();
        SearchIndex.Entry a = new SearchIndex.Entry("primary:Music/x/a.mp3", "a.mp3",
                "x/a.mp3", 100, 1, null);
        SearchIndex.Entry b = new SearchIndex.Entry("primary:Music/x/a.mp3", "a.mp3",
                "x/a.mp3", 100, 1, null);
        index.add(a);
        index.add(b);
        check("同 docId 只留一条", index.all().size() == 1);
        check("find 返回最后加入的", index.find("primary:Music/x/a.mp3") == b);
    }

    private static void robustness() {
        section("容错与统计");
        SearchIndex index = new SearchIndex();
        check("空索引搜索", index.search(SearchQuery.parse("x")).isEmpty());
        check("size=0", index.size() == 0);

        SearchIndex.Entry e = new SearchIndex.Entry("a/b.mp3", "b.mp3", "a/b.mp3",
                100, 0, null);
        check("未读标签不算已读", !e.metaLoaded);
        Tags tags = new Tags();
        tags.put("title", "标题");
        tags.put("artist", "艺人");
        e.applyTags(tags, true);
        check("applyTags 置标记", e.metaLoaded && e.hasCover);
        check("applyTags 生效", "标题".equals(e.displayTitle()));
        check("副标题拼接", "艺人".equals(e.displaySub()));
        check("标签不全判否", !e.tagComplete());

        e.applyLyrics("一二三");
        check("applyLyrics 置 hasLyrics", e.hasLyrics);
        index.add(e);
        check("loadedCount", index.loadedCount() == 1);
        check("find 按 docId", index.find("a/b.mp3") == e);

        // 超长歌词只留前缀，避免内存爆掉
        StringBuilder big = new StringBuilder();
        for (int i = 0; i < SearchIndex.LYRICS_HEAD + 5000; i++) {
            big.append('词');
        }
        SearchIndex.Entry bigE = entry("c/d.mp3", 100, "", "", "");
        bigE.applyLyrics(big.toString());
        check("歌词被截断", bigE.lyrics.length() == SearchIndex.LYRICS_HEAD);

        List<SearchIndex.Entry> all = index.all();
        check("all() 反映列表", all.size() == 1);
    }

    // ------------------------------------------------------------------

    private static SearchIndex.Entry entry(String docId, long size, String title,
                                           String artist, String album) {
        SearchIndex.Entry e = new SearchIndex.Entry(docId, docId.substring(docId.lastIndexOf('/') + 1),
                docId, size, 1_700_000_000_000L, null);
        e.title = title;
        e.artist = artist;
        e.album = album;
        e.metaLoaded = true;
        e.renormalize();
        return e;
    }

    private static void section(String title) {
        System.out.println("[ " + title + " ]");
    }

    private static void check(String name, boolean ok) {
        if (ok) {
            passed++;
            System.out.println("  ok   " + name);
        } else {
            failed++;
            System.out.println("  FAIL " + name);
        }
    }
}
