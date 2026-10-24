import com.dsh.musicorganizer.core.HealthCheck;

/**
 * 曲库体检回归（纯 JVM）。
 *
 * <p>盯的是计数与完整度：五项维度逐首累加不能串味，完整度不能出现负数或超过 100，
 * 尺寸格式化的进位要对得上。
 */
public class HealthCheckTest {

    private static int pass = 0;
    private static int fail = 0;

    public static void main(String[] args) {
        // 1) 单条的缺失描述与得分
        HealthCheck.Item full = item("a.mp3", ".mp3", 100, true, true, true, true, true);
        check("齐全得分 5", full.score() == 5);
        check("齐全无缺失", full.missing().isEmpty());

        HealthCheck.Item bare = item("b.mp3", ".mp3", 100, false, false, false, false, false);
        check("全缺得分 0", bare.score() == 0);
        check("全缺列五项", bare.missing().split("/").length == 5);

        HealthCheck.Item noCoverNoLyrics = item("c.flac", ".flac", 100, true, true, true, false, false);
        check("缺两项得分 3", noCoverNoLyrics.score() == 3);
        check("缺两项描述", noCoverNoLyrics.missing().equals("缺封面/缺歌词"));

        // 2) 累加
        HealthCheck.Report r = new HealthCheck.Report();
        r.add(full);
        r.add(noCoverNoLyrics);
        r.add(bare);
        check("首数 3", r.audio == 3);
        check("字节累加", r.bytes == 300);
        check("缺标题 1", r.noTitle == 1);
        check("缺歌手 1", r.noArtist == 1);
        check("缺专辑 1", r.noAlbum == 1);
        check("缺封面 2", r.noCover == 2);
        check("缺歌词 2", r.noLyrics == 2);
        check("齐全 1 首", r.complete() == 1);
        check("问题 2 条", r.issues.size() == 2);

        // 3) 完整度：3 首 × 5 维 = 15，满足 5 + 3 + 0 = 8 → 53%
        check("完整度 53%", r.completeness() == 53);
        check("headline 带首数", r.headline().contains("3 首"));

        // 4) 全齐 → 100%
        HealthCheck.Report perfect = new HealthCheck.Report();
        perfect.add(full);
        check("全齐 100%", perfect.completeness() == 100);
        check("全齐无问题", perfect.issues.isEmpty());

        // 5) 空库
        HealthCheck.Report empty = new HealthCheck.Report();
        check("空库 0%", empty.completeness() == 0);
        check("空库 headline", empty.headline().contains("没有"));

        // 6) lines 只为非零项出现
        check("lines 两项", perfect.lines().isEmpty());
        check("lines 五项", bareOnly().lines().size() == 5);

        // 7) 格式分布按首数倒序
        HealthCheck.Report exts = new HealthCheck.Report();
        exts.add(item("1.mp3", ".mp3", 1, true, true, true, true, true));
        exts.add(item("2.mp3", ".mp3", 1, true, true, true, true, true));
        exts.add(item("3.flac", ".flac", 1, true, true, true, true, true));
        check("mp3 排在前面", exts.extLine().startsWith("mp3 2 首"));
        check("单格式也列", exts.extLine().contains("flac 1 首"));

        // 8) 无扩展名归到「其它」
        HealthCheck.Report other = new HealthCheck.Report();
        other.add(item("noext", "", 1, true, true, true, true, true));
        check("空扩展名归其它", other.extLine().contains("其它"));

        // 9) 问题清单上限 200
        HealthCheck.Report many = new HealthCheck.Report();
        for (int i = 0; i < 260; i++) {
            many.add(item("x" + i + ".mp3", ".mp3", 1, false, false, false, false, false));
        }
        check("清单封顶 200", many.issues.size() == 200);

        // 10) 尺寸格式化
        check("字节", HealthCheck.size(512).equals("512 B"));
        check("KB", HealthCheck.size(2048).equals("2.0 KB"));
        check("MB", HealthCheck.size(3 * 1024 * 1024).equals("3.0 MB"));
        check("GB", HealthCheck.size(2L * 1024 * 1024 * 1024).startsWith("2.00 GB"));

        System.out.println("结果：通过 " + pass + "，失败 " + fail);
        if (fail > 0) {
            System.exit(1);
        }
    }

    private static HealthCheck.Report bareOnly() {
        HealthCheck.Report r = new HealthCheck.Report();
        r.add(item("b.mp3", ".mp3", 1, false, false, false, false, false));
        return r;
    }

    private static HealthCheck.Item item(String name, String ext, long size,
                                         boolean title, boolean artist, boolean album,
                                         boolean cover, boolean lyrics) {
        HealthCheck.Item it = new HealthCheck.Item(name, ext, size);
        it.title = title;
        it.artist = artist;
        it.album = album;
        it.cover = cover;
        it.lyrics = lyrics;
        return it;
    }

    private static void check(String label, boolean ok) {
        if (ok) {
            pass++;
            System.out.println("  ok   " + label);
        } else {
            fail++;
            System.out.println("  FAIL " + label);
        }
    }
}
