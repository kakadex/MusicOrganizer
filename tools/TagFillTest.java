import com.dsh.musicorganizer.core.TagFill;
import com.dsh.musicorganizer.core.Tags;

import java.util.HashMap;
import java.util.Map;

/**
 * 离线回归测试（纯 JVM）：批量标签的「只补空缺 / 覆盖已有」判定。
 * 不依赖 Android，可用 tools/run_core_test.sh 直接跑。
 */
public class TagFillTest {

    static int fails = 0;

    static void eq(String name, String expect, String actual) {
        boolean ok = expect.equals(actual);
        if (!ok) {
            fails++;
        }
        System.out.println((ok ? "  ok   " : "  FAIL ") + name
                + (ok ? "" : "  期望=[" + expect + "] 实际=[" + actual + "]"));
    }

    static void ok(String name, boolean cond) {
        if (!cond) {
            fails++;
        }
        System.out.println((cond ? "  ok   " : "  FAIL ") + name);
    }

    static Map<String, String> candidate() {
        Map<String, String> c = new HashMap<String, String>();
        c.put("title", "晴天");
        c.put("artist", "周杰伦");
        c.put("album", "叶惠美");
        c.put("year", "2003");
        c.put("track", "");
        c.put("genre", "");
        return c;
    }

    /** 固定顺序输出，便于断言。 */
    static String render(Map<String, String> m) {
        return new java.util.TreeMap<String, String>(m).toString();
    }

    public static void main(String[] a) {
        System.out.println("[1] 只补空缺：已有值一律不动");
        Tags before = new Tags();
        before.put("title", "晴天（旧）");
        before.put("artist", "周杰伦");
        Map<String, String> d1 = TagFill.diff(before, candidate(), false);
        eq("只写 album / year", "{album=叶惠美, year=2003}", render(d1));

        System.out.println("[2] 覆盖已有：不同才写，相同跳过");
        Map<String, String> d2 = TagFill.diff(before, candidate(), true);
        eq("写 title / album / year，artist 相同跳过",
                "{album=叶惠美, title=晴天, year=2003}", render(d2));

        System.out.println("[3] 候选里的空值永远不写（不会把已有标签清空）");
        Tags full = new Tags();
        for (String k : Tags.KEYS) {
            full.put(k, "原值-" + k);
        }
        Map<String, String> cand = new HashMap<String, String>();
        cand.put("title", "");
        cand.put("artist", "");
        ok("空候选 → 无改动", TagFill.diff(full, cand, true).isEmpty());

        System.out.println("[4] 标签已完整：默认视为饱和，跳过联网");
        ok("六个字段齐全 → 饱和", TagFill.isSaturated(full, false));
        ok("覆盖模式下不饱和（仍需查）", !TagFill.isSaturated(full, true));
        Tags partial = new Tags();
        partial.put("title", "x");
        ok("缺字段 → 不饱和", !TagFill.isSaturated(partial, false));

        System.out.println("[5] 摘要文案");
        eq("字段名拼接", "专辑、年份", TagFill.describe(d1));
        eq("空改动摘要为空", "", TagFill.describe(new HashMap<String, String>()));

        System.out.println("[6] 字段级三态策略（不写 / 只补空 / 覆盖）");
        Tags before2 = new Tags();
        before2.put("title", "晴天（旧）");
        before2.put("artist", "周杰伦");
        Map<String, Integer> modes = new HashMap<String, Integer>();
        modes.put("title", TagFill.DISABLED);
        modes.put("artist", TagFill.OVERWRITE);
        Map<String, String> d3 = TagFill.diff(before2, candidate(), modes);
        eq("title 不写、artist 覆盖但值相同跳过、album/year 补空",
                "{album=叶惠美, year=2003}", render(d3));

        Map<String, String> cand2 = candidate();
        cand2.put("artist", "周杰伦(新)");
        Map<String, String> d4 = TagFill.diff(before2, cand2, modes);
        eq("artist 覆盖写、title 不写、album/year 补空",
                "{album=叶惠美, artist=周杰伦(新), year=2003}", render(d4));

        Tags full2 = new Tags();
        for (String k : Tags.KEYS) {
            full2.put(k, "原值-" + k);
        }
        ok("全只补空 + 字段齐全 → 饱和", TagFill.isSaturated(full2, TagFill.defaultModes(false)));
        Map<String, Integer> hasOverwrite = TagFill.defaultModes(false);
        hasOverwrite.put("genre", TagFill.OVERWRITE);
        ok("含覆盖字段 → 不饱和", !TagFill.isSaturated(full2, hasOverwrite));
        Map<String, Integer> disableAndSupp = TagFill.defaultModes(false);
        disableAndSupp.put("genre", TagFill.DISABLED);
        ok("DISABLED 字段不参与饱和判断", TagFill.isSaturated(full2, disableAndSupp));

        System.out.println(fails == 0 ? "\n全部通过 ✅" : "\n失败 " + fails + " 项 ❌");
        if (fails != 0) {
            System.exit(1);
        }
    }
}
