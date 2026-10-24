package com.dsh.musicorganizer.core;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * 搜索输入解析：把一行文本变成「词 + 字段条件 + 大小条件」。
 *
 * <p>设计目标是把常见的搜索维度都覆盖，但不占界面：
 * <pre>
 *   周杰伦 晴天            → 两个词，全部命中（AND）
 *   artist:周杰伦          → 只搜艺人
 *   title:晴天 album:叶惠美 → 多字段同时成立
 *   ext:flac size:&gt;10m    → 扩展名 + 大小比较（单位 k/m/g，也可直接写字节）
 *   "晴天 2004"            → 引号内当一个词（允许带空格）
 * </pre>
 * 未知前缀（例如 {@code http://x}）按普通词处理，不会把整条查询吃掉。
 *
 * <p>纯逻辑、无安卓依赖，桌面 JVM 可直接跑测试。
 */
public final class SearchQuery {

    /** 支持的字段名（也是中文别名的目标）。 */
    public static final String[] FIELDS = {
            "title", "artist", "album", "genre", "comment", "lyrics", "path", "ext", "year",
    };

    private static final Map<String, String> ALIASES = new HashMap<String, String>();

    static {
        alias("title", "标题", "歌名", "曲名", "name");
        alias("artist", "艺术家", "歌手", "艺人", "singer");
        alias("album", "专辑", "唱片");
        alias("genre", "流派", "风格", "类型");
        alias("comment", "注释", "备注", "comment");
        alias("lyrics", "歌词", "lrc");
        alias("path", "路径", "目录", "dir", "folder");
        alias("ext", "后缀", "格式", "扩展名", "type");
        alias("year", "年份", "年代", "date");
        alias("size", "大小", "体积");
    }

    private static void alias(String field, String... names) {
        // 英文规范名本身也要能当前缀用（artist:xxx），不能只登记中文别名
        ALIASES.put(field, field);
        for (String n : names) {
            ALIASES.put(n, field);
        }
    }

    /** 归一后的检索词（用于匹配）。 */
    public final List<String> terms = new ArrayList<String>();
    /** 原始检索词（大小写/繁简不动，用于界面高亮）。 */
    public final List<String> raw = new ArrayList<String>();
    /** 字段条件：字段名 → 归一后的值。 */
    public final Map<String, String> fields = new LinkedHashMap<String, String>();
    /** 大小下限 / 上限，-1 表示不限。 */
    public long minSize = -1;
    public long maxSize = -1;
    /** 原始输入（界面上回显用）。 */
    public final String source;

    private SearchQuery(String source) {
        this.source = source == null ? "" : source;
    }

    public boolean isEmpty() {
        return terms.isEmpty() && fields.isEmpty() && minSize < 0 && maxSize < 0;
    }

    /** 是否带了「字段条件」（决定要不要提示「标签还没读完」）。 */
    public boolean hasFieldFilter() {
        return !fields.isEmpty();
    }

    public static SearchQuery parse(String rawText) {
        SearchQuery q = new SearchQuery(rawText);
        if (rawText == null) {
            return q;
        }
        for (String token : tokenize(rawText)) {
            String t = token.trim();
            if (t.isEmpty()) {
                continue;
            }
            int colon = t.indexOf(':');
            if (colon > 0 && colon < t.length() - 1) {
                String prefix = t.substring(0, colon).toLowerCase(Locale.ROOT);
                String field = ALIASES.get(prefix);
                String value = t.substring(colon + 1).trim();
                if (field != null && !value.isEmpty()) {
                    if ("size".equals(field)) {
                        q.applySize(value);
                    } else {
                        q.fields.put(field, norm(value));
                    }
                    continue;
                }
            }
            q.terms.add(norm(t));
            q.raw.add(t);
        }
        return q;
    }

    private void applySize(String value) {
        String v = value.trim().toLowerCase(Locale.ROOT);
        String op = "";
        if (v.startsWith(">=") || v.startsWith("<=") || v.startsWith(">")
                || v.startsWith("<") || v.startsWith("=")) {
            int i = 0;
            while (i < v.length() && (v.charAt(i) == '>' || v.charAt(i) == '<' || v.charAt(i) == '=')) {
                i++;
            }
            op = v.substring(0, i);
            v = v.substring(i).trim();
        }
        long bytes = parseBytes(v);
        if (bytes < 0) {
            return;
        }
        if (">".equals(op)) {
            minSize = bytes + 1;
        } else if (">=".equals(op)) {
            minSize = bytes;
        } else if ("<".equals(op)) {
            maxSize = bytes - 1;
        } else if ("<=".equals(op)) {
            maxSize = bytes;
        } else {
            // "=" 或无比较符：允许 ±10% 的浮动，避免 10.0 MB 与 10485760 对不上
            minSize = (long) (bytes * 0.9);
            maxSize = (long) (bytes * 1.1);
        }
    }

    /** "10m" / "1.5g" / "800k" / "4096" → 字节；解析失败返回 -1。 */
    public static long parseBytes(String v) {
        if (v.isEmpty()) {
            return -1;
        }
        char last = v.charAt(v.length() - 1);
        long unit = 1;
        String num = v;
        if (last == 'k' || last == 'm' || last == 'g' || last == 'b') {
            num = v.substring(0, v.length() - 1);
            if (last == 'k') {
                unit = 1024L;
            } else if (last == 'm') {
                unit = 1024L * 1024L;
            } else if (last == 'g') {
                unit = 1024L * 1024L * 1024L;
            }
        }
        try {
            double d = Double.parseDouble(num);
            if (d < 0) {
                return -1;
            }
            return (long) (d * unit);
        } catch (NumberFormatException e) {
            return -1;
        }
    }

    /** 按空白切词，支持双引号（含中文引号）把带空格的内容并成一个词。 */
    static List<String> tokenize(String text) {
        List<String> out = new ArrayList<String>();
        StringBuilder cur = new StringBuilder();
        boolean quoted = false;
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            if (c == '"' || c == '\u201c' || c == '\u201d') {
                quoted = !quoted;
                continue;
            }
            if (!quoted && Character.isWhitespace(c)) {
                if (cur.length() > 0) {
                    out.add(cur.toString());
                    cur.setLength(0);
                }
                continue;
            }
            cur.append(c);
        }
        if (cur.length() > 0) {
            out.add(cur.toString());
        }
        return out;
    }

    /**
     * 归一：繁转简 + 只保留字母数字（去掉空格、标点、括号）+ 小写。
     * 这样「周杰伦-晴天」与「周杰伦 晴天」在字段条件里等价。
     */
    public static String norm(String s) {
        if (s == null) {
            return "";
        }
        String simplified = TextUtil.toSimplified(s).toLowerCase(Locale.ROOT);
        StringBuilder sb = new StringBuilder(simplified.length());
        for (int i = 0; i < simplified.length(); i++) {
            char c = simplified.charAt(i);
            if (Character.isLetterOrDigit(c)) {
                sb.append(c);
            }
        }
        return sb.toString();
    }

    /** 描述当前查询（用于「N 首匹配 · 条件：艺人=周杰伦」这类回显）。 */
    public String describe() {
        StringBuilder sb = new StringBuilder();
        for (String t : raw) {
            if (sb.length() > 0) {
                sb.append(' ');
            }
            sb.append(t);
        }
        for (Map.Entry<String, String> e : fields.entrySet()) {
            if (sb.length() > 0) {
                sb.append(' ');
            }
            sb.append(e.getKey()).append(':').append(e.getValue());
        }
        if (minSize >= 0) {
            sb.append(" size>=").append(minSize);
        }
        if (maxSize >= 0) {
            sb.append(" size<=").append(maxSize);
        }
        return sb.toString().trim();
    }
}
