import com.dsh.musicorganizer.core.LyricsTool;

/**
 * 歌词文本工具回归（纯 JVM，v0.1.80）。
 *
 * <p>这几条都是「界面上点一下就会改文件」的动作，出错代价高：
 * 时间轴被改乱、元信息被当歌词写进去、多时间戳行被拆成重复行。
 */
public class LyricsToolTest {

    private static int pass = 0;
    private static int fail = 0;

    public static void main(String[] args) {
        // ---- 归一：BOM / CRLF / 行尾空白
        check("去 BOM", LyricsTool.normalize("\uFEFF[ti:x]").equals("[ti:x]"));
        check("CRLF 转 LF", LyricsTool.normalize("a\r\nb\r\nc").equals("a\nb\nc"));
        check("去行尾空格", LyricsTool.normalize("a   \nb\t").equals("a\nb"));
        check("null 空串", LyricsTool.normalize(null).isEmpty());

        // ---- 删空行
        String withBlank = "[00:01.00]第一行\n\n   \n[00:02.00]第二行\n";
        check("删空行", LyricsTool.stripEmptyLines(withBlank)
                .equals("[00:01.00]第一行\n[00:02.00]第二行"));
        check("删空行后行数", LyricsTool.lineCount(LyricsTool.stripEmptyLines(withBlank)) == 2);

        // ---- 去头部标签（整行都是元信息的才删，正文不动）
        String head = "[ti:测试标题]\n[ar:示例歌手]\n[offset:0]\n[00:01.00]正文";
        check("去头部标签", LyricsTool.stripHeaders(head).equals("[00:01.00]正文"));
        check("正文里的方括号不误删",
                LyricsTool.stripHeaders("[00:01.00][合唱] 你好").equals("[00:01.00][合唱] 你好"));

        // ---- 去时间轴（多个时间戳只留一次文本）
        check("去时间轴", LyricsTool.stripTimestamps("[00:01.00]你好").equals("你好"));
        check("多时间戳行只留一次",
                LyricsTool.stripTimestamps("[00:01.00][00:30.00]副歌").equals("副歌"));
        check("去时间轴后空行也清了",
                LyricsTool.stripTimestamps("[00:01.00]\n[00:02.00]词").equals("词"));

        // ---- 时间轴规范化
        check("1:2.3 → 01:02.30",
                LyricsTool.normalizeTimestamps("[1:2.3]词").equals("[01:02.30]词"));
        check("无小数补 .00",
                LyricsTool.normalizeTimestamps("[00:05]词").equals("[00:05.00]词"));
        check("三位小数截到百分秒",
                LyricsTool.normalizeTimestamps("[00:05.999]词").equals("[00:05.99]词"));
        check("超过一小时带小时位",
                LyricsTool.normalizeTimestamps("[1:02:03.45]词").equals("[1:02:03.45]词"));
        check("多个时间戳都规范",
                LyricsTool.normalizeTimestamps("[0:1.5][0:2.5]词")
                        .equals("[00:01.50][00:02.50]词"));
        check("没有时间轴的行原样保留",
                LyricsTool.normalizeTimestamps("纯文本").equals("纯文本"));

        // ---- 去重行
        check("去重复行", LyricsTool.dedupeLines("[00:01.00]词\n[00:01.00]词\n[00:02.00]词")
                .equals("[00:01.00]词\n[00:02.00]词"));

        // ---- 时间戳解析
        check("解析为毫秒", LyricsTool.timestamps("[00:01.50]x").get(0).longValue() == 1500L);
        check("没有时间戳给空", LyricsTool.timestamps("x").isEmpty());

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
