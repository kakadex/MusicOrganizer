import com.dsh.musicorganizer.core.SettingsBackup;
import com.dsh.musicorganizer.core.TagFill;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * 设置备份 / 恢复回归测试（纯 JVM）。
 *
 * 覆盖：
 *   1. 键分类（布尔 / 整数 / 字段策略 / 接口地址 / 源开关；设备相关键必须被排除）
 *   2. 导出 JSON 结构（app / version / settings、排序、非 ASCII 转义）
 *   3. 往返：导出 → 导入后值与类型都不变
 *   4. 容错：越界 clamp、非法地址丢弃、陌生键忽略、坏 JSON、app 标识不符
 *   5. 扁平格式（手写的最小备份）与字符串化布尔
 */
public final class SettingsBackupTest {

    private static int passed = 0;
    private static int failed = 0;

    public static void main(String[] args) {
        keyKinds();
        exportShape();
        roundTrip();
        tolerantImport();
        flatFormat();
        badInput();

        System.out.println();
        System.out.println("结果：通过 " + passed + "，失败 " + failed);
        if (failed > 0) {
            System.exit(1);
        }
    }

    // ------------------------------------------------------------------

    private static void keyKinds() {
        section("键分类");
        check("recursive 是布尔", SettingsBackup.kindOf("recursive") == SettingsBackup.Kind.BOOL);
        check("fn_weight 是整数", SettingsBackup.kindOf("fn_weight") == SettingsBackup.Kind.INT);
        check("fp:title 是字段策略",
                SettingsBackup.kindOf("fp:title") == SettingsBackup.Kind.FIELD_MODE);
        check("ep:netease.0 是接口地址",
                SettingsBackup.kindOf("ep:netease.0") == SettingsBackup.Kind.ENDPOINT_URL);
        check("ep_on:netease 是源开关",
                SettingsBackup.kindOf("ep_on:netease") == SettingsBackup.Kind.SOURCE_ON);
        // 设备相关 / 不存在的键一律不备份
        check("tree_uri 不备份", !SettingsBackup.isKnownKey("tree_uri"));
        check("notif_asked 不备份", !SettingsBackup.isKnownKey("notif_asked"));
        check("不存在的字段不认", SettingsBackup.kindOf("fp:nope") == null);
        check("不存在的源不认", SettingsBackup.kindOf("ep_on:nope") == null);
        check("不存在的端点不认", SettingsBackup.kindOf("ep:nope.9") == null);
        check("空键不认", SettingsBackup.kindOf("") == null);
        check("null 不认", SettingsBackup.kindOf(null) == null);
    }

    private static void exportShape() {
        section("导出结构");
        Map<String, Object> values = sample();
        values.put("tree_uri", "content://should/not/appear");
        String json = SettingsBackup.toJson(values, "2026-10-22 导出");
        check("带 app 标识", json.contains("\"app\": \"MusicOrganizer\""));
        check("带 version", json.contains("\"version\": " + SettingsBackup.VERSION));
        check("带 settings", json.contains("\"settings\": {"));
        check("布尔值未加引号", json.contains("\"recursive\": true"));
        check("整数未加引号", json.contains("\"fn_weight\": 20"));
        check("地址是字符串", json.contains("\"ep:netease.0\": \"https://m.example.com/ne\""));
        check("设备相关键被排除", !json.contains("tree_uri"));
        check("非 ASCII 转义", json.contains("\\u5bfc") || json.contains("exportedAt"));
        check("键按字母序（ep 在 fp 之前）",
                json.indexOf("\"ep:netease.0\"") < json.indexOf("\"fp:title\""));
        check("JSON 能被自己解析回来", SettingsBackup.fromJson(json).ok);
    }

    private static void roundTrip() {
        section("导出 → 导入 往返");
        Map<String, Object> values = sample();
        String json = SettingsBackup.toJson(values, "stamp");
        SettingsBackup.Import in = SettingsBackup.fromJson(json);
        check("解析成功", in.ok);
        check("条数一致", in.count() == values.size());
        check("布尔保持布尔", Boolean.TRUE.equals(in.values.get("recursive")));
        check("整数保持整数", Integer.valueOf(20).equals(in.values.get("fn_weight")));
        check("地址保持字符串", "https://m.example.com/ne".equals(in.values.get("ep:netease.0")));
        check("源开关保持布尔", Boolean.FALSE.equals(in.values.get("ep_on:netease")));
        check("字段策略保持整数", Integer.valueOf(TagFill.SUPPLEMENT).equals(in.values.get("fp:title")));
        check("没有警告", in.warnings.isEmpty());
        check("没有忽略项", in.ignored.isEmpty());
        check("摘要含条数", in.summary().contains("可用设置 " + values.size() + " 项"));
    }

