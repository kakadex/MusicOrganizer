import com.dsh.musicorganizer.core.LyricsDoc;

import java.util.List;

/**
 * 歌词文档模型回归测试（纯 JVM）。
 *
 * 覆盖：
 *   1. 解析（多时间戳展开、centisecond/millisecond 两种精度）
 *   2. 元信息行识别（「作词 : 小寒」是、「作词人的眼泪」不是）
 *   3. 清洗（去制作信息、统一时间戳格式、纯文本原样保留）
 *   4. 合并译文（**毫秒最近邻**、容差 150ms、相同文本不重复）
 *   5. 统计与格式化
 */
public final class LyricsDocTest {

    private static int passed = 0;
    private static int failed = 0;

    public static void main(String[] args) {
        parsing();
        metadata();
        cleaning();
        merging();
        formatting();

        System.out.println();
        System.out.println("结果：通过 " + passed + "，失败 " + failed);
        if (failed > 0) {
            System.exit(1);
        }
    }

    // ------------------------------------------------------------------

    private static void parsing() {
        section("解析");
        String lrc = "[00:01.50]第一行\n[00:03.20][00:09.20]重复行\n[00:05.123]高精度\n";
        List<LyricsDoc.Line> lines = LyricsDoc.parse(lrc);
        check("多时间戳展开成 4 行", lines.size() == 4);
        check("首行 1500ms", lines.get(0).timeMs == 1500);
        check("次行 3200ms", lines.get(1).timeMs == 3200);
        check("第三行 9200ms（第二个时间戳）", lines.get(2).timeMs == 9200);
        check("毫秒精度 5123", lines.get(3).timeMs == 5123);
        check("文本解析正确", "重复行".equals(lines.get(1).text));
        check("空文本安全", LyricsDoc.parse(null).isEmpty() || true);
        check("null 返回空列表", LyricsDoc.parse(null).isEmpty());
        check("无时间轴返回空", LyricsDoc.parse("随便写点什么").isEmpty());
        check("行数统计", LyricsDoc.timedLineCount(lrc) == 4);
    }

    private static void metadata() {
        section("元信息行识别");
        check("作词：是", LyricsDoc.isMetadataLine("作词：小寒"));
        check("作曲 : 是", LyricsDoc.isMetadataLine("作曲 : 某某"));
        check("OP 是", LyricsDoc.isMetadataLine("OP：某某音乐"));
        check("编曲 是", LyricsDoc.isMetadataLine("编曲 陈伟"));
        check("producer 是", LyricsDoc.isMetadataLine("Producer: Someone"));
        check("歌名不算", !LyricsDoc.isMetadataLine("作词人的眼泪"));
        check("普通歌词不算", !LyricsDoc.isMetadataLine("那一年的夏天"));
        check("空行不算", !LyricsDoc.isMetadataLine("  "));
    }

    private static void cleaning() {
        section("清洗");
        String lrc = "作词 : 小寒\n作曲 : 某某\n[00:01.00]第一句\n[00:02.00]\n[00:03.00]第二句\n";
        String clean = LyricsDoc.clean(lrc);
        check("去掉作词行", !clean.contains("作词"));
        check("去掉作曲行", !clean.contains("作曲"));
        check("保留时间轴行", clean.contains("[00:01.00]第一句") && clean.contains("[00:03.00]第二句"));
        check("保留空占位行", clean.contains("[00:02.00]"));
        check("行数 3", LyricsDoc.timedLineCount(clean) == 3);

        String plain = "作词 : 小寒\n这是第一句\n这是第二句\n";
        String cleaned = LyricsDoc.clean(plain);
        check("纯文本去制作信息", !cleaned.contains("作词") && cleaned.contains("这是第一句"));
    }

    private static void merging() {
        section("合并译文（毫秒最近邻）");
        String orig = "[00:19.629]Hello\n[00:22.100]World\n";
        // 译文小数位与原文不同，字符串比对会全落空
        String trans = "[00:19.64]你好\n[00:22.12]世界\n";
        String merged = LyricsDoc.mergeTranslation(orig, trans);
        check("原文保留", merged.contains("Hello") && merged.contains("World"));
        check("译文插入", merged.contains("你好") && merged.contains("世界"));
        check("译文行数 2", LyricsDoc.translationLineCount(merged) == 2);
        check("同一时间点相邻",
                merged.indexOf("你好") > merged.indexOf("Hello")
                        && merged.indexOf("世界") > merged.indexOf("World"));

        String far = "[00:25.000]太晚了\n";
        check("超过容差不合并", LyricsDoc.translationLineCount(
                LyricsDoc.mergeTranslation(orig, far)) == 0);
        check("没有译文时返回清洗后的原文",
                LyricsDoc.mergeTranslation(orig, "").equals(LyricsDoc.clean(orig)));
        check("译文与原文相同不重复", LyricsDoc.translationLineCount(
                LyricsDoc.mergeTranslation("[00:01.00]纯音乐\n", "[00:01.00]纯音乐\n")) == 0);
        check("译文里的制作信息被忽略", LyricsDoc.translationLineCount(
                LyricsDoc.mergeTranslation(orig, "[00:19.63]作词：某人\n")) == 0);
        check("译文时间几乎相等也合并（±150ms）", LyricsDoc.translationLineCount(
                LyricsDoc.mergeTranslation("[00:10.00]A\n", "[00:10.14]B\n")) == 1);
    }

    private static void formatting() {
        section("格式化与摘要");
        check("[00:00.00]", "[00:00.00]".equals(LyricsDoc.format(0)));
        check("[01:05.50]", "[01:05.50]".equals(LyricsDoc.format(65500)));
        check("[02:00.00]", "[02:00.00]".equals(LyricsDoc.format(120000)));
        String merged = LyricsDoc.mergeTranslation("[00:01.00]A\n[00:02.00]B\n", "[00:01.00]甲\n");
        String sum = LyricsDoc.summary(merged);
        check("摘要含行数", sum.contains("3 行"));
        check("摘要含译文数", sum.contains("含译文 1 行"));
        check("纯文本摘要", LyricsDoc.summary("只有文字").contains("纯文本"));
        check("排序输出按时间", LyricsDoc.sorted("[00:05.00]B\n[00:01.00]A\n").get(0).text.equals("A"));
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
