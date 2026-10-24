import com.dsh.musicorganizer.core.ScanMerge;
import com.dsh.musicorganizer.core.Tags;
import com.dsh.musicorganizer.core.VFile;

import java.util.ArrayList;
import java.util.List;

/**
 * 增量扫描回归（纯 JVM）。
 *
 * <p>这块逻辑决定「重扫目录要不要把整库标签再读一遍」：只有 docId + size + lastModified
 * 都没变的文件才允许沿用上次的标签缓存。判宽了会把改过的文件当成没改（显示旧标签），
 * 判严了等于没优化（每次全库重读），所以四个分支都要钉住。
 */
public final class ScanMergeTest {

    private static int passed = 0;
    private static int failed = 0;

    public static void main(String[] args) {
        carriesOver();
        detectsSizeChange();
        detectsTimeChange();
        newAndRemoved();
        uncachedMustReread();
        ignoresNonAudio();
        dedupesDuplicates();
        nullPrevious();
        summaryText();

        System.out.println();
        System.out.println("结果：通过 " + passed + "，失败 " + failed);
        if (failed > 0) {
            System.exit(1);
        }
    }

    // ------------------------------------------------------------------

    private static void carriesOver() {
        section("未改动的文件接力标签");
        VFile old = audio("primary:Music/a.mp3", 1000L, 111L);
        Tags tags = new Tags();
        tags.put("title", "晴天");
        tags.put("artist", "周杰伦");
        old.cacheMeta(tags, true, false);

        List<VFile> previous = one(old);
        List<VFile> current = one(audio("primary:Music/a.mp3", 1000L, 111L));
        ScanMerge.Result r = ScanMerge.merge(previous, current);

        check("复用 1 首", r.reused == 1);
        check("无需重读", r.fresh == 0);
        check("无删除", r.removed == 0);
        VFile now = r.files.get(0);
        check("标签已挂到新对象", now.metaCached());
        check("标题正确", "晴天".equals(now.cachedTags.get("title")));
        check("艺人正确", "周杰伦".equals(now.cachedTags.get("artist")));
        check("封面标志保留", now.cachedHasCover);
        check("两份标签不是同一个对象", now.cachedTags != old.cachedTags);
    }

    private static void detectsSizeChange() {
        section("大小变了 → 必须重读");
        VFile old = audio("primary:Music/a.mp3", 1000L, 111L);
        old.cacheMeta(tagged("旧标题"), false, false);
        List<VFile> current = one(audio("primary:Music/a.mp3", 2000L, 111L));

        ScanMerge.Result r = ScanMerge.merge(one(old), current);
        check("判为重读", r.fresh == 1);
        check("没复用", r.reused == 0);
        check("缓存已清空", !r.files.get(0).metaCached());
    }

    private static void detectsTimeChange() {
        section("修改时间变了 → 必须重读");
        VFile old = audio("primary:Music/a.mp3", 1000L, 111L);
        old.cacheMeta(tagged("旧标题"), false, false);
        List<VFile> current = one(audio("primary:Music/a.mp3", 1000L, 222L));

        ScanMerge.Result r = ScanMerge.merge(one(old), current);
        check("判为重读", r.fresh == 1);
        check("没复用", r.reused == 0);
    }

    private static void newAndRemoved() {
        section("新增与移除");
        VFile old = audio("primary:Music/gone.mp3", 500L, 1L);
        old.cacheMeta(tagged("走了"), false, false);
        List<VFile> previous = one(old);

        List<VFile> current = new ArrayList<VFile>();
        current.add(audio("primary:Music/new.mp3", 700L, 2L));
        current.add(audio("primary:Music/gone.mp3", 500L, 1L));

        ScanMerge.Result r = ScanMerge.merge(previous, current);
        check("新增算重读", r.fresh == 1);
        check("保留的接力", r.reused == 1);
        check("没有删除", r.removed == 0);

        // 第二次：去掉 gone，换上一个全新文件
        List<VFile> next = new ArrayList<VFile>();
        next.add(audio("primary:Music/new.mp3", 700L, 2L));
        next.add(audio("primary:Music/other.mp3", 800L, 3L));
        ScanMerge.Result r2 = ScanMerge.merge(current, next);
        check("删掉 1 首", r2.removed == 1);
        check("两首都算重读（new.mp3 上一轮也没缓存）", r2.fresh == 2);
        check("没有复用", r2.reused == 0);
    }

