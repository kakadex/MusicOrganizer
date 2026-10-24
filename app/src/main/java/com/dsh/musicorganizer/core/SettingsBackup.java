package com.dsh.musicorganizer.core;

import com.dsh.musicorganizer.net.Endpoints;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 设置备份 / 恢复（JSON 存盘，零第三方依赖）。
 *
 * <p>为什么要有：目录授权、权重、字段策略、数据源地址、各开关散在
 * SharedPreferences 里，换机 / 重装 / 误点「恢复默认」之后只能一项项手调。
 * 这里把它们导出成一份 JSON，需要时逐项校验后写回。
 *
 * <p>三条设计原则：
 * <ol>
 *   <li><b>白名单</b>：只导出 {@link #isKnownKey} 认识的键。`tree_uri`（目录授权）、
 *       `notif_asked`（通知权限已问过）这类<b>设备相关</b>的键必须排除 ——
 *       换台机器上导入一个旧 SAF 授权地址只会让人以为「目录丢了」。</li>
 *   <li><b>逐项容错</b>：手改过的 JSON 里出现越界数字、失效地址、陌生键，
 *       都不该让整个导入失败；能修的修（clamp），修不了的丢弃并记进 warnings。</li>
 *   <li><b>不依赖 Android</b>：这样能在纯 JVM 里跑回归（{@code tools/SettingsBackupTest}）。</li>
 * </ol>
 */
public final class SettingsBackup {

    private SettingsBackup() {
    }

    /** 备份文件里的应用标识，用来挡住「导入别人的 JSON」。 */
    public static final String APP_TAG = "MusicOrganizer";
    /** 备份格式版本；结构变了就 +1，导入时向下兼容。 */
    public static final int VERSION = 1;

    /** 常规布尔开关（与 OrganizePage 里的复选框一一对应）。 */
    public static final String[] BOOL_KEYS = {
            "recursive", "skip_artist", "fast", "net", "cn", "dry",
            "lrc_overwrite", "lrc_plain", "lrc_embed", "lyrics_simplify", "tag_overwrite",
            // 更新检查开关（ui/Repo.KEY_UPDATE_AUTO）。上次检查时间与远端版本号属于
            // 会过期的运行态，不进备份。
            "update_auto",
            // 外观偏好：夜间模式开关（主题 id 是整数，见 INT_KEYS）
            "theme_dark",
            // v0.1.36 补进备份：未识别是否搬进「未识别」目录（之前漏了，换机后行为会变）
            "move_unrec",
    };

    /** 整数键（权重 / 主题 / 目录结构）。 */
    public static final String KEY_LAYOUT = "layout_id";

    /** 常规整数设置。 */
    public static final String KEY_WEIGHT = "fn_weight";
    /** 主题 id（0 暖橙 / 1 极简 / 2 霓虹）。 */
    public static final String KEY_THEME_ID = "theme_id";

    public static final String PREFIX_ENDPOINT = "ep:";
    public static final String PREFIX_SOURCE_ON = "ep_on:";
    public static final String PREFIX_FIELD_MODE = "fp:";

    /** 键的类别（决定校验方式与写回类型）。 */
    public enum Kind {
        BOOL, INT, FIELD_MODE, ENDPOINT_URL, SOURCE_ON
    }

    /** 判断一个偏好键属于哪类；返回 null 表示「不是可备份的设置」。 */
    public static Kind kindOf(String key) {
        if (key == null || key.isEmpty()) {
            return null;
        }
        for (String k : BOOL_KEYS) {
            if (k.equals(key)) {
                return Kind.BOOL;
            }
        }
        if (KEY_WEIGHT.equals(key) || KEY_THEME_ID.equals(key) || KEY_LAYOUT.equals(key)) {
            return Kind.INT;
        }
        if (key.startsWith(PREFIX_FIELD_MODE)) {
            String field = key.substring(PREFIX_FIELD_MODE.length());
            return isField(field) ? Kind.FIELD_MODE : null;
        }
        if (key.startsWith(PREFIX_SOURCE_ON)) {
            String src = key.substring(PREFIX_SOURCE_ON.length());
            return Endpoints.find(src) != null ? Kind.SOURCE_ON : null;
        }
        if (key.startsWith(PREFIX_ENDPOINT)) {
            String ep = key.substring(PREFIX_ENDPOINT.length());
            return Endpoints.isEndpointKey(ep) ? Kind.ENDPOINT_URL : null;
        }
        return null;
    }

    /**
     * 内置默认值（「恢复默认设置」与回归测试共用）。
     *
     * <p>数值必须和界面上的读取处一致：{@code repo.bool("fast", true)} 这类调用的第二参数
     * 就是这里的值。改默认值时**两处一起改**，否则「恢复默认」会给出一个界面没预期的值。
     */
    public static java.util.Map<String, Object> defaults() {
        java.util.Map<String, Object> m = new java.util.LinkedHashMap<String, Object>();
        // 整理
        m.put("recursive", Boolean.TRUE);
        m.put("skip_artist", Boolean.TRUE);
        m.put("fast", Boolean.TRUE);
        m.put("net", Boolean.TRUE);
        m.put("cn", Boolean.TRUE);
        m.put("dry", Boolean.FALSE);
        m.put("move_unrec", Boolean.FALSE);
        // 歌词
        m.put("lrc_overwrite", Boolean.FALSE);
        m.put("lrc_plain", Boolean.FALSE);
        m.put("lrc_embed", Boolean.TRUE);
        m.put("lyrics_simplify", Boolean.TRUE);
        // 标签
        m.put("tag_overwrite", Boolean.FALSE);
        // 更新检查
        m.put("update_auto", Boolean.TRUE);
        // 外观
        m.put("theme_dark", Boolean.FALSE);
        m.put(KEY_THEME_ID, Integer.valueOf(1));
        m.put(KEY_WEIGHT, Integer.valueOf(20));
        m.put(KEY_LAYOUT, Integer.valueOf(0));
        return m;
    }

    /**
     * 与默认值不同的设置项（键名列表，排序后返回）。
     *
     * <p>用于「恢复默认设置」前告诉用户会改哪些：值为 {@code null} 表示当前没设置过，
     * 视为与默认一致。
     */
    public static List<String> diffFromDefaults(java.util.Map<String, ?> current) {
        List<String> out = new ArrayList<String>();
        if (current == null) {
            return out;
        }
        for (java.util.Map.Entry<String, Object> e : defaults().entrySet()) {
            Object now = current.get(e.getKey());
            if (now == null) {
                continue;
            }
            if (!String.valueOf(now).equals(String.valueOf(e.getValue()))) {
                out.add(e.getKey());
            }
        }
        java.util.Collections.sort(out);
        return out;
    }

    /** 是否是可备份的键（导出时按它过滤）。 */
    public static boolean isKnownKey(String key) {
        return kindOf(key) != null;
    }

    private static boolean isField(String field) {
        for (String f : TagFill.CANDIDATE_FIELDS) {
            if (f.equals(field)) {
                return true;
            }
        }
        return false;
    }

    // ------------------------------------------------------------------
    // 导出
    // ------------------------------------------------------------------

    /**
     * 把设置写成 JSON。
     *
     * @param values 已按 {@link Kind} 排好类型的设置项（Repository 从 SharedPreferences 取）
     * @param stamp  导出时间（由调用方给，便于测试）
     */
    public static String toJson(Map<String, ?> values, String stamp) {
        StringBuilder sb = new StringBuilder();
        sb.append("{\n");
        sb.append("  \"app\": ").append(Json.quote(APP_TAG)).append(",\n");
        sb.append("  \"version\": ").append(VERSION).append(",\n");
        sb.append("  \"exportedAt\": ").append(Json.quote(stamp == null ? "" : stamp)).append(",\n");
        sb.append("  \"settings\": {");
        boolean first = true;
        // 排序输出，方便用户 diff 两份备份
        List<String> keys = new ArrayList<String>();
        if (values != null) {
            for (String k : values.keySet()) {
                if (isKnownKey(k) && values.get(k) != null) {
                    keys.add(k);
                }
            }
        }
        java.util.Collections.sort(keys);
        for (String k : keys) {
            sb.append(first ? "\n" : ",\n");
            first = false;
            sb.append("    ").append(Json.quote(k)).append(": ").append(Json.value(values.get(k)));
        }
        sb.append(first ? "}\n" : "\n  }\n");
        sb.append("}\n");
        return sb.toString();
    }


    // ------------------------------------------------------------------
    // 导入
    // ------------------------------------------------------------------

    /** 导入结果：values 可直接逐项写回；warnings/ignored 用来告诉用户「哪些没生效」。 */
    public static final class Import {
        public boolean ok;
        public String error;
        public int version;
        /** 校验通过、可以直接写回的设置（Boolean / Integer / String）。 */
        public final Map<String, Object> values = new LinkedHashMap<String, Object>();
        /** 不认识的键（多半来自别的版本或手工加的）。 */
        public final List<String> ignored = new ArrayList<String>();
        /** 被修正或丢弃的项说明。 */
        public final List<String> warnings = new ArrayList<String>();

        public int count() {
            return values.size();
        }

        /** 一句话摘要（导入确认框里用）。 */
        public String summary() {
            if (!ok) {
                return error == null ? "无法读取" : error;
            }
            int ep = 0;
            int on = 0;
            int fp = 0;
            int other = 0;
            for (Map.Entry<String, Object> e : values.entrySet()) {
                Kind k = kindOf(e.getKey());
                if (k == Kind.ENDPOINT_URL) {
                    ep++;
                } else if (k == Kind.SOURCE_ON) {
                    on++;
                } else if (k == Kind.FIELD_MODE) {
                    fp++;
                } else {
                    other++;
                }
            }
            StringBuilder sb = new StringBuilder();
            sb.append("可用设置 ").append(values.size()).append(" 项：常规 ").append(other)
                    .append("，接口地址 ").append(ep)
                    .append("，数据源开关 ").append(on)
                    .append("，字段策略 ").append(fp);
            if (!warnings.isEmpty()) {
                sb.append("\n\n已修正 / 丢弃 ").append(warnings.size()).append(" 项：");
                appendLimited(sb, warnings, 8);
            }
            if (!ignored.isEmpty()) {
                sb.append("\n\n忽略不认识的键 ").append(ignored.size()).append(" 个：");
                appendLimited(sb, ignored, 8);
            }
            return sb.toString();
        }

        private static void appendLimited(StringBuilder sb, List<String> items, int max) {
            for (int i = 0; i < items.size() && i < max; i++) {
                sb.append("\n· ").append(items.get(i));
            }
            if (items.size() > max) {
                sb.append("\n· …还有 ").append(items.size() - max).append(" 项");
            }
        }
    }

    /**
     * 解析备份 JSON 并逐项校验。
     *
     * <p>兼容两种结构：标准格式（带 {@code app/version/settings}）与
     * 「扁平 map」（直接是键值对），后者方便用户手写一份最小备份。
     */
    public static Import fromJson(String text) {
        Import out = new Import();
        if (text == null || text.trim().isEmpty()) {
            out.error = "文件是空的";
            return out;
        }
        Object root;
        try {
            root = Json.parse(text);
        } catch (RuntimeException e) {
            out.error = "不是合法的 JSON：" + e.getMessage();
            return out;
        }
        if (!(root instanceof Map)) {
            out.error = "备份文件的顶层必须是 JSON 对象";
            return out;
        }
        @SuppressWarnings("unchecked")
        Map<String, Object> top = (Map<String, Object>) root;
        Object app = top.get("app");
        if (app != null && !APP_TAG.equals(String.valueOf(app))) {
            out.error = "这不是「音乐整理」的设置备份（app=" + app + "）";
            return out;
        }
        Object ver = top.get("version");
        out.version = ver instanceof Number ? ((Number) ver).intValue() : VERSION;
        if (out.version > VERSION) {
            out.warnings.add("备份来自更高版本（v" + out.version + "），部分项可能被忽略");
        }
        Object settings = top.get("settings");
        Map<?, ?> map;
        if (settings instanceof Map) {
            map = (Map<?, ?>) settings;
        } else if (settings == null) {
            map = top; // 扁平格式
        } else {
            out.error = "settings 字段必须是对象";
            return out;
        }
        for (Map.Entry<?, ?> e : map.entrySet()) {
            String key = String.valueOf(e.getKey());
            if ("app".equals(key) || "version".equals(key) || "exportedAt".equals(key)
                    || "settings".equals(key)) {
                continue; // 扁平格式里会撞到元数据
            }
            Kind kind = kindOf(key);
            if (kind == null) {
                out.ignored.add(key);
                continue;
            }
            Object clean = sanitize(key, e.getValue(), out.warnings);
            if (clean != null) {
                out.values.put(key, clean);
            }
        }
        out.ok = true;
        return out;
    }

    /**
     * 逐类校验单个值；返回 null 表示这一项丢弃。
     *
     * @param warnings 修正/丢弃的说明会追加到这里
     */
    public static Object sanitize(String key, Object raw, List<String> warnings) {
        Kind kind = kindOf(key);
        if (kind == null) {
            return null;
        }
        if (kind == Kind.BOOL || kind == Kind.SOURCE_ON) {
            Boolean b = asBool(raw);
            if (b == null) {
                warn(warnings, key, "不是布尔值，已丢弃");
            }
            return b;
        }
        if (kind == Kind.INT) {
            Integer v = asInt(raw);
            if (v == null) {
                warn(warnings, key, "不是整数，已丢弃");
                return null;
            }
            int max = KEY_THEME_ID.equals(key) ? Theme.NAMES.length - 1 : NameWeight.MAX_PERCENT;
            if (v < 0 || v > max) {
                int fixed = Math.max(0, Math.min(v, max));
                warn(warnings, key, "越界 " + v + " → " + fixed);
                return Integer.valueOf(fixed);
            }
            return v;
        }
        if (kind == Kind.FIELD_MODE) {
            Integer v = asInt(raw);
            if (v == null) {
                warn(warnings, key, "不是整数，已丢弃");
                return null;
            }
            if (v < TagFill.DISABLED || v > TagFill.OVERWRITE) {
                int fixed = Math.max(TagFill.DISABLED, Math.min(v, TagFill.OVERWRITE));
                warn(warnings, key, "取值 " + v + " 不在 0~2，已修正为 " + fixed);
                return Integer.valueOf(fixed);
            }
            return v;
        }
        // ENDPOINT_URL
        String url = raw == null ? null : String.valueOf(raw).trim();
        if (!Endpoints.isValidUrl(url)) {
            warn(warnings, key, "不是 http/https 地址，已丢弃");
            return null;
        }
        return url;
    }

    private static void warn(List<String> warnings, String key, String why) {
        if (warnings != null) {
            warnings.add(key + "：" + why);
        }
    }

    private static Boolean asBool(Object raw) {
        if (raw instanceof Boolean) {
            return (Boolean) raw;
        }
        if (raw instanceof Number) {
            return Boolean.valueOf(((Number) raw).intValue() != 0);
        }
        if (raw != null) {
            String s = String.valueOf(raw).trim();
            if ("true".equalsIgnoreCase(s) || "1".equals(s)) {
                return Boolean.TRUE;
            }
            if ("false".equalsIgnoreCase(s) || "0".equals(s)) {
                return Boolean.FALSE;
            }
        }
        return null;
    }

    private static Integer asInt(Object raw) {
        if (raw instanceof Number) {
            return Integer.valueOf((int) Math.round(((Number) raw).doubleValue()));
        }
        if (raw != null) {
            try {
                return Integer.valueOf((int) Math.round(Double.parseDouble(String.valueOf(raw).trim())));
            } catch (NumberFormatException ignored) {
                return null;
            }
        }
        return null;
    }

}
