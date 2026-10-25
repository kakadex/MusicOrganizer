package com.dsh.musicorganizer.core;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * 标签文本的本地批量修正（v0.1.80）。
 *
 * <p>跟「联网匹配」无关：这里只把已经写在文件里的文本整理干净 —— 去首尾空格、
 * 折叠多余空格、全角转半角、音轨号补零。纯函数，进桌面 JVM 回归
 * （{@code tools/TagFixTest}）。
 */
public final class TagFix {

    /** 去首尾空白。 */
    public static final int TRIM = 1;
    /** 把连续空格/制表符折叠成一个空格。 */
    public static final int SPACES = 2;
    /** 全角字母数字标点 → 半角（中文汉字不动）。 */
    public static final int WIDTH = 4;
    /** 音轨号补零：{@code 1} → {@code 01}，{@code 1/12} → {@code 01/12}。 */
    public static final int TRACK = 8;

    /** 会被处理的字段（与标签编辑器里的六个候选字段一致）。 */
    public static final String[] FIELDS = {
            "title", "artist", "album", "year", "track", "genre",
    };

    private TagFix() {
    }

    /** 对一个值做指定修正；{@code ops} 为 0 或值本来就是干净的，返回原串。 */
    public static String clean(String value, int ops) {
        if (value == null || value.isEmpty() || ops == 0) {
            return value == null ? "" : value;
        }
        String s = value;
        if ((ops & WIDTH) != 0) {
            s = fullToHalf(s);
        }
        if ((ops & SPACES) != 0) {
            s = collapseSpaces(s);
        }
        if ((ops & TRIM) != 0) {
            s = s.trim();
        }
        return s;
    }

    /** 音轨号补零。已经是两位以上、或不是纯数字（{@code 1/12} 的分子单独处理）就原样返回。 */
    public static String track(String value) {
        if (value == null || value.isEmpty()) {
            return "";
        }
        String v = value.trim();
        int slash = v.indexOf('/');
        if (slash > 0) {
            return pad(v.substring(0, slash).trim()) + "/" + v.substring(slash + 1).trim();
        }
        return pad(v);
    }

    /**
     * 算出「这条标签需要改哪些字段」。
     *
     * @param tags 当前标签
     * @param ops  见 {@link #TRIM} 等
     * @return 需要写入的字段 → 新值；没有变化时为空 map（调用方据此跳过写盘）
     */
    public static Map<String, String> plan(Tags tags, int ops) {
        Map<String, String> out = new LinkedHashMap<String, String>();
        if (tags == null) {
            return out;
        }
        for (String f : FIELDS) {
            String old = tags.get(f);
            if (old.isEmpty()) {
                continue;
            }
            String now = "track".equals(f)
                    ? cleanAndTrack(old, ops)
                    : clean(old, ops);
            if (!now.equals(old)) {
                out.put(f, now);
            }
        }
        return out;
    }

    private static String cleanAndTrack(String value, int ops) {
        String s = clean(value, ops & ~TRACK);
        if ((ops & TRACK) != 0) {
            s = track(s);
        }
        return s;
    }

    /** 全角（FF01–FF5E、U+3000）转半角，其它字符（含汉字）原样保留。 */
    public static String fullToHalf(String s) {
        if (s == null || s.isEmpty()) {
            return "";
        }
        StringBuilder sb = new StringBuilder(s.length());
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == '\u3000') {
                sb.append(' ');
            } else if (c >= '\uFF01' && c <= '\uFF5E') {
                sb.append((char) (c - 0xFEE0));
            } else {
                sb.append(c);
            }
        }
        return sb.toString();
    }

    /** 连续空白折叠成一个空格（行内的中文之间不加空格）。 */
    public static String collapseSpaces(String s) {
        if (s == null || s.isEmpty()) {
            return "";
        }
        StringBuilder sb = new StringBuilder(s.length());
        boolean lastSpace = false;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            boolean space = c == ' ' || c == '\t' || c == '\u3000';
            if (space) {
                if (!lastSpace) {
                    sb.append(' ');
                }
                lastSpace = true;
            } else {
                sb.append(c);
                lastSpace = false;
            }
        }
        return sb.toString();
    }

    private static String pad(String num) {
        if (num.isEmpty()) {
            return num;
        }
        for (int i = 0; i < num.length(); i++) {
            if (num.charAt(i) < '0' || num.charAt(i) > '9') {
                return num;      // 不是纯数字（如 "A1"、"0-9"）不碰
            }
        }
        if (num.length() == 1) {
            return "0" + num;
        }
        return num;
    }
}
