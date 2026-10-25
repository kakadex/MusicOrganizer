import com.dsh.musicorganizer.core.MatchDedupe;

import java.util.ArrayList;
import java.util.List;

/**
 * 多源候选合并回归（纯 JVM，v0.1.80）。
 *
 * <p>核心诉求：同一首歌在多家源出现时合并成一条（并记住「几家命中」），
 * 但**不同的版本**（现场版、不同时长）不能误并 —— 并错了会直接写错标签。
 */
public class MatchDedupeTest {

    private static int pass = 0;
    private static int fail = 0;

    public static void main(String[] args) {
        // 1) 三条同曲合并成一条，分数取最高，来源串起来
        List<MatchDedupe.Entry> in = new ArrayList<MatchDedupe.Entry>();
        in.add(e("测试标题", "示例歌手", 258.6, 0.72, "网易云"));
        in.add(e("测试标题", "示例歌手", 259.0, 0.91, "QQ"));
        in.add(e("测试标题", "示例歌手", 258.0, 0.65, "酷狗"));
        List<MatchDedupe.Entry> out = MatchDedupe.merge(in);
        check("三条并成一条", out.size() == 1);
        check("命中源数 3", out.get(0).merged == 3);
        check("取最高分 0.91", Math.abs(out.get(0).score - 0.91) < 1e-9);
        check("来源串起来", out.get(0).sources.contains("网易云")
                && out.get(0).sources.contains("QQ") && out.get(0).sources.contains("酷狗"));

        // 2) 时长差超过容差 → 不许并（可能是现场版 / 不同录音）
        List<MatchDedupe.Entry> diff = new ArrayList<MatchDedupe.Entry>();
        diff.add(e("测试标题", "示例歌手", 258.0, 0.8, "网易云"));
        diff.add(e("测试标题", "示例歌手", 301.0, 0.7, "QQ"));
        check("时长差太大不合并", MatchDedupe.merge(diff).size() == 2);

        // 3) 一方没写艺人：标题一致就算同一首
        List<MatchDedupe.Entry> noArtist = new ArrayList<MatchDedupe.Entry>();
        noArtist.add(e("测试标题", "示例歌手", 200.0, 0.6, "网易云"));
        noArtist.add(e("测试标题", "", null, 0.7, "iTunes"));
        check("缺艺人仍合并", MatchDedupe.merge(noArtist).size() == 1);

        // 4) 标题差太多 → 分开
        List<MatchDedupe.Entry> diffTitle = new ArrayList<MatchDedupe.Entry>();
        diffTitle.add(e("测试标题", "示例歌手", 200.0, 0.8, "网易云"));
        diffTitle.add(e("完全不同的歌名", "示例歌手", 200.0, 0.7, "QQ"));
        check("歌名不同不合并", MatchDedupe.merge(diffTitle).size() == 2);

        // 5) 排序：分数高的在前；同分时命中源多的在前
        List<MatchDedupe.Entry> order = new ArrayList<MatchDedupe.Entry>();
        order.add(e("低分歌", "甲", 100.0, 0.40, "网易云"));
        order.add(e("高分歌", "乙", 100.0, 0.90, "QQ"));
        order.add(e("高分歌", "乙", 100.5, 0.90, "酷狗"));
        List<MatchDedupe.Entry> sorted = MatchDedupe.merge(order);
        check("高分在前", "高分歌".equals(sorted.get(0).title));
        check("合并后命中 2 源", sorted.get(0).merged == 2);

        // 6) 空输入 / null 元素
        check("空列表", MatchDedupe.merge(new ArrayList<MatchDedupe.Entry>()).isEmpty());
        List<MatchDedupe.Entry> withNull = new ArrayList<MatchDedupe.Entry>();
        withNull.add(null);
        withNull.add(e("歌", "手", null, 0.5, "QQ"));
        check("null 元素被跳过", MatchDedupe.merge(withNull).size() == 1);

        // 7) 标题里的标点/空格差异要认成同一首
        List<MatchDedupe.Entry> punct = new ArrayList<MatchDedupe.Entry>();
        punct.add(e("测试-标题", "示例歌手", 200.0, 0.7, "网易云"));
        punct.add(e("测试 标题", "示例歌手", 200.2, 0.8, "QQ"));
        check("标点空格差异可合并", MatchDedupe.merge(punct).size() == 1);

        System.out.println("结果：通过 " + pass + "，失败 " + fail);
        if (fail > 0) {
            System.exit(1);
        }
    }

    private static MatchDedupe.Entry e(String title, String artist, Double dur,
                                       double score, String source) {
        MatchDedupe.Entry x = new MatchDedupe.Entry();
        x.title = title;
        x.artist = artist;
        x.duration = dur;
        x.score = score;
        x.source = source;
        x.payload = title + "|" + source;
        return x;
    }

    private static void check(String name, boolean ok) {
        if (ok) {
            pass++;
            System.out.println("  ok   " + name);
        } else {
            fail++;
            System.out.println("  FAIL " + name);
        }
    }
}
