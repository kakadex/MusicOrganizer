import com.dsh.musicorganizer.core.SourceRank;

/**
 * 数据源优先级与候选排序回归（纯 JVM）。
 *
 * <p>v0.1.44 起「国内源优先」。这个测试盯三件事：
 * <ol>
 *   <li>顺序表本身是国内在前、海外在后；</li>
 *   <li>置信度接近时国内源真的排前面（这是改动的目的）；</li>
 *   <li>置信度明显更高时仍按置信度（别把海外源的正确答案硬压掉）。</li>
 * </ol>
 */
public class SourceRankTest {

    private static int pass = 0;
    private static int fail = 0;

    public static void main(String[] args) {
        // 1) 顺序：国内五家严格在海外三家之前
        check("网易最优先", SourceRank.priority("netease") == 0);
        check("QQ 第二", SourceRank.priority("qqmusic") == 1);
        check("酷狗第三", SourceRank.priority("kugou") == 2);
        check("酷我第四", SourceRank.priority("kuwo") == 3);
        check("咪咕第五", SourceRank.priority("migu") == 4);
        check("MusicBrainz 第六", SourceRank.priority("musicbrainz") == 5);
        check("Deezer 第七", SourceRank.priority("deezer") == 6);
        check("iTunes 第八", SourceRank.priority("itunes") == 7);

        // 2) 国内一家都不许排到海外后面
        boolean allBefore = true;
        String[] cn = {"netease", "qqmusic", "kugou", "kuwo", "migu"};
        String[] os = {"musicbrainz", "deezer", "itunes"};
        for (String c : cn) {
            for (String o : os) {
                if (SourceRank.priority(c) >= SourceRank.priority(o)) {
                    allBefore = false;
                }
            }
        }
        check("国内五家全在海外三家之前", allBefore);

        // 3) 国内源判定
        check("网易是国内", SourceRank.isChinese("netease"));
        check("咪咕是国内", SourceRank.isChinese("migu"));
        check("MusicBrainz 不是国内", !SourceRank.isChinese("musicbrainz"));
        check("iTunes 不是国内", !SourceRank.isChinese("itunes"));
        check("未知源不是国内", !SourceRank.isChinese("unknown"));
        check("null 不是国内", !SourceRank.isChinese(null));

        // 4) 未登记源排在最后
        check("未知源排最后", SourceRank.priority("nobody") == 8);
        check("null 排最后", SourceRank.priority(null) == 8);

        // 5) 置信度完全相同 → 国内源在前
        check("同分国内在前",
                SourceRank.compare("netease", 0.90, "musicbrainz", 0.90) < 0);
        check("同分海外在后",
                SourceRank.compare("musicbrainz", 0.90, "netease", 0.90) > 0);

        // 6) 差在容差内（≤0.001）→ 仍国内优先
        check("差 0.0005 国内优先",
                SourceRank.compare("netease", 0.9000, "musicbrainz", 0.9005) < 0);
        check("差 0.001 仍国内优先",
                SourceRank.compare("netease", 0.9000, "musicbrainz", 0.9010) <= 0);

        // 7) 差超过容差 → 置信度高者在前（哪怕它是海外源）
        check("海外明显更准就排前",
                SourceRank.compare("musicbrainz", 0.95, "netease", 0.60) < 0);
        check("国内明显更准就排前",
                SourceRank.compare("netease", 0.95, "itunes", 0.60) < 0);

        // 8) 同为国内：按置信度
        check("国内之间比置信度",
                SourceRank.compare("qqmusic", 0.95, "netease", 0.80) < 0);
        // 9) 同为海外：按置信度
        check("海外之间比置信度",
                SourceRank.compare("deezer", 0.95, "musicbrainz", 0.80) < 0);

        // 10) 排序稳定性：对同一输入反复比较结果一致（Comparator 契约）
        int ab = SourceRank.compare("netease", 0.9, "qqmusic", 0.9);
        int ba = SourceRank.compare("qqmusic", 0.9, "netease", 0.9);
        check("反对称", ab < 0 && ba > 0);
        check("自反为 0", SourceRank.compare("netease", 0.9, "netease", 0.9) == 0);

        // 11) order() 返回副本：改它不影响内部表
        String[] o1 = SourceRank.order();
        check("order 长度 8", o1.length == 8);
        o1[0] = "hacked";
        check("改副本不影响优先级", SourceRank.priority("netease") == 0);

        // 12) 展示名
        check("网易展示名", "网易云".equals(SourceRank.label("netease")));
        check("QQ 展示名", "QQ 音乐".equals(SourceRank.label("qqmusic")));
        check("未知源展示原名", "foo".equals(SourceRank.label("foo")));
        check("null 展示空", SourceRank.label(null).isEmpty());

        // 13) 语言感知：中文曲目下国内源优先（覆盖海外 0.85 vs 国内 0.60 的基数落差）
        check("中文曲目：国内压过海外(0.60 vs 0.85)",
                SourceRank.compare("netease", 0.60, "musicbrainz", 0.85, true) < 0);
        check("中文曲目：国内压过 Deezer(0.60 vs 0.75)",
                SourceRank.compare("qqmusic", 0.60, "deezer", 0.75, true) < 0);
        check("中文曲目：海外明显更准仍排前(0.60 vs 0.96)",
                SourceRank.compare("netease", 0.60, "musicbrainz", 0.96, true) > 0);
        check("中文曲目：海外明显更准仍排前(0.60 vs 0.99)",
                SourceRank.compare("kugou", 0.60, "itunes", 0.99, true) > 0);

        // 14) 语言感知：外文曲目下海外源优先（不被国内源错压）
        check("外文曲目：海外压过国内(0.85 vs 0.60)",
                SourceRank.compare("musicbrainz", 0.85, "netease", 0.60, false) < 0);
        check("外文曲目：海外压过国内(0.75 vs 0.60)",
                SourceRank.compare("deezer", 0.75, "qqmusic", 0.60, false) < 0);
        check("外文曲目：同为海外按置信度",
                SourceRank.compare("musicbrainz", 0.95, "itunes", 0.80, false) < 0);
        check("外文曲目：海外之间排序表生效",
                SourceRank.compare("itunes", 0.80, "musicbrainz", 0.80, false) > 0);

        // 15) order 按语种返回不同顺序表
        String[] cnOrder = SourceRank.order(true);
        String[] osOrder = SourceRank.order(false);
        check("order(中文) 国内在前", "netease".equals(cnOrder[0]) && "musicbrainz".equals(cnOrder[5]));
        check("order(外文) 海外在前", "musicbrainz".equals(osOrder[0]) && "netease".equals(osOrder[3]));

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
