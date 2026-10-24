import com.dsh.musicorganizer.core.LyricsDoc;
import com.dsh.musicorganizer.core.LyricsTimeline;

import java.util.ArrayList;
import java.util.List;

/**
 * 歌词时间轴判定回归（纯 JVM，v0.1.37 歌词查看器用）。
 *
 * <p>盯的是「高亮别跳错行」：二分查找的边界、逐字进度插值、唱完之后停在哪一行。
 */
public class LyricsTimelineTest {

    private static int pass = 0;
    private static int fail = 0;

    public static void main(String[] args) {
        List<LyricsDoc.Line> lines = new ArrayList<LyricsDoc.Line>();
        lines.add(new LyricsDoc.Line(1000, "第一行"));
        lines.add(new LyricsDoc.Line(5000, "第二行"));
        lines.add(new LyricsDoc.Line(9000, "第三行"));

        // 1) 行定位
        check("没开始返回 -1", LyricsTimeline.lineIndexAt(lines, 500) == -1);
        check("正好第一行", LyricsTimeline.lineIndexAt(lines, 1000) == 0);
        check("第一行中间", LyricsTimeline.lineIndexAt(lines, 3000) == 0);
        check("第二行起点", LyricsTimeline.lineIndexAt(lines, 5000) == 1);
        check("最后一行", LyricsTimeline.lineIndexAt(lines, 20000) == 2);
        check("空表 -1", LyricsTimeline.lineIndexAt(new ArrayList<LyricsDoc.Line>(), 0) == -1);
        check("null -1", LyricsTimeline.lineIndexAt(null, 0) == -1);

        // 2) 无逐字时的线性进度
        double p = LyricsTimeline.progressAt(lines.get(0), 3000, 5000);
        check("线性进度 50%", Math.abs(p - 0.5) < 0.001);
        check("早于该行 0%", LyricsTimeline.progressAt(lines.get(0), 0, 5000) == 0);
        check("晚于该行 100%", LyricsTimeline.progressAt(lines.get(0), 9000, 5000) == 1);
        check("下一行无时间不炸", LyricsTimeline.progressAt(lines.get(0), 1000, 1000) == 0);

        // 3) 有逐字时的插值
        LyricsDoc.Line wordLine = new LyricsDoc.Line(0, "晴天");
        wordLine.words.add(new LyricsDoc.Word(0, "晴"));
        wordLine.words.add(new LyricsDoc.Word(500, "天"));
        wordLine.words.add(new LyricsDoc.Word(1000, "！"));
        check("逐字词数 3", wordLine.words.size() == 3);
        check("读第一个字", LyricsTimeline.wordIndexAt(wordLine, 0) == 1);
        check("读第二个字", LyricsTimeline.wordIndexAt(wordLine, 500) == 2);
        check("读完三个字", LyricsTimeline.wordIndexAt(wordLine, 1500) == 3);
        check("早于首字返回 0", LyricsTimeline.wordIndexAt(
                new LyricsDoc.Line(0, "x"), 0) == -1);
        // 1000ms 时读完第二个字，正在读第三个字：进度 = (2 + 0)/3
        double wp = LyricsTimeline.progressAt(wordLine, 1000, 2000);
        check("逐字进度 66%", Math.abs(wp - 2.0 / 3) < 0.01);
        check("逐字开始 0", LyricsTimeline.progressAt(wordLine, -100, 2000) == 0);

        // 4) 末行时间与逐字行数
        check("末行时间 9000", LyricsTimeline.lastTime(lines) == 9000);
        check("空表末行 -1", LyricsTimeline.lastTime(null) == -1);
        List<LyricsDoc.Line> mixed = new ArrayList<LyricsDoc.Line>();
        mixed.add(wordLine);
        mixed.add(new LyricsDoc.Line(2000, "普通行"));
        check("逐字行数 1", LyricsTimeline.enhancedLineCount(mixed) == 1);
        check("全普通 0", LyricsTimeline.enhancedLineCount(lines) == 0);

        // 5) 排序副本（乱序输入按时间归位）
        List<LyricsDoc.Line> messy = new ArrayList<LyricsDoc.Line>();
        messy.add(new LyricsDoc.Line(9000, "c"));
        messy.add(new LyricsDoc.Line(1000, "a"));
        messy.add(new LyricsDoc.Line(5000, "b"));
        List<LyricsDoc.Line> sorted = LyricsTimeline.sortedCopy(messy);
        check("排序第一行", sorted.get(0).timeMs == 1000);
        check("排序末行", sorted.get(2).timeMs == 9000);
        check("不改原表", messy.get(0).timeMs == 9000);
        check("null 排序安全", LyricsTimeline.sortedCopy(null).isEmpty());

        // 6) 时间显示与状态文案
        check("时间格式 00:05", LyricsTimeline.stamp(5000).equals("00:05"));
        check("时间格式 01:05", LyricsTimeline.stamp(65000).equals("01:05"));
        check("负时间归零", LyricsTimeline.stamp(-100).equals("00:00"));
        check("状态带行号", LyricsTimeline.statusText(lines, 5000).contains("第 2/3 行"));
        check("未开始文案", LyricsTimeline.statusText(lines, 0).contains("还没开始"));

        // 7) 真实 LRC 走一遍解析
        List<LyricsDoc.Line> parsed = LyricsTimeline.sortedCopy(LyricsDoc.parse(
                "[00:01.00]<00:01.00>晴<00:01.50>天\n[00:05.00]第二句"));
        check("解析两行", parsed.size() == 2);
        check("解析出行首时间", parsed.get(0).timeMs == 1000);
        check("解析出逐字", parsed.get(0).words.size() == 2);
        check("逐字行计数", LyricsTimeline.enhancedLineCount(parsed) == 1);
        check("定位到第二句", LyricsTimeline.lineIndexAt(parsed, 6000) == 1);

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
