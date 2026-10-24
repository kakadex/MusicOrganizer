import com.dsh.musicorganizer.core.ArtistRules;

/**
 * 艺人判定与目录归一回归（纯 JVM）。
 *
 * <p>盯的是 v0.1.16 实机日志暴露的两类问题：
 * <ul>
 *   <li>标签写「华语群星」被当成歌手 → 整盘合辑归进同一个错目录；</li>
 *   <li>同一艺人三种写法 → 三个目录（示例乐队 / 示例乐队 &amp; China Blue / 示例乐队 And China Blue）。</li>
 * </ul>
 */
public class ArtistRulesTest {

    private static int pass = 0;
    private static int fail = 0;

    public static void main(String[] args) {
        // 1) 占位歌手标签必须被识别出来
        check("华语群星 是占位", ArtistRules.isGenericArtist("华语群星"));
        check("群星 是占位", ArtistRules.isGenericArtist("群星"));
        check("Various Artists 是占位", ArtistRules.isGenericArtist("Various Artists"));
        check("未知歌手 是占位", ArtistRules.isGenericArtist("未知歌手"));
        check("空串 是占位", ArtistRules.isGenericArtist(""));
        check("周杰伦 不是占位", !ArtistRules.isGenericArtist("周杰伦"));
        check("张学友 不是占位", !ArtistRules.isGenericArtist("张学友"));

        // 2) 同义写法归一到同一个目录
        check("& 与 And 等价",
                ArtistRules.folderKey("示例乐队 & China Blue")
                        .equals(ArtistRules.folderKey("示例乐队 And China Blue")));
        check("全角＆ 等价",
                ArtistRules.folderKey("示例乐队＆China Blue")
                        .equals(ArtistRules.folderKey("示例乐队 & China Blue")));
        check("顿号 与 & 等价",
                ArtistRules.folderKey("周杰伦、方文山")
                        .equals(ArtistRules.folderKey("周杰伦&方文山")));
        check("大小写归一", ArtistRules.folderKey("BEYOND").equals(ArtistRules.folderKey("beyond")));
        check("空串归一键为空", ArtistRules.folderKey("").isEmpty());

        // 3) 不能过度合并：Simon & Garfunkel 与 Simon 是两个键
        check("组合不并入个人",
                !ArtistRules.folderKey("Simon & Garfunkel")
                        .equals(ArtistRules.folderKey("Simon")));

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