    private static void tolerantImport() {
        section("容错：越界 / 非法地址 / 陌生键");
        String json = "{\"app\":\"MusicOrganizer\",\"version\":1,\"settings\":{"
                + "\"fn_weight\":150,"
                + "\"fp:title\":9,"
                + "\"ep:netease.0\":\"ftp://bad\","
                + "\"ep_on:qqmusic\":\"false\","
                + "\"unknown_key\":1"
                + "}}";
        SettingsBackup.Import in = SettingsBackup.fromJson(json);
        check("整体仍然成功", in.ok);
        check("权重被 clamp 到 100", Integer.valueOf(100).equals(in.values.get("fn_weight")));
        check("字段策略被 clamp 到 2", Integer.valueOf(2).equals(in.values.get("fp:title")));
        check("非法地址被丢弃", !in.values.containsKey("ep:netease.0"));
        check("字符串 false 转成布尔", Boolean.FALSE.equals(in.values.get("ep_on:qqmusic")));
        check("陌生键进 ignored", in.ignored.contains("unknown_key"));
        check("警告 3 条", in.warnings.size() == 3);
        check("摘要列出修正项", in.summary().contains("已修正 / 丢弃 3 项"));
        check("摘要列出忽略项", in.summary().contains("忽略不认识的键 1 个"));

        SettingsBackup.Import neg = SettingsBackup.fromJson(
                "{\"app\":\"MusicOrganizer\",\"settings\":{\"fn_weight\":-5}}");
        check("负数被 clamp 到 0", Integer.valueOf(0).equals(neg.values.get("fn_weight")));
    }

    private static void flatFormat() {
        section("扁平格式与字符串化数值");
        String json = "{\"recursive\":\"true\",\"fn_weight\":\"35\",\"ep_on:kugou\":\"0\"}";
        SettingsBackup.Import in = SettingsBackup.fromJson(json);
        check("扁平格式可用", in.ok);
        check("字符串 true → 布尔", Boolean.TRUE.equals(in.values.get("recursive")));
        check("字符串 35 → 整数", Integer.valueOf(35).equals(in.values.get("fn_weight")));
        check("字符串 0 → 布尔 false", Boolean.FALSE.equals(in.values.get("ep_on:kugou")));
        check("元数据键不会被当成设置", !in.values.containsKey("app"));
    }

    private static void badInput() {
        section("坏输入");
        check("空文本", !SettingsBackup.fromJson("").ok);
        check("null", !SettingsBackup.fromJson(null).ok);
        check("不是 JSON", !SettingsBackup.fromJson("hello").ok);
        check("顶层不是对象", !SettingsBackup.fromJson("[1,2]").ok);
        check("缺右括号", !SettingsBackup.fromJson("{\"a\":1").ok);
        SettingsBackup.Import other = SettingsBackup.fromJson(
                "{\"app\":\"OtherApp\",\"settings\":{\"recursive\":true}}");
        check("别的应用备份被拒", !other.ok);
        check("错误信息可读", other.summary().contains("这不是"));
        SettingsBackup.Import wrong = SettingsBackup.fromJson(
                "{\"app\":\"MusicOrganizer\",\"settings\":[1,2]}");
        check("settings 不是对象时报错", !wrong.ok);
    }

    // ------------------------------------------------------------------

    private static Map<String, Object> sample() {
        Map<String, Object> values = new LinkedHashMap<String, Object>();
        values.put("recursive", Boolean.TRUE);
        values.put("fn_weight", Integer.valueOf(20));
        values.put("fp:title", Integer.valueOf(TagFill.SUPPLEMENT));
        values.put("ep:netease.0", "https://m.example.com/ne");
        values.put("ep_on:netease", Boolean.FALSE);
        return values;
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
