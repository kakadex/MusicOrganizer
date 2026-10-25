import com.dsh.musicorganizer.core.TagFix;
import com.dsh.musicorganizer.core.Tags;

import java.util.Map;

/**
 * 标签本地批量修正回归（纯 JVM，v0.1.80）。
 *
 * <p>重点盯两件事：① 只改该改的（汉字不能被「全角转半角」误伤）；
 * ② 没变化时 {@code plan()} 必须返回空表 —— 空表是不写盘的唯一依据。
 */
public class TagFixTest {

    private static int pass = 0;
    private static int fail = 0;

    public static void main(String[] args) {
        // ---- 去首尾空白
        check("去首尾空格", "标题".equals(TagFix.clean("  标题  ", TagFix.TRIM)));
        check("去制表符", "a".equals(TagFix.clean("\ta\t", TagFix.TRIM)));
        check("ops=0 原样", "  a  ".equals(TagFix.clean("  a  ", 0)));
        check("null 给空串", "".equals(TagFix.clean(null, TagFix.TRIM)));

        // ---- 折叠空格
        check("折叠多个空格", "A B".equals(TagFix.clean("A    B", TagFix.SPACES)));
        check("折叠制表符", "A B".equals(TagFix.clean("A\t\tB", TagFix.SPACES)));
        check("不动中文内部", "周杰伦".equals(TagFix.clean("周杰伦", TagFix.SPACES)));

        // ---- 全角转半角（只动 ASCII 区，汉字保留）
        check("全角字母", "ABC".equals(TagFix.fullToHalf("ＡＢＣ")));
        check("全角数字", "123".equals(TagFix.fullToHalf("１２３")));
        check("全角标点", "(a)".equals(TagFix.fullToHalf("（a）")));
        check("全角空格", "A B".equals(TagFix.fullToHalf("A　B")));
        check("汉字不动", "测试 乐队".equals(TagFix.fullToHalf("测试　乐队")));

        // ---- 音轨号补零
        check("1 → 01", "01".equals(TagFix.track("1")));
        check("9 → 09", "09".equals(TagFix.track("9")));
        check("10 不变", "10".equals(TagFix.track("10")));
        check("1/12 → 01/12", "01/12".equals(TagFix.track("1/12")));
        check("12/12 不变", "12/12".equals(TagFix.track("12/12")));
        check("非数字不碰", "A1".equals(TagFix.track("A1")));
        check("空串给空串", "".equals(TagFix.track("")));

        // ---- plan：只列真正变化的字段
        Tags t = new Tags();
        t.put("title", "测试  标题");   // Tags.put 自己会 trim，这里测的是内部多余空格
        t.put("artist", "示例歌手");
        t.put("track", "3");
        Map<String, String> plan = TagFix.plan(t, TagFix.TRIM | TagFix.SPACES | TagFix.TRACK);
        check("标题折叠空格", "测试 标题".equals(plan.get("title")));
        check("艺人没变化就不列", !plan.containsKey("artist"));
        check("音轨要补零", "03".equals(plan.get("track")));
        check("空字段不列", !plan.containsKey("album"));

        Tags clean = new Tags();
        clean.put("title", "干净的标题");
        clean.put("artist", "示例歌手");
        check("全干净 → 空表", TagFix.plan(clean, TagFix.TRIM | TagFix.SPACES).isEmpty());
        check("空标签 → 空表", TagFix.plan(new Tags(), TagFix.TRIM).isEmpty());
        check("null 标签 → 空表", TagFix.plan(null, TagFix.TRIM).isEmpty());

        System.out.println("结果：通过 " + pass + "，失败 " + fail);
        if (fail > 0) {
            System.exit(1);
        }
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
