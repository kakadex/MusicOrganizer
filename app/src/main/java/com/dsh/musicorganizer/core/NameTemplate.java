package com.dsh.musicorganizer.core;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * 文件名模板：把标签字段拼成文件名。
 *
 * <p>以前「按标签重命名」把格式写死成「艺人 - 歌名」，改不了。这里做成模板：
 * <pre>
 *   {artist} - {title}       → 周杰伦 - 晴天.mp3
 *   {track}. {title}         → 03. 晴天.mp3
 *   {artist}/{album}/{title}  → 目录分隔符被抹掉，只用于文件名
 * </pre>
 *
 * <p>约定：
 * <ul>
 *   <li>占位符大小写不敏感，未知占位符按空串处理（整段被抹平后多余的「-」「.」一起清掉）；</li>
 *   <li>{@code {track}} 是数字就补到两位（1 → 01），{@code {track:3}} 指定位数；</li>
 *   <li>文件名非法字符 {@code \ / : * ? " < > |} 与控制字符替换成空格并压缩；</li>
 *   <li>去掉首尾空白与「. 」，长度上限 90（留出扩展名和「 (2)」的余量）；</li>
 *   <li>模板里没写 {@code {ext}} 时自动补原扩展名。</li>
 * </ul>
 *
 * <p>纯 Java（不依赖 Android），回归在 {@code tools/NameTemplateTest}。
 */
public final class NameTemplate {

    /** 常用预设（顺序即界面里的顺序）。 */
    public static final String[] PRESETS = new String[]{
            "{artist} - {title}",
            "{title} - {artist}",
            "{track}. {title}",
            "{artist} - {album} - {track}. {title}",
            "{title}"
    };

    public static final String DEFAULT = PRESETS[0];

    private NameTemplate() {
    }

    /** 模板里有意义的占位符（用于界面说明）。 */
    public static String help() {
        return "可用占位符：{artist} 艺人、{title} 标题、{album} 专辑、{year} 年份、"
                + "{track} 音轨、{genre} 流派、{ext} 原扩展名。未知占位符按空处理。";
    }

    /** 由一条标签记录构造字段表（键为小写占位符名）。 */
    public static Map<String, String> fields(Tags tags) {
        Map<String, String> m = new LinkedHashMap<String, String>();
        if (tags == null) {
            return m;
        }
        m.put("artist", safe(tags.get("artist")));
        m.put("title", safe(tags.get("title")));
        m.put("album", safe(tags.get("album")));
        m.put("year", safe(tags.get("year")));
        m.put("date", safe(tags.get("year")));
        m.put("genre", safe(tags.get("genre")));
        m.put("track", safe(tags.get("track")));
        return m;
    }

    /** 音轨号补零：1 → 01；`3/12` 这种只取前一段；非数字原样返回。 */
    public static String padTrack(String value) {
        return padTrack(value, 2);
    }

    public static String padTrack(String value, int width) {
        if (value == null) {
            return "";
        }
        String v = value.trim();
        int slash = v.indexOf('/');
        if (slash > 0) {
            v = v.substring(0, slash).trim();
        }
        if (v.isEmpty()) {
            return "";
        }
        for (int i = 0; i < v.length(); i++) {
            if (!Character.isDigit(v.charAt(i))) {
                return v;
            }
        }
        StringBuilder sb = new StringBuilder(v);
        while (sb.length() < width) {
            sb.insert(0, '0');
        }
        return sb.toString();
    }

    /**
     * 渲染模板。
     *
     * @param pattern 模板串；为空则用 {@link #DEFAULT}
     * @param fields  占位符值（键小写，见 {@link #fields}）
     * @param ext     原扩展名（含点，如 ".mp3"；可为空）
     * @return 文件名（含扩展名）；信息不足时返回空串（调用方跳过这个文件）
     */
    public static String render(String pattern, Map<String, String> fields, String ext) {
        String p = (pattern == null || pattern.trim().isEmpty()) ? DEFAULT : pattern.trim();
        Map<String, String> f = fields == null ? new LinkedHashMap<String, String>() : fields;
        String e = ext == null ? "" : ext.trim();
        if (!e.isEmpty() && !e.startsWith(".")) {
            e = "." + e;
        }

        boolean wantsExt = p.toLowerCase(Locale.US).contains("{ext}");
        StringBuilder out = new StringBuilder();
        int i = 0;
        while (i < p.length()) {
            char c = p.charAt(i);
            if (c == '{') {
                int close = p.indexOf('}', i + 1);
                if (close < 0) {
                    // 没闭合：原样保留，别把用户正在输入的内容吃掉
                    out.append(p.substring(i));
                    break;
                }
                String token = p.substring(i + 1, close).trim();
                out.append(valueOf(token, f, e));
                i = close + 1;
            } else {
                out.append(c);
                i++;
            }
        }

        String name = tidy(out.toString());
        if (name.isEmpty()) {
            // 字段全空：别硬补扩展名（会把 ".mp3" 变成 "mp3"）
            return "";
        }
        if (!wantsExt) {
            name = tidy(name + e);
        }
        if (name.length() > 90) {
            name = name.substring(0, 90).trim();
            // 截断后可能把扩展名切掉，补回去
            if (!wantsExt && !e.isEmpty() && !name.toLowerCase(Locale.US).endsWith(e.toLowerCase(Locale.US))) {
                if (name.length() + e.length() <= 90) {
                    name = name + e;
                }
            }
        }
        return name;
    }

    /** 单行预览用：旧名 → 新名，新名为空时给原因。 */
    public static String describe(String oldName, String newName) {
        if (newName == null || newName.isEmpty()) {
            return (oldName == null ? "" : oldName) + " → （跳过：标题为空）";
        }
        if (oldName != null && oldName.equals(newName)) {
            return oldName + " → （不变）";
        }
        return (oldName == null ? "" : oldName) + " → " + newName;
    }

    /** 去掉首尾空白/点、压缩连续空格、清理非法字符。 */
    public static String tidy(String raw) {
        if (raw == null) {
            return "";
        }
        String s = sanitize(raw);
        // 1. 字段缺失会留下「 - 」「. 」这类残渣：连续多段分隔符只留最后一个
        s = collapseSeparators(s);
        // 2. 首尾的分隔符与空白
        s = s.replaceAll("^[\\s\\-_.·—]+", "");
        s = s.replaceAll("[\\s\\-_.·—]+$", "");
        // 3. 「晴天 -夜曲」这种一边没空格的横线补成「 - 」（T-N-T 这种不带空格的不动）
        s = s.replaceAll("\\s+-\\s*|\\s*-\\s+", " - ");
        // 4. 压缩多余空白
        s = s.replaceAll("\\s{2,}", " ").trim();
        return s;
    }

    /**
     * 连续分隔符只保留最后一个：「周杰伦 -  - 晴天」→「周杰伦 - 晴天」。
     * 保留最后一个而不是第一个，是因为模板里「{artist} - {album} - {title}」缺 album 时，
     * 想留下的是紧跟真值的那根横线。
     */
    private static String collapseSeparators(String s) {
        StringBuilder out = new StringBuilder(s.length());
        int i = 0;
        while (i < s.length()) {
            char c = s.charAt(i);
            if (!isSeparator(c)) {
                out.append(c);
                i++;
                continue;
            }
            int j = i + 1;
            boolean another = false;
            while (j < s.length()) {
                char d = s.charAt(j);
                if (d == ' ') {
                    j++;
                    continue;
                }
                another = isSeparator(d);
                break;
            }
            if (another) {
                i = j;
                continue;
            }
            out.append(c);
            i++;
        }
        return out.toString();
    }

    private static boolean isSeparator(char c) {
        return c == '-' || c == '_' || c == '.' || c == '·' || c == '—' || c == '–';
    }

    /** 非法字符替换成空格（不删，避免两个词粘一起），并压缩空格。 */
    public static String sanitize(String raw) {
        if (raw == null) {
            return "";
        }
        StringBuilder sb = new StringBuilder(raw.length());
        for (int i = 0; i < raw.length(); i++) {
            char c = raw.charAt(i);
            if (c < 0x20 || "\\/:*?\"<>|".indexOf(c) >= 0) {
                sb.append(' ');
            } else {
                sb.append(c);
            }
        }
        return sb.toString().replaceAll("\\s{2,}", " ").trim();
    }

    /** 冲突时的候选名：`名 (2).mp3`。 */
    public static String withIndex(String name, int index) {
        if (name == null || name.isEmpty()) {
            return name;
        }
        int dot = name.lastIndexOf('.');
        String stem = dot > 0 ? name.substring(0, dot) : name;
        String ext = dot > 0 ? name.substring(dot) : "";
        return stem + " (" + index + ")" + ext;
    }

    /** 把模板拆成「前缀/占位符/字面量」便于界面说明（保留给将来高亮用）。 */
    public static List<String> tokens(String pattern) {
        List<String> out = new ArrayList<String>();
        String p = pattern == null ? "" : pattern;
        int i = 0;
        while (i < p.length()) {
            int open = p.indexOf('{', i);
            if (open < 0) {
                out.add(p.substring(i));
                break;
            }
            if (open > i) {
                out.add(p.substring(i, open));
            }
            int close = p.indexOf('}', open + 1);
            if (close < 0) {
                out.add(p.substring(open));
                break;
            }
            out.add(p.substring(open, close + 1));
            i = close + 1;
        }
        return out;
    }

    private static String valueOf(String token, Map<String, String> f, String ext) {
        if (token.isEmpty()) {
            return "";
        }
        String key = token.toLowerCase(Locale.US);
        if (key.equals("ext")) {
            return ext;
        }
        int colon = key.indexOf(':');
        if (colon > 0) {
            String base = key.substring(0, colon);
            String arg = key.substring(colon + 1).trim();
            String v = f.containsKey(base) ? f.get(base) : "";
            if (base.equals("track")) {
                try {
                    return padTrack(v, Integer.parseInt(arg));
                } catch (Exception ignored) {
                    return padTrack(v);
                }
            }
            return v;
        }
        if (key.equals("track")) {
            return padTrack(f.containsKey("track") ? f.get("track") : "");
        }
        String v = f.containsKey(key) ? f.get(key) : "";
        return v == null ? "" : v;
    }

    private static String safe(String v) {
        return v == null ? "" : v.trim();
    }
}
