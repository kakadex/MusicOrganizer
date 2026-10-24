import com.dsh.musicorganizer.core.Zh;

/**
 * 繁 → 简 转换回归（纯 JVM）。
 *
 * <p>重点不是「转了几个字」，而是三条容易出错的边界：
 * ① 日文不能被误转；② 一对多的字（乾 / 著 / 藉）要按语境；③ 时间轴、标点、英文一律别动。
 */
public final class ZhTest {

    private static int passed = 0;
    private static int failed = 0;

    public static void main(String[] args) {
        basics();
        lyrics();
        timeline();
        ambiguous();
        japanese();
        untouched();
        misc();

        System.out.println();
        System.out.println("结果：通过 " + passed + "，失败 " + failed);
        if (failed > 0) {
            System.exit(1);
        }
    }

    private static void basics() {
        section("基本字");
        eq("愛 → 爱", "爱", Zh.toSimplified("愛"));
        eq("們 → 们", "们", Zh.toSimplified("們"));
        eq("說 → 说", "说", Zh.toSimplified("說"));
        eq("時 → 时", "时", Zh.toSimplified("時"));
        eq("間 → 间", "间", Zh.toSimplified("間"));
        eq("願 → 愿", "愿", Zh.toSimplified("願"));
        eq("妳 → 你（台湾用法）", "你好", Zh.toSimplified("妳好"));
        eq("牠 → 它", "它", Zh.toSimplified("牠"));
        eq("臺 → 台", "台北", Zh.toSimplified("臺北"));
        eq("裡 → 里", "心里", Zh.toSimplified("心裡"));
        eq("乾淨 → 干净", "干净", Zh.toSimplified("乾淨"));
        eq("幾個 → 几个", "几个", Zh.toSimplified("幾個"));
        eq("什麼 → 什么", "什么", Zh.toSimplified("什麼"));
        eq("為什麼 → 为什么", "为什么", Zh.toSimplified("為什麼"));
    }

    private static void lyrics() {
        section("整句歌词");
        eq("常见歌词", "我们说好的幸福呢",
                Zh.toSimplified("我們說好的幸福呢"));
        eq("多行", "我爱你\n你是否也爱我\n别让我一个人",
                Zh.toSimplified("我愛你\n你是否也愛我\n別讓我一個人"));
        eq("含译文轨", "我看着你\n我看着你（译）",
                Zh.toSimplified("我看著你\n我看著你（譯）"));
        eq("空字符串", "", Zh.toSimplified(""));
        eq("null 安全", "", Zh.toSimplified(null));
    }

    private static void timeline() {
        section("时间轴与格式");
        eq("时间轴不动", "[00:12.34]我们相爱", Zh.toSimplified("[00:12.34]我們相愛"));
        eq("多时间戳不动", "[00:01.00][01:20.50]爱", Zh.toSimplified("[00:01.00][01:20.50]愛"));
        eq("offset 标签不动", "[offset:500]\n爱", Zh.toSimplified("[offset:500]\n愛"));
        eq("全角标点保留", "「爱」，。！？", Zh.toSimplified("「愛」，。！？"));
    }

    private static void ambiguous() {
        section("一对多的字");
        eq("著名保持", "著名歌手", Zh.toSimplified("著名歌手"));
        eq("著作保持（權→权）", "著作权", Zh.toSimplified("著作權"));
        eq("看著 → 看着", "看着你", Zh.toSimplified("看著你"));
        eq("睡著 → 睡着", "睡着了", Zh.toSimplified("睡著了"));
        eq("笑著 → 笑着", "笑着说", Zh.toSimplified("笑著說"));
        eq("乾隆保持", "乾隆", Zh.toSimplified("乾隆"));
        eq("乾坤保持", "乾坤", Zh.toSimplified("乾坤"));
        eq("乾燥 → 干燥", "干燥", Zh.toSimplified("乾燥"));
        eq("藉口 → 借口", "借口", Zh.toSimplified("藉口"));
        eq("憑藉 → 凭借", "凭借", Zh.toSimplified("憑藉"));
        eq("藉此 → 借此", "借此", Zh.toSimplified("藉此"));
        eq("慰藉保持", "慰藉", Zh.toSimplified("慰藉"));
        eq("狼藉保持", "狼藉", Zh.toSimplified("狼藉"));
        eq("宮商角徵羽保留徵", "宫商角徵羽", Zh.toSimplified("宮商角徵羽"));
    }

    private static void japanese() {
        section("日文不转");
        String ja = "君の名前を呼ぶ 愛してる";
        eq("含假名整段跳过", ja, Zh.toSimplified(ja));
        String jaKanji = "日本語の歌詞、東京の夜";
        eq("日文汉字句（有假名）不动", jaKanji, Zh.toSimplified(jaKanji));
        check("isJapanese 判定平假名", Zh.isJapanese("あいう"));
        check("isJapanese 判定片假名", Zh.isJapanese("アイウ"));
        check("isJapanese 判中文为否", !Zh.isJapanese("我們相愛"));
    }

    private static void untouched() {
        section("不该动的");
        eq("简体原样", "我们相爱", Zh.toSimplified("我们相爱"));
        eq("纯英文", "Love Me Tender 2026", Zh.toSimplified("Love Me Tender 2026"));
        eq("数字与符号", "100% - 3.14 (x)", Zh.toSimplified("100% - 3.14 (x)"));
        eq("emoji 保留", "爱你 ❤🎵", Zh.toSimplified("愛你 ❤🎵"));
        eq("中英混排", "I love 你 我爱你", Zh.toSimplified("I love 你 我愛你"));
        eq("空行保留", "\n\n", Zh.toSimplified("\n\n"));
    }

    private static void misc() {
        section("幂等与覆盖");
        String trad = "我們說好不分離，要一直走到最後，看細水長流。";
        String once = Zh.toSimplified(trad);
        eq("二次转换不变", once, Zh.toSimplified(once));
        check("转换后不再含表内繁体", !Zh.hasTraditional(once));
        check("原文被判为含繁体", Zh.hasTraditional(trad));
        check("简体文本 hasTraditional=false", !Zh.hasTraditional("我们相爱的故事"));
        check("转出来的不是空", once.length() >= trad.length() - 2);

        // 覆盖率抽查：20 个高频繁体逐个核
        String[][] sample = {
                {"愛", "爱"}, {"戀", "恋"}, {"夢", "梦"}, {"願", "愿"},
                {"淚", "泪"}, {"傷", "伤"}, {"溫", "温"}, {"柔", "柔"},
                {"時", "时"}, {"間", "间"}, {"記", "记"}, {"憶", "忆"},
                {"聲", "声"}, {"聽", "听"}, {"遠", "远"}, {"邊", "边"},
                {"誰", "谁"}, {"讓", "让"}, {"給", "给"}, {"變", "变"},
        };
        int okCount = 0;
        for (String[] p : sample) {
            if (Zh.toSimplified(p[0]).equals(p[1])) {
                okCount++;
            }
        }
        check("高频字覆盖 " + okCount + "/20", okCount == sample.length);
    }

    // ------------------------------------------------------------------

    private static void eq(String name, String expect, String actual) {
        if (expect.equals(actual)) {
            passed++;
            System.out.println("  ok   " + name);
        } else {
            failed++;
            System.out.println("  FAIL " + name + "：期望「" + expect + "」，实际「" + actual + "」");
        }
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

    private static void section(String name) {
        System.out.println();
        System.out.println("[" + name + "]");
    }
}
