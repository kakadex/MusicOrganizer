import com.dsh.musicorganizer.core.CancelToken;
import com.dsh.musicorganizer.core.Duplicates;
import com.dsh.musicorganizer.core.Progress;
import com.dsh.musicorganizer.core.VFile;

import java.util.ArrayList;
import java.util.List;

/**
 * 文件名查重回归测试（纯 JVM，不碰磁盘、不碰安卓）。
 *
 * 覆盖：完全相同 / 复制痕迹后缀 / 近似名 / 不同歌不误判 / 建议保留规则 /
 * 相似度打分 / 摘要文案 / 结果排序 / 空输入容错。
 */
public final class DuplicatesTest {

    private static int passed = 0;
    private static int failed = 0;

    /** 静默进度桩。 */
    private static final Progress NO_PROGRESS = new Progress() {
        @Override
        public void onProgress(int done, int total, String message) {
        }
    };

    /** 永不取消的令牌桩。 */
    private static final CancelToken NO_CANCEL = new CancelToken() {
        @Override
        public boolean isCancelled() {
            return false;
        }
    };

    public static void main(String[] args) {
        grouping();
        copies();
        nearMiss();
        keepRule();
        scoring();
        ordering();
        robustness();

        System.out.println();
        System.out.println("结果：通过 " + passed + "，失败 " + failed);
        if (failed > 0) {
            System.exit(1);
        }
    }

    // ------------------------------------------------------------------

    private static void grouping() {
        section("完全同名（不同目录）");
        List<Duplicates.Group> g = run(
                file("Music/周杰伦/晴天.mp3", 4_000_000),
                file("Music/备份/晴天.mp3", 4_000_000));
        check("合成一组", g.size() == 1);
        check("组内两个文件", g.size() == 1 && g.get(0).files.size() == 2);

        section("扩展名不同也算重复");
        g = run(
                file("Music/a/夜曲.mp3", 3_000_000),
                file("Music/b/夜曲.flac", 9_000_000));
        check("mp3/flac 同名一组", g.size() == 1 && g.get(0).files.size() == 2);
    }

    private static void copies() {
        section("复制痕迹后缀");
        List<Duplicates.Group> g = run(
                file("Music/稻香.mp3", 3_000_000),
                file("Music/稻香 (1).mp3", 3_000_000));
        check("「(1)」归一后同组", g.size() == 1);

        g = run(
                file("Music/青花瓷.mp3", 3_000_000),
                file("Music/青花瓷 - 副本.mp3", 3_000_000));
        check("「- 副本」同组", g.size() == 1);

        g = run(
                file("Music/七里香.mp3", 3_000_000),
                file("Music/七里香 copy.mp3", 3_000_000));
        check("「 copy」同组", g.size() == 1);

        g = run(
                file("Music/东风破.mp3", 3_000_000),
                file("Music/东风破_2.mp3", 3_000_000));
        check("「_2」纯数字后缀同组", g.size() == 1);
    }

    private static void nearMiss() {
        section("近似名与误判");
        // 11 字里差一个字 → Levenshtein 0.92，应判为重复（文件名打错/漏字的典型情况）
        List<Duplicates.Group> g = run(
                file("Music/那些年我们一起追的女孩.mp3", 4_000_000),
                file("Music/那些年我们一起追过的女孩.mp3", 4_000_000));
        check("长名一字之差算重复", g.size() == 1);

        // 短名一字之差只有 0.75，不能算重复，否则「晴天 / 雨天」会被误杀
        g = run(
                file("Music/富士山下.mp3", 3_000_000),
                file("Music/富士山夏.mp3", 3_000_000));
        check("短名一字之差不算重复", g.size() == 0);

        g = run(
                file("Music/晴天.mp3", 3_000_000),
                file("Music/雨天.mp3", 3_100_000));
        check("不同歌不算重复", g.size() == 0);

        g = run(
                file("Music/周杰伦 - 晴天.mp3", 3_000_000),
                file("Music/陈奕迅 - 十年.mp3", 3_200_000));
        check("不同艺人不同歌不误判", g.size() == 0);

        g = run(
                file("Music/a.mp3", 1_000_000),
                file("Music/b.mp3", 1_000_000),
                file("Music/c.mp3", 1_000_000));
        check("单字母短名不乱合并（长度 < 3 不参与）", g.size() == 0);
    }

