import com.dsh.musicorganizer.core.SettingsBackup;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 恢复默认设置回归（纯 JVM）。
 *
 * <p>盯的是「默认值表」与「差异计算」：默认值必须覆盖所有会显示在界面上的开关，
 * 差异只报真的不一样的键，没设置过（null）视为默认。
 */
public class SettingsDefaultsTest {

    private static int pass = 0;
    private static int fail = 0;

    public static void main(String[] args) {
        Map<String, Object> d = SettingsBackup.defaults();

        // 1) 关键默认值
        check("整理递归默认开", Boolean.TRUE.equals(d.get("recursive")));
        check("跳过已归位默认开", Boolean.TRUE.equals(d.get("skip_artist")));
        check("快速模式默认开", Boolean.TRUE.equals(d.get("fast")));
        check("联网默认开", Boolean.TRUE.equals(d.get("net")));
        check("国内源默认开", Boolean.TRUE.equals(d.get("cn")));
        check("仅预览默认关", Boolean.FALSE.equals(d.get("dry")));
        check("未识别搬运默认关", Boolean.FALSE.equals(d.get("move_unrec")));
        check("嵌入歌词默认开", Boolean.TRUE.equals(d.get("lrc_embed")));
        check("繁转简默认开", Boolean.TRUE.equals(d.get("lyrics_simplify")));
        check("覆盖 .lrc 默认关", Boolean.FALSE.equals(d.get("lrc_overwrite")));
        check("标签覆盖默认关", Boolean.FALSE.equals(d.get("tag_overwrite")));
        check("权重 20", Integer.valueOf(20).equals(d.get(SettingsBackup.KEY_WEIGHT)));
        check("主题默认 1", Integer.valueOf(1).equals(d.get(SettingsBackup.KEY_THEME_ID)));
        check("目录结构默认 0", Integer.valueOf(0).equals(d.get(SettingsBackup.KEY_LAYOUT)));

        // 2) 默认表里的键都应该是「可备份键」，否则 resetSettings 删不到
        boolean allKnown = true;
        for (String k : d.keySet()) {
            allKnown &= SettingsBackup.isKnownKey(k);
        }
        check("默认键都被 isKnownKey 覆盖", allKnown);

        // 3) 差异计算：空 → 无差异
        check("null 无差异", SettingsBackup.diffFromDefaults(null).isEmpty());
        check("空表无差异", SettingsBackup.diffFromDefaults(new LinkedHashMap<String, Object>())
                .isEmpty());

        // 4) 与默认一致 → 无差异
        Map<String, Object> same = new LinkedHashMap<String, Object>(d);
        check("全默认无差异", SettingsBackup.diffFromDefaults(same).isEmpty());

        // 5) 改一个布尔
        Map<String, Object> changed = new LinkedHashMap<String, Object>(d);
        changed.put("fast", Boolean.FALSE);
        List<String> diff = SettingsBackup.diffFromDefaults(changed);
        check("改布尔被识别", diff.size() == 1 && diff.get(0).equals("fast"));

        // 6) 改一个整数
        Map<String, Object> weight = new LinkedHashMap<String, Object>(d);
        weight.put(SettingsBackup.KEY_WEIGHT, Integer.valueOf(60));
        check("改权重被识别", SettingsBackup.diffFromDefaults(weight).size() == 1);

        // 7) 多处修改按字母序
        Map<String, Object> many = new LinkedHashMap<String, Object>(d);
        many.put("theme_dark", Boolean.TRUE);
        many.put("dry", Boolean.TRUE);
        many.put("cn", Boolean.FALSE);
        List<String> md = SettingsBackup.diffFromDefaults(many);
        check("三项差异", md.size() == 3);
        check("按字母序", md.get(0).equals("cn") && md.get(1).equals("dry")
                && md.get(2).equals("theme_dark"));

        // 8) null 值视为「没设置过」→ 不算差异
        Map<String, Object> withNull = new LinkedHashMap<String, Object>(d);
        withNull.put("fast", null);
        check("null 不算差异", SettingsBackup.diffFromDefaults(withNull).isEmpty());

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
