import com.dsh.musicorganizer.core.Layout;

import java.util.List;

/**
 * 整理目录结构回归（纯 JVM）。
 *
 * <p>盯的是「换目录结构别把曲库搞乱」：专辑为空不能造「未知专辑」、专辑名里的斜杠不能变成
 * 意外的一层目录、平铺模式必须真的不建子目录。
 */
public class LayoutTest {

    private static int pass = 0;
    private static int fail = 0;

    public static void main(String[] args) {
        // 1) 四种结构的基本形态
        check("艺人层", Layout.path(Layout.ARTIST, "周杰伦", "叶惠美").equals("周杰伦"));
        check("艺人/专辑", Layout.path(Layout.ARTIST_ALBUM, "周杰伦", "叶惠美")
                .equals("周杰伦/叶惠美"));
        check("艺人 - 专辑单层", Layout.path(Layout.ARTIST_ALBUM_JOIN, "周杰伦", "叶惠美")
                .equals("周杰伦 - 叶惠美"));
        check("平铺为空", Layout.path(Layout.FLAT, "周杰伦", "叶惠美").isEmpty());

        // 2) 专辑为空 → 退回艺人层，不造「未知专辑」
        check("缺专辑退艺人", Layout.path(Layout.ARTIST_ALBUM, "周杰伦", "").equals("周杰伦"));
        check("缺专辑退艺人（单层）",
                Layout.path(Layout.ARTIST_ALBUM_JOIN, "周杰伦", null).equals("周杰伦"));
        check("无艺人用专辑", Layout.path(Layout.ARTIST_ALBUM, "", "叶惠美").equals("叶惠美"));
        check("全空为空", Layout.path(Layout.ARTIST_ALBUM, "", "").isEmpty());

        // 3) 专辑名里的斜杠不能变成多一层目录
        check("专辑斜杠被清", Layout.path(Layout.ARTIST_ALBUM, "周杰伦", "EP/Live")
                .equals("周杰伦/EP Live"));
        check("艺人斜杠被清", Layout.path(Layout.ARTIST, "AC/DC", "").equals("AC DC"));
        check("层级数正确", Layout.segments(
                Layout.path(Layout.ARTIST_ALBUM, "周杰伦", "EP/Live")).size() == 2);

        // 4) 目录名清理
        check("首尾点去掉", Layout.sanitizeSegment("...叶惠美...").equals("叶惠美"));
        check("非法字符", Layout.sanitizeSegment("A:B*C?D").equals("A B C D"));
        check("连续空格压缩", Layout.sanitizeSegment("周  杰伦").equals("周 杰伦"));
        check("纯分隔符丢弃", Layout.sanitizeSegment("///").isEmpty());
        check("点号路径丢弃", Layout.sanitizeSegment("..").isEmpty());
        check("空串安全", Layout.sanitizeSegment(null).isEmpty());
        StringBuilder longName = new StringBuilder();
        for (int i = 0; i < 80; i++) {
            longName.append('长');
        }
        check("超长截到 60", Layout.sanitizeSegment(longName.toString()).length() == 60);

        // 5) clamp 越界回落默认
        check("越界回落艺人", Layout.clamp(99) == Layout.ARTIST);
        check("负数回落艺人", Layout.clamp(-1) == Layout.ARTIST);
        check("合法值不变", Layout.clamp(Layout.FLAT) == Layout.FLAT);
        check("标签数量与提示一致", Layout.LABELS.length == Layout.HINTS.length);

        // 6) segments 拆层
        List<String> segs = Layout.segments("周杰伦/叶惠美/");
        check("拆两层", segs.size() == 2);
        check("第一层", segs.get(0).equals("周杰伦"));
        check("第二层", segs.get(1).equals("叶惠美"));
        check("空路径零层", Layout.segments("").isEmpty());
        check("null 零层", Layout.segments(null).isEmpty());

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
