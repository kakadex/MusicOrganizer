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
        artistPrefix();
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

    /**
     * 艺人前缀 / 包含度兜底（v0.1.84）：
     * 「示例歌手-示例歌名」与「示例歌名」这种同曲不同命名，纯编辑距离只有 0.6 查不出；
     * 换成综合相似度后靠「包含度」命中，但必须用时长把「示例歌名加长版」这类挡在外面。
     */
    private static void artistPrefix() {
        section("艺人前缀（包含度）");
        java.util.Map<String, Double> dur = new java.util.HashMap<String, Double>();
        dur.put("示例歌名.mp3", 245.0);
        dur.put("示例歌手-示例歌名.mp3", 246.0);
        List<Duplicates.Group> g = runDur(dur,
                file("Music/示例歌手-示例歌名.mp3", 6_800_000),
                file("Music/示例歌名.mp3", 6_100_000));
        check("带艺人前缀的同曲能成组", g.size() == 1);
        check("标题一致按确证算（score=1.0）", !g.isEmpty()
                && Math.abs(g.get(0).score - 1.0) < 1e-9);
        check("确证组不标疑似", !g.isEmpty() && !g.get(0).suspect);

        section("同名但艺人明确不同（翻唱/重名）");
        java.util.Map<String, Double> durX = new java.util.HashMap<String, Double>();
        durX.put("示例歌手甲-示例歌名.mp3", 240.0);
        durX.put("示例歌手乙-示例歌名.mp3", 240.0);
        check("不自动并组", runDur(durX,
                file("Music/示例歌手甲-示例歌名.mp3", 3_000_000),
                file("Music/示例歌手乙-示例歌名.mp3", 3_000_000)).isEmpty());

        section("文件名没写艺人时读标签（翻唱不能算重复）");
        java.util.Map<String, String> tagA = new java.util.HashMap<String, String>();
        tagA.put("示例歌名(1).mp3", "示例歌手甲");
        java.util.Map<String, Double> durSame = new java.util.HashMap<String, Double>();
        durSame.put("示例歌名(1).mp3", 240.0);
        durSame.put("示例歌手乙-示例歌名.mp3", 241.0);
        check("标签艺人不同则不并组（即便时长接近）",
                runMeta(durSame, tagA,
                        file("Music/示例歌名(1).mp3", 5_700_000),
                        file("Music/示例歌手乙-示例歌名.mp3", 6_700_000)).isEmpty());

        java.util.Map<String, String> tagB = new java.util.HashMap<String, String>();
        tagB.put("示例歌名(1).mp3", "示例歌手乙");
        check("标签艺人一致则并组", runMeta(durSame, tagB,
                file("Music/示例歌名(1).mp3", 5_700_000),
                file("Music/示例歌手乙-示例歌名.mp3", 6_700_000)).size() == 1);

        java.util.Map<String, String> tagPlaceholder = new java.util.HashMap<String, String>();
        tagPlaceholder.put("示例歌名(1).mp3", "群星");
        java.util.Map<String, Double> durFar = new java.util.HashMap<String, Double>();
        durFar.put("示例歌名(1).mp3", 180.0);
        durFar.put("示例歌手乙-示例歌名.mp3", 240.0);
        check("「群星」当未知处理，靠时长判定（差 60s 不并组）",
                runMeta(durFar, tagPlaceholder,
                        file("Music/示例歌名(1).mp3", 5_700_000),
                        file("Music/示例歌手乙-示例歌名.mp3", 6_700_000)).isEmpty());

        section("前缀延长但时长不符（必须挡住）");
        java.util.Map<String, Double> dur2 = new java.util.HashMap<String, Double>();
        dur2.put("示例歌名.mp3", 245.0);
        dur2.put("示例歌名加长版.mp3", 180.0);
        check("时长差 60s 不并组", runDur(dur2,
                file("Music/示例歌名.mp3", 3_000_000),
                file("Music/示例歌名加长版.mp3", 3_000_000)).isEmpty());

        java.util.Map<String, Double> dur3 = new java.util.HashMap<String, Double>();
        dur3.put("示例歌名.mp3", 245.0);
        dur3.put("示例歌名加长版.mp3", 246.5);
        check("时长一致则并组（疑似）", runDur(dur3,
                file("Music/示例歌名.mp3", 3_000_000),
                file("Music/示例歌名加长版.mp3", 3_100_000)).size() == 1);

        section("读不到时长");
        List<Duplicates.Group> unknown = runDur(new java.util.HashMap<String, Double>(),
                file("Music/示例歌名.mp3", 3_000_000),
                file("Music/示例歌名加长版.mp3", 3_000_000));
        check("时长未知仍并组", unknown.size() == 1);
        check("但标疑似（默认不勾选）", unknown.size() == 1 && unknown.get(0).suspect);

        section("复制尾巴其实是剪辑版（不能默认勾选）");
        java.util.Map<String, Double> cut = new java.util.HashMap<String, Double>();
        cut.put("示例歌名 (1).mp3", 275.0);
        cut.put("示例歌名.mp3", 155.0);          // 前后各切 60s
        List<Duplicates.Group> cutGroup = runDur(cut,
                file("Music/示例歌名 (1).mp3", 4_000_000),
                file("Music/示例歌名.mp3", 6_800_000));
        check("仍列出（让人能看见）", cutGroup.size() == 1);
        check("但标疑似、默认不勾", cutGroup.size() == 1 && cutGroup.get(0).suspect);

        section("同名同大小视为副本（不做时长 IO）");
        List<Duplicates.Group> same = runDur(new java.util.HashMap<String, Double>(),
                file("Music/a/示例歌名.mp3", 6_800_000),
                file("Music/b/示例歌名.mp3", 6_800_000));
        check("无时长来源也能确证", same.size() == 1);
        check("且不标疑似", same.size() == 1 && !same.get(0).suspect);

        section("结果里带时长对比");
        java.util.Map<String, Double> durD = new java.util.HashMap<String, Double>();
        durD.put("示例歌名.mp3", 275.0);
        durD.put("示例歌名 (1).mp3", 155.0);
        List<Duplicates.Group> dg = runDur(durD,
                file("Music/示例歌名.mp3", 6_800_000),
                file("Music/示例歌名 (1).mp3", 4_000_000));
        check("每个文件都填了时长", dg.size() == 1
                && dg.get(0).files.get(0).duration != null
                && dg.get(0).files.get(1).duration != null);
        String durLine = Duplicates.durationSummary(dg.get(0));
        check("概览含两个时长", durLine.contains("4:35") && durLine.contains("2:35"));
        check("概览含相差", durLine.contains("相差") && durLine.contains("2:00"));

        section("疑似组的内容核验（采样指纹）");
        java.util.Map<String, Double> durEq = new java.util.HashMap<String, Double>();
        durEq.put("示例歌名.mp3", 245.0);
        durEq.put("示例歌名加长版.mp3", 245.5);
        java.util.Map<String, String> sameHash = new java.util.HashMap<String, String>();
        sameHash.put("示例歌名.mp3", "aaaaaa");
        sameHash.put("示例歌名加长版.mp3", "aaaaaa");
        List<Duplicates.Group> verified = runAll(durEq, new java.util.HashMap<String, String>(),
                sameHash,
                file("Music/示例歌名.mp3", 3_000_000),
                file("Music/示例歌名加长版.mp3", 3_000_000));
        check("采样一致 → 升为确证", verified.size() == 1 && !verified.get(0).suspect);
        check("记录内容状态为「一致」",
                verified.size() == 1 && verified.get(0).content == Duplicates.CONTENT_SAME);

        java.util.Map<String, String> diffHash = new java.util.HashMap<String, String>();
        diffHash.put("示例歌名.mp3", "aaaaaa");
        diffHash.put("示例歌名加长版.mp3", "bbbbbb");
        List<Duplicates.Group> differed = runAll(durEq, new java.util.HashMap<String, String>(),
                diffHash,
                file("Music/示例歌名.mp3", 3_000_000),
                file("Music/示例歌名加长版.mp3", 3_000_000));
        check("采样不同 → 仍是疑似", differed.size() == 1 && differed.get(0).suspect);
        check("记录内容状态为「不同」",
                differed.size() == 1 && differed.get(0).content == Duplicates.CONTENT_DIFF);
        check("摘要点出内容不同", Duplicates.summary(differed).contains("内容不同"));
        check("内容状态文案", Duplicates.contentLabel(differed.get(0)).contains("名字像"));

        section("确证档不标疑似");
        java.util.Map<String, Double> dur4 = new java.util.HashMap<String, Double>();
        dur4.put("示例歌名 (1).mp3", 245.0);
        dur4.put("示例歌名.mp3", 245.0);
        List<Duplicates.Group> copy = runDur(dur4,
                file("Music/示例歌名 (1).mp3", 3_000_000),
                file("Music/示例歌名.mp3", 3_000_000));
        check("复制件归一后 score=1.0", copy.size() == 1
                && Math.abs(copy.get(0).score - 1.0) < 1e-9);
        check("确证档不标疑似", copy.size() == 1 && !copy.get(0).suspect);
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
        return runDur(new java.util.HashMap<String, Double>(), files);
    }

    /** 带时长来源的跑法：按文件名查时长，缺省视为「读不到」。 */
    private static List<Duplicates.Group> runDur(final java.util.Map<String, Double> durations,
                                                 VFile... files) {
        return runMeta(durations, new java.util.HashMap<String, String>(), files);
    }

    /** 时长 + 内嵌标签艺人都给的跑法。 */
    private static List<Duplicates.Group> runMeta(final java.util.Map<String, Double> durations,
                                                  final java.util.Map<String, String> tagArtists,
                                                  VFile... files) {
        return runAll(durations, tagArtists, new java.util.HashMap<String, String>(), files);
    }

    /** 时长 + 标签艺人 + 内容采样哈希全给。 */
    private static List<Duplicates.Group> runAll(final java.util.Map<String, Double> durations,
                                                 final java.util.Map<String, String> tagArtists,
                                                 final java.util.Map<String, String> contentHashes,
                                                 VFile... files) {
        List<VFile> list = new ArrayList<VFile>();
        for (VFile f : files) {
            list.add(f);
        }
        return Duplicates.find(list, "primary:Music", NO_PROGRESS, NO_CANCEL,
                new Duplicates.DurationSource() {
                    @Override
                    public double durationOf(VFile file) {
                        Double d = durations.get(file.name);
                        return d == null ? 0 : d.doubleValue();
                    }

                    @Override
                    public String tagArtist(VFile file) {
                        return tagArtists.get(file.name);
                    }

                    @Override
                    public String contentHash(VFile file) {
                        return contentHashes.get(file.name);
                    }
                });
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
