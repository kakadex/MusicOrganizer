import com.dsh.musicorganizer.core.NameTemplate;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * 文件名模板回归（纯 JVM）。
 *
 * <p>盯的是「按模板重命名」最容易出事的几处：字段缺失时留下残渣（`- -`、`..`）、
 * 音轨没补零、非法字符、扩展名重复、超长截断把扩展名切掉。
 */
public class NameTemplateTest {

    private static int pass = 0;
    private static int fail = 0;

    public static void main(String[] args) {
        Map<String, String> f = new LinkedHashMap<String, String>();
        f.put("artist", "周杰伦");
        f.put("title", "晴天");
        f.put("album", "叶惠美");
        f.put("year", "2003");
        f.put("track", "3");
        f.put("genre", "Pop");

        // 1) 基本模板
        check("艺人 - 歌名", NameTemplate.render("{artist} - {title}", f, ".mp3")
                .equals("周杰伦 - 晴天.mp3"));
        check("歌名 - 艺人", NameTemplate.render("{title} - {artist}", f, ".mp3")
                .equals("晴天 - 周杰伦.mp3"));
        check("音轨补零", NameTemplate.render("{track}. {title}", f, ".flac")
                .equals("03. 晴天.flac"));
        check("音轨指定位数", NameTemplate.render("{track:3} {title}", f, ".mp3")
                .equals("003 晴天.mp3"));
        check("音轨 3/12 只取前段", NameTemplate.render("{track} {title}",
                fields("3/12", "x"), ".mp3").equals("03 x.mp3"));
        check("音轨非数字原样", NameTemplate.render("{track} {title}",
                fields("A1", "x"), ".mp3").equals("A1 x.mp3"));

        // 2) 缺字段：残渣要清干净
        check("缺艺人只剩歌名", NameTemplate.render("{artist} - {title}",
                fields("", "晴天"), ".mp3").equals("晴天.mp3"));
        check("缺音轨不留前导点", NameTemplate.render("{track}. {title}",
                fields("", "晴天"), ".mp3").equals("晴天.mp3"));
        check("缺专辑不留双横线", NameTemplate.render("{artist} - {album} - {title}", f, ".mp3")
                .equals("周杰伦 - 叶惠美 - 晴天.mp3"));
        Map<String, String> onlyTitle = new LinkedHashMap<String, String>();
        onlyTitle.put("title", "晴天");
        check("三连缺失不剩破折号", NameTemplate.render("{artist} - {album} - {title}",
                onlyTitle, ".mp3").equals("晴天.mp3"));
        check("全空返回空", NameTemplate.render("{artist} - {title}",
                new LinkedHashMap<String, String>(), ".mp3").isEmpty());

        // 3) 大小写 / 未知占位符 / 没闭合的括号
        check("占位符大小写不敏感", NameTemplate.render("{ARTIST} - {Title}", f, ".mp3")
                .equals("周杰伦 - 晴天.mp3"));
        check("未知占位符按空", NameTemplate.render("{artist} {bpm} {title}", f, ".mp3")
                .equals("周杰伦 晴天.mp3"));
        check("空占位符被吃掉", NameTemplate.render("{artist}{}{title}", f, ".mp3")
                .equals("周杰伦晴天.mp3"));
        check("没闭合括号原样保留", NameTemplate.render("{artist} - {title", f, ".mp3")
                .contains("{title"));

        // 4) 非法字符
        check("斜杠变空格", NameTemplate.render("{artist} {title}",
                pair("AC/DC", "T.N.T"), ".mp3").equals("AC DC T.N.T.mp3"));
        check("冒号星号问号", NameTemplate.render("{title}", fields("", "A:B*C?D"), ".mp3")
                .equals("A B C D.mp3"));
        check("控制字符变空格", NameTemplate.render("{title}",
                fields("", "a\u0001b"), ".mp3").equals("a b.mp3"));

        // 5) 扩展名
        check("模板没 {ext} 自动补", NameTemplate.render("{title}", f, "mp3")
                .equals("晴天.mp3"));
        check("模板写了 {ext} 不重复", NameTemplate.render("{title}{ext}", f, ".mp3")
                .equals("晴天.mp3"));
        check("无扩展名不报错", NameTemplate.render("{title}", f, "").equals("晴天"));

        // 6) 长度
        StringBuilder longTitle = new StringBuilder();
        for (int i = 0; i < 60; i++) {
            longTitle.append('长');
        }
        String longName = NameTemplate.render("{title}", fields("", longTitle.toString()), ".flac");
        check("超长截到 90 内", longName.length() <= 90);
        check("超长仍保留扩展名", longName.endsWith(".flac"));

        // 7) 冲突序号
        check("冲突序号", NameTemplate.withIndex("晴天.mp3", 2).equals("晴天 (2).mp3"));
        check("无扩展名冲突序号", NameTemplate.withIndex("晴天", 3).equals("晴天 (3)"));

        // 8) tidy / describe
        check("首尾破折号被清", NameTemplate.tidy("- 晴天 -").equals("晴天"));
        check("连续分隔符压缩", NameTemplate.tidy("晴天  -  - 夜曲").equals("晴天 - 夜曲"));
        check("describe 跳过", NameTemplate.describe("a.mp3", "").contains("跳过"));
        check("describe 不变", NameTemplate.describe("a.mp3", "a.mp3").contains("不变"));
        check("describe 变化带箭头", NameTemplate.describe("a.mp3", "b.mp3").contains("→ b.mp3"));

        // 9) 模板拆词（界面说明用）
        check("tokens 数量", NameTemplate.tokens("{artist} - {title}").size() == 3);
        check("空模板用默认", NameTemplate.render("", f, ".mp3").equals("周杰伦 - 晴天.mp3"));
        check("空白模板用默认", NameTemplate.render("   ", f, ".mp3").equals("周杰伦 - 晴天.mp3"));

        // 10) 预设都能渲染出非空名字
        boolean allOk = true;
        for (String p : NameTemplate.PRESETS) {
            allOk &= !NameTemplate.render(p, f, ".mp3").isEmpty();
        }
        check("五个预设都可用", allOk);

        System.out.println("结果：通过 " + pass + "，失败 " + fail);
        if (fail > 0) {
            System.exit(1);
        }
    }

    private static Map<String, String> pair(String artist, String title) {
        Map<String, String> m = new LinkedHashMap<String, String>();
        m.put("artist", artist);
        m.put("title", title);
        return m;
    }

    private static Map<String, String> fields(String track, String title) {
        Map<String, String> m = new LinkedHashMap<String, String>();
        m.put("track", track);
        m.put("title", title);
        m.put("artist", "");
        m.put("album", "");
        return m;
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
