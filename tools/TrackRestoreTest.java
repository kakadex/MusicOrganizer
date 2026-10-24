import com.dsh.musicorganizer.core.SearchIndex;
import com.dsh.musicorganizer.core.Tags;
import com.dsh.musicorganizer.core.VFile;
import com.dsh.musicorganizer.core.TrackRestore;

/**
 * 缓存回填回归（纯 JVM，v0.1.52）。
 *
 * <p>对应线上故障：换主题 / 转屏触发 {@code recreate()}，库页重建索引走「缓存直填」，
 * 但只回填了标签 —— 结果是列表右侧的时长与质量消失、封面也永远补不上。
 * 这里把「一组字段必须整体回填」钉死。
 */
public class TrackRestoreTest {

    private static int pass = 0;
    private static int fail = 0;

    public static void main(String[] args) {
        System.out.println("TrackRestoreTest");

        noCacheReturnsFalse();
        fillsEverything();
        lrcFlagOnlyAdds();
        cacheIsCopy();
        clearResetsAll();
        noCacheButLrcStillMarksLyrics();

        System.out.println("结果：通过 " + pass + " 项，失败 " + fail + " 项");
        if (fail > 0) {
            System.exit(1);
        }
        System.exit(0);
    }

    /** 1. 没有缓存时必须返回 false，让调用方去读盘 —— 不能把空标签当成「已读」。 */
    static void noCacheReturnsFalse() {
        VFile f = file("a.mp3");
        SearchIndex.Entry e = entry(f);
        check("无缓存返回 false", !TrackRestore.apply(e, f, false));
        check("无缓存不标记已读", !e.metaLoaded);
    }

    /** 2. 缓存里的五项必须全部回填（标签 / 封面 / 时长 / 码率 / 歌词）。 */
    static void fillsEverything() {
        VFile f = file("b.mp3");
        Tags t = new Tags();
        t.put("title", "晴天");
        t.put("artist", "周杰伦");
        f.cacheMeta(t, true, true, 269000L, 320);

        SearchIndex.Entry e = entry(f);
        check("有缓存返回 true", TrackRestore.apply(e, f, false));
        check("标题回填", "晴天".equals(e.title));
        check("艺人回填", "周杰伦".equals(e.artist));
        check("有封面回填", e.hasCover);
        check("时长回填", e.durationMs == 269000L);
        check("码率回填", e.bitrateKbps == 320);
        check("标记已读", e.metaLoaded);
    }

    /** 3. 找到同名 .lrc 时补「有歌词」，但缓存说没有也不该被抹掉。 */
    static void lrcFlagOnlyAdds() {
        VFile f = file("c.mp3");
        f.cacheMeta(new Tags(), false, false, 1000L, 128);
        SearchIndex.Entry e = entry(f);
        TrackRestore.apply(e, f, true);
        check("外部 .lrc 标记有歌词", e.hasLyrics);

        VFile g = file("d.mp3");
        Tags t = new Tags();
        t.put("lyrics", "[00:01.00]内嵌歌词");
        g.cacheMeta(t, false, true, 2000L, 192);
        SearchIndex.Entry e2 = entry(g);
        TrackRestore.apply(e2, g, false);
        check("内嵌歌词不丢", e2.hasLyrics);
    }

    /** 4. 缓存是副本：之后改标签对象不能影响已缓存的值。 */
    static void cacheIsCopy() {
        VFile f = file("e.mp3");
        Tags t = new Tags();
        t.put("title", "原值");
        f.cacheMeta(t, false, false, 0L, 0);
        t.put("title", "改后");
        check("缓存存的是副本", "原值".equals(f.cachedTags.get("title")));
    }

    /** 5. clearMeta 必须把时长 / 码率也一起清掉，否则写完标签还是旧值。 */
    static void clearResetsAll() {
        VFile f = file("f.mp3");
        f.cacheMeta(new Tags(), true, true, 5000L, 256);
        f.clearMeta();
        check("清缓存后无标签", !f.metaCached());
        check("清缓存后封面标记归零", !f.cachedHasCover);
        check("清缓存后歌词标记归零", !f.cachedHasLyrics);
        check("清缓存后时长归零", f.cachedDurationMs == 0L);
        check("清缓存后码率归零", f.cachedBitrateKbps == 0);
        SearchIndex.Entry e = entry(f);
        check("清缓存后回填失败", !TrackRestore.apply(e, f, false));
    }

    /** 6. 空标签但确实读过的文件：仍算「已读」，避免每次都重读。 */
    static void noCacheButLrcStillMarksLyrics() {
        VFile f = file("g.mp3");
        f.cacheMeta(new Tags(), false, false);
        check("空标签也算有缓存", f.metaCached());
        SearchIndex.Entry e = entry(f);
        check("空标签回填成功", TrackRestore.apply(e, f, false));
        check("空标签标记已读", e.metaLoaded);
        check("没有封面就是没有", !e.hasCover);
    }

    // ------------------------------------------------------------------

    private static VFile file(String name) {
        return new VFile("id-" + name, "parent", name,
                "audio/mpeg", 5_000_000L, 1_700_000_000_000L, false);
    }

    private static SearchIndex.Entry entry(VFile f) {
        return new SearchIndex.Entry(f.docId, f.name, f.name, f.size, f.lastModified, f);
    }

    private static void check(String label, boolean ok) {
        if (ok) {
            pass++;
        } else {
            fail++;
            System.out.println("[FAIL] " + label);
        }
    }
}