    private static void uncachedMustReread() {
        section("没读过的文件不能冒充已读");
        // 文件没变，但上次从没读过标签（metaCached=false）→ 仍需重读
        VFile old = audio("primary:Music/a.mp3", 1000L, 111L);
        List<VFile> current = one(audio("primary:Music/a.mp3", 1000L, 111L));
        ScanMerge.Result r = ScanMerge.merge(one(old), current);
        check("判为重读", r.fresh == 1);
        check("没复用", r.reused == 0);
        check("缓存仍为空", !r.files.get(0).metaCached());
    }

    private static void ignoresNonAudio() {
        section("目录与歌词不参与");
        VFile dir = new VFile("primary:Music/周杰伦", "primary:Music", "周杰伦",
                "vnd.android.document/directory", 0, 0, true);
        VFile lrc = new VFile("primary:Music/a.lrc", "primary:Music", "a.lrc",
                "text/plain", 100L, 5L, false);
        lrc.cacheMeta(tagged("歌词文件不该有标签"), false, false);

        List<VFile> previous = new ArrayList<VFile>();
        previous.add(dir);
        previous.add(lrc);
        previous.add(audio("primary:Music/a.mp3", 1000L, 111L));

        List<VFile> current = new ArrayList<VFile>();
        current.add(dir);
        current.add(lrc);
        current.add(audio("primary:Music/a.mp3", 1000L, 111L));

        ScanMerge.Result r = ScanMerge.merge(previous, current);
        check("只统计 1 首音频", r.fresh + r.reused == 1);
        check("无删除", r.removed == 0);
        check("文件总数保持不变", r.files.size() == 3);
    }

    /** v0.1.57：同一 docId 出现两次（provider 重复返回）必须只留一条。 */
    private static void dedupesDuplicates() {
        VFile a1 = audio("primary:Music/a.mp3", 100, 1);
        VFile a2 = audio("primary:Music/a.mp3", 100, 1);
        java.util.List<VFile> now = new java.util.ArrayList<VFile>();
        now.add(a1);
        now.add(a2);
        ScanMerge.Result r = ScanMerge.merge(null, now);
        check("重复条目被去掉", r.files.size() == 1);
        check("保留的是第一条", r.files.get(0) == a1);
    }

    private static void nullPrevious() {
        section("首次扫描");
        List<VFile> current = new ArrayList<VFile>();
        current.add(audio("primary:Music/a.mp3", 1000L, 1L));
        current.add(audio("primary:Music/b.mp3", 2000L, 2L));
        ScanMerge.Result r = ScanMerge.merge(null, current);
        check("全部算重读", r.fresh == 2);
        check("无复用", r.reused == 0);
        check("无删除", r.removed == 0);
        check("结果不为空", r.files.size() == 2);
    }

    private static void summaryText() {
        section("日志文案");
        VFile old = audio("primary:Music/a.mp3", 1000L, 111L);
        old.cacheMeta(tagged("x"), false, false);
        List<VFile> previous = new ArrayList<VFile>();
        previous.add(old);
        previous.add(audio("primary:Music/gone.mp3", 1L, 1L));

        List<VFile> current = new ArrayList<VFile>();
        current.add(audio("primary:Music/a.mp3", 1000L, 111L));
        current.add(audio("primary:Music/new.mp3", 2L, 2L));

        ScanMerge.Result r = ScanMerge.merge(previous, current);
        String s = r.summary();
        check("包含复用数", s.contains("复用 1"));
        check("包含重读数", s.contains("重读 1"));
        check("包含移除数", s.contains("移除 1"));
    }

    // ------------------------------------------------------------------

    private static Tags tagged(String title) {
        Tags t = new Tags();
        t.put("title", title);
        return t;
    }

    private static VFile audio(String docId, long size, long modified) {
        return new VFile(docId, "primary:Music", docId.substring(docId.lastIndexOf('/') + 1),
                "audio/mpeg", size, modified, false);
    }

    private static List<VFile> one(VFile f) {
        List<VFile> l = new ArrayList<VFile>();
        l.add(f);
        return l;
    }

    private static void section(String name) {
        System.out.println();
        System.out.println("[" + name + "]");
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
