import com.dsh.musicorganizer.core.LyricsShift;

/**
 * 歌词时间轴偏移回归（纯 JVM）。
 *
 * <p>盯的是「别把歌词改坏」：元信息不能动、负时间要钳零、小数位数要保留、
 * 逐字标记与多时间戳都要一起偏移。
 */
public class LyricsShiftTest {

    private static int pass = 0;
    private static int fail = 0;

    public static void main(String[] args) {
        String lrc = "[ar:周杰伦]\n[ti:晴天]\n[00:12.30]故事的小黄花\n[00:16.50]从出生那年就飘着";

        // 1) 正偏移：全体后推 500ms
        String plus = LyricsShift.shift(lrc, 500);
        check("元信息不动（ar）", plus.contains("[ar:周杰伦]"));
        check("元信息不动（ti）", plus.contains("[ti:晴天]"));
        check("第一行后推", plus.contains("[00:12.80]故事的小黄花"));
        check("第二行后推", plus.contains("[00:17.00]从出生那年就飘着"));

        // 2) 负偏移
        String minus = LyricsShift.shift(lrc, -500);
        check("负偏移第一行", minus.contains("[00:11.80]故事的小黄花"));

        // 3) 钳到 0
        String clamp = LyricsShift.shift("[00:00.20]开头", -1000);
        check("负时间钳零", clamp.contains("[00:00.00]开头"));

        // 4) 小数位数保留
        check("一位小数", LyricsShift.shift("[00:12.3]x", 0).contains("[00:12.3]"));
        check("两位小数不变", LyricsShift.shift("[00:12.30]x", 100).contains("[00:12.40]"));
        check("三位小数", LyricsShift.shift("[00:12.300]x", 100).contains("[00:12.400]"));
        check("无小数保持无小数", LyricsShift.shift("[00:12]x", 100).contains("[00:12]"));

        // 5) 跨分钟与跨小时
        check("跨分钟", LyricsShift.shift("[00:59.80]x", 500).contains("[01:00.30]"));
        check("跨十分钟", LyricsShift.shift("[09:59.90]x", 500).contains("[10:00.40]"));

        // 6) 逐字标记也偏移
        String word = "[00:12.30]<00:12.30>故<00:12.60>事<00:12.90>的";
        String wordPlus = LyricsShift.shift(word, 200);
        check("逐字标记偏移", wordPlus.contains("<00:12.50>故"));
        check("逐字标记都动", wordPlus.contains("<00:13.10>的"));
        check("行首时间也动", wordPlus.startsWith("[00:12.50]"));

        // 7) 一行多时间戳
        String multi = "[00:10.00][00:20.00]重复的一句";
        String multiPlus = LyricsShift.shift(multi, 1000);
        check("多时间戳都偏移", multiPlus.contains("[00:11.00][00:21.00]"));

        // 8) 统计与首尾时间
        check("时间戳计数", LyricsShift.count(lrc) == 2);
        check("首时间", LyricsShift.firstStamp(lrc) == 12300);
        check("末时间", LyricsShift.lastStamp(lrc) == 16500);
        check("无时间戳返回 -1", LyricsShift.firstStamp("纯文本") == -1);
        check("空串 -1", LyricsShift.lastStamp("") == -1);

        // 9) 归零判定
        check("会归零", LyricsShift.collapsesToZero("[00:00.50]x", -800));
        check("不会归零", !LyricsShift.collapsesToZero("[00:10.00]x", -800));

        // 10) 边界
        check("偏移 0 原样返回", LyricsShift.shift(lrc, 0).equals(lrc));
        check("null 安全", LyricsShift.shift(null, 100).isEmpty());
        check("纯文本不动", LyricsShift.shift("没有时间轴", 500).equals("没有时间轴"));
        check("行数与原文一致", LyricsShift.shift(lrc, 500).split("\n").length
                == lrc.split("\n").length);
        check("正文不改", LyricsShift.shift(lrc, 500).contains("故事的小黄花"));

        System.out.println("结果：通过 " + pass + "，失败 " + fail);
        if (fail > 0) {
            System.exit(1);
        }
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
