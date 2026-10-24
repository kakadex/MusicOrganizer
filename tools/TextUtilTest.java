import com.dsh.musicorganizer.core.TextUtil;

import java.util.List;

/**
 * 离线回归测试（纯 JVM）：文本归一 + 相似度 + 多艺人拆分（第一档 ②④⑤）。
 *
 * 覆盖：
 *   1. normCompare 连字符归一（全角/半角/变体横线 → '-'）
 *   2. textSimilarity 边界（相同=1、空=0、繁简=1）
 *   3. 短中文歌名相似度（重合一字不会虚高到接近 1）
 *   4. 子串包含（「晴天」vs「晴天 完整版」）
 *   5. splitArtists 拆分 / 白名单保护 / 去重
 *   6. bestArtistSimilarity 合唱匹配（本地「周杰伦」vs 候选「周杰伦/杨瑞代」）
 */
public class TextUtilTest {

    static int fails = 0;

    static void ok(String name, boolean cond) {
        if (!cond) {
            fails++;
        }
        System.out.println((cond ? "  ok   " : "  FAIL ") + name);
    }

    static double sim(String a, String b) {
        return TextUtil.textSimilarity(a, b);
    }

    public static void main(String[] args) {
        normDash();
        similarityBounds();
        shortChinese();
        contains();
        splitArtists();
        bestArtist();

        System.out.println(fails == 0 ? "全部通过" : (fails + " 项失败"));
        if (fails > 0) {
            System.exit(1);
        }
    }

    static void normDash() {
        System.out.println("[1] normCompare 连字符归一");
        String a = TextUtil.normCompare("周杰伦－晴天");
        String b = TextUtil.normCompare("周杰伦-晴天");
        ok("全角－归一", a.equals(b));
        ok("半角-归一", TextUtil.normCompare("A–B").equals(TextUtil.normCompare("A-B")));
        ok("长破折号归一", TextUtil.normCompare("A—B").equals(TextUtil.normCompare("A-B")));
    }

    static void similarityBounds() {
        System.out.println("[2] textSimilarity 边界");
        ok("相同 = 1", sim("晴天", "晴天") == 1.0);
        ok("空 = 0", sim("", "晴天") == 0.0);
        ok("双空 = 1", sim("", "") == 1.0);
        ok("繁简 = 1", sim("周杰伦", "周杰倫") > 0.99);
        ok("全角数字归一", sim("Track 01", "Track　01") > 0.99);
    }

    static void shortChinese() {
        System.out.println("[3] 短中文歌名");
        double same = sim("晴天", "晴天");
        double oneDiff = sim("晴天", "阴天");   // 2 字，1 字不同
        double noOverlap = sim("晴天", "大海");  // 2 字，完全不同
        ok("重合一字不虚高", oneDiff < 0.8 && oneDiff > 0.0);
        ok("完全不同更低于一字之差", noOverlap < oneDiff);
        ok("完全不同接近 0", noOverlap < 0.35);
        ok("相同明显最高", same > oneDiff);
    }

    static void contains() {
        System.out.println("[4] 子串包含");
        double c = sim("晴天", "晴天 完整版");
        ok("短串是长串子串时偏高", c >= 0.8);
        ok("containsSimilarity", TextUtil.containsSimilarity("晴天", "晴天完整版") >= 0.8);
    }

    static void splitArtists() {
        System.out.println("[5] splitArtists");
        List<String> r = TextUtil.splitArtists("周杰伦/杨瑞代");
        ok("斜杠拆两个", r.size() == 2 && r.get(0).equals("周杰伦") && r.get(1).equals("杨瑞代"));
        ok("顿号拆", TextUtil.splitArtists("周杰伦、林俊杰").size() == 2);
        ok("feat 拆", TextUtil.splitArtists("A feat. B").size() == 2);
        List<String> wl = TextUtil.splitArtists("Simon & Garfunkel");
        ok("白名单不拆 &", wl.size() == 1 && wl.get(0).equals("Simon & Garfunkel"));
        ok("去重", TextUtil.splitArtists("周杰伦、周杰伦").size() == 1);
        ok("空串返回空", TextUtil.splitArtists("  ").isEmpty());
    }

    static void bestArtist() {
        System.out.println("[6] bestArtistSimilarity 合唱匹配");
        double a = TextUtil.bestArtistSimilarity("周杰伦", "周杰伦/杨瑞代");
        ok("本地单人命中候选合唱", a > 0.9);
        double b = TextUtil.bestArtistSimilarity("周杰伦", "林俊杰");
        ok("无关艺人低分", b < 0.5);
    }
}