    private static void keepRule() {
        section("建议保留");
        List<Duplicates.Group> g = run(
                file("Music/简单爱 (1).mp3", 3_000_000),
                file("Music/简单爱.mp3", 3_000_000));
        Duplicates.Group group = g.get(0);
        int keep = Duplicates.recommendKeep(group);
        check("保留名字干净的", keep >= 0
                && "简单爱.mp3".equals(group.files.get(keep).file.name));

        g = run(
                file("Music/x/告白气球.mp3", 2_000_000),
                file("Music/告白气球.mp3", 8_000_000));
        group = g.get(0);
        keep = Duplicates.recommendKeep(group);
        check("体积更大的优先", keep >= 0
                && group.files.get(keep).size == 8_000_000);

        check("空组返回 -1", Duplicates.recommendKeep(null) == -1);
    }

    private static void scoring() {
        section("相似度与摘要");
        List<Duplicates.Group> g = run(
                file("Music/夜曲.mp3", 3_000_000),
                file("Music/夜曲 (2).mp3", 3_000_000));
        check("完全归一后 score = 1.0", Math.abs(g.get(0).score - 1.0) < 1e-9);

        g = run(
                file("Music/那些年我们一起追的女孩.mp3", 3_000_000),
                file("Music/那些年我们一起追过的女孩.mp3", 3_000_000));
        check("近似名 score 在 0.9~1 之间",
                g.get(0).score >= 0.90 && g.get(0).score < 1.0);

        String s = Duplicates.summary(g);
        check("摘要含组数", s.contains("1 组"));
        check("摘要含多余文件数", s.contains("1 个多余文件"));
        check("摘要含空间估算", s.contains("约"));
        check("空输入摘要", "没有发现相似文件".equals(Duplicates.summary(new ArrayList<Duplicates.Group>())));
    }

    private static void ordering() {
        section("结果排序");
        List<Duplicates.Group> g = run(
                // 三份的组 + 两份的组，三份的组应排前面
                file("Music/借口.mp3", 3_000_000),
                file("Music/b/借口.mp3", 3_000_000),
                file("Music/c/借口.mp3", 3_000_000),
                file("Music/暗号.mp3", 3_000_000),
                file("Music/b/暗号.mp3", 3_000_000));
        check("共两组", g.size() == 2);
        check("组大的排前面", g.get(0).files.size() == 3);
        check("第二组两个", g.get(1).files.size() == 2);
    }

    private static void robustness() {
        section("容错");
        check("空列表不崩", run().isEmpty());
        check("单个文件不成组", run(file("Music/独唱.mp3", 1000)).isEmpty());
        check("取消令牌不崩", Duplicates.find(java.util.Arrays.asList(
                        file("Music/一.mp3", 1), file("Music/二.mp3", 1)),
                "root", NO_PROGRESS, NO_CANCEL).size() == 0);
    }

    // ------------------------------------------------------------------

    private static List<Duplicates.Group> run(VFile... files) {
        List<VFile> list = new ArrayList<VFile>();
        for (VFile f : files) {
            list.add(f);
        }
        return Duplicates.find(list, "primary:Music", NO_PROGRESS, NO_CANCEL);
    }

    private static VFile file(String docId, long size) {
        int slash = docId.lastIndexOf('/');
        String name = slash >= 0 ? docId.substring(slash + 1) : docId;
        String parent = slash >= 0 ? "primary:" + docId.substring(0, slash) : "primary:";
        return new VFile("primary:" + docId, parent, name, "audio/mpeg", size, 1_700_000_000_000L, false);
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
