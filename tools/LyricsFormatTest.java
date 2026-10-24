import com.dsh.musicorganizer.core.LyricsDoc;
import com.dsh.musicorganizer.core.Ttml;

import java.util.List;

/**
 * 歌词格式回归：增强型 LRC（逐字）与 TTML。
 *
 * <p>做「歌词格式处理」时最容易错的两处：
 * <ul>
 *   <li>逐字标记 {@code <00:12.00>} 没剥离 → 播放器把标记直接显示出来；</li>
 *   <li>TTML 没转换就落盘 → 大多数播放器只显示一串 XML。</li>
 * </ul>
 */
public class LyricsFormatTest {

    private static int pass = 0;
    private static int fail = 0;

    public static void main(String[] args) {
        // 1) 普通 LRC：文本原样、没有逐字表
        List<LyricsDoc.Line> plain = LyricsDoc.parse("[00:12.00]第一行\n[00:15.500]第二行\n");
        check("普通 LRC 行数", plain.size() == 2);
        check("普通 LRC 首行时间", plain.get(0).timeMs == 12000);
        check("普通 LRC 首行文本", "第一行".equals(plain.get(0).text));
        check("普通 LRC 无逐字", plain.get(0).words.isEmpty());
        check("普通 LRC 不是增强型", !LyricsDoc.isEnhanced("[00:12.00]第一行"));

        // 2) 增强型 LRC：文本剥离标记，逐字时间保留
        String enhanced = "[00:12.00]我<00:12.00>是<00:12.40>谁\n";
        List<LyricsDoc.Line> en = LyricsDoc.parse(enhanced);
        check("增强 LRC 行数", en.size() == 1);
        check("增强 LRC 文本已剥离标记", "我是谁".equals(en.get(0).text));
        check("增强 LRC 逐字数量", en.get(0).words.size() == 3);
        check("增强 LRC 首字时间", en.get(0).words.get(0).timeMs == 12000);
        check("增强 LRC 第三字时间", en.get(0).words.get(2).timeMs == 12400);
        check("增强 LRC 识别为增强型", LyricsDoc.isEnhanced(enhanced));
        check("增强 LRC 逐字总数", LyricsDoc.wordCount(enhanced) == 3);

        // 3) 清洗必须丢掉逐字标记（旧播放器不认）
        String cleaned = LyricsDoc.clean(enhanced);
        check("清洗后无逐字标记", !cleaned.contains("<00:12"));
        check("清洗后仍有文本", cleaned.contains("我是谁"));
        check("清洗后仍带时间轴", cleaned.startsWith("[00:12.00]"));

        // 4) 一行多时间戳
        List<LyricsDoc.Line> multi = LyricsDoc.parse("[00:10.00][00:20.00]副歌\n");
        check("多时间戳展开成两行", multi.size() == 2);
        check("多时间戳第二行时间", multi.get(1).timeMs == 20000);

        // 5) TTML → LRC
        String ttml = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
                + "<tt xmlns=\"http://www.w3.org/ns/ttml\"><body><div>\n"
                + "<p begin=\"00:00:12.345\" end=\"00:00:15.200\">第一句</p>\n"
                + "<p begin=\"00:00:15.500\" end=\"00:00:18.000\">第二句</p>\n"
                + "</div></body></tt>";
        check("识别为 TTML", Ttml.looksLike(ttml));
        String lrc = Ttml.toLrc(ttml);
        check("TTML 转 LRC 行数", LyricsDoc.timedLineCount(lrc) == 2);
        check("TTML 转 LRC 首行时间", lrc.contains("[00:12.34]"));
        check("TTML 转 LRC 首行文本", lrc.contains("第一句"));
        check("TTML 转 LRC 不含 XML 标签", !lrc.contains("<tt"));

        // 6) TTML 逐字 <span>
        String ttmlSpan = "<tt><body><div>"
                + "<p begin=\"0:12.0\" end=\"0:15.0\">"
                + "<span begin=\"0:12.0\">我</span><span begin=\"0:12.4\">是</span>"
                + "<span begin=\"0:12.8\">谁</span></p></div></body></tt>";
        List<LyricsDoc.Line> spanLines = Ttml.parse(ttmlSpan);
        check("TTML span 解析出 1 行", spanLines.size() == 1);
        check("TTML span 文本", "我是谁".equals(spanLines.get(0).text));
        check("TTML span 逐字数量", spanLines.get(0).words.size() == 3);
        String enhancedOut = Ttml.toEnhancedLrc(ttmlSpan);
        check("TTML 可转增强型 LRC", enhancedOut.contains("<00:12.00>"));
        check("TTML 增强型可被反解析", LyricsDoc.isEnhanced(enhancedOut));

        // 7) TTML 译文轨（同 begin 两段）
        String ttmlBi = "<tt><body><div>"
                + "<p begin=\"00:05.000\">Hello</p>"
                + "<p begin=\"00:05.000\">你好</p>"
                + "</div></body></tt>";
        String bi = Ttml.toLrc(ttmlBi);
        check("同时间点双语各占一行", LyricsDoc.timedLineCount(bi) == 2);

        // 8) 时间格式
        check("hh:mm:ss.mmm", Ttml.parseTime("00:00:12.345", -1) == 12345);
        check("mm:ss.mmm", Ttml.parseTime("12.345", -1) == 12345);
        check("带 s 后缀", Ttml.parseTime("12.345s", -1) == 12345);
        check("毫秒写法", Ttml.parseTime("500ms", -1) == 500);
        check("长片", Ttml.parseTime("1:02:03.5", -1) == 3723500);
        check("无法解析用兜底", Ttml.parseTime("abc", -7) == -7);

        // 9) 格式归一：TTML 进 LRC 出，LRC 原样
        check("归一 TTML", LyricsDoc.normalizeFormat(ttml).contains("[00:12.34]"));
        check("归一不碰普通 LRC",
                LyricsDoc.normalizeFormat("[00:01.00]a").equals("[00:01.00]a"));
        check("归一空串", LyricsDoc.normalizeFormat(null).isEmpty());

        // 10) 坏 XML 不能抛异常
        check("坏 XML 返回空 LRC", Ttml.toLrc("<tt><body><div>").trim().isEmpty());

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
