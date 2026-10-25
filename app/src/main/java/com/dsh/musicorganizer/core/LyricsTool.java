package com.dsh.musicorganizer.core;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * 歌词文本的本地处理工具（v0.1.80）。
 *
 * <p>只做**纯文本**变换：不联网、不碰文件、不改时间轴含义。界面上是一组可勾选的动作
 * （删空行 / 去头部标签 / 去时间轴 / 规范时间轴 / 去重复行），单曲和批量共用同一套。
 *
 * <p>为什么不并进 {@link Lyrics}：那边管的是「查 / 匹配 / 写入」这条流程，体量大；
 * 这里全是纯函数，能直接进桌面 JVM 回归（{@code tools/LyricsToolTest}）。
 */
public final class LyricsTool {

    /** 动作位（界面勾选项与这里的常量一一对应）。 */
    public static final int OP_EMPTY = 1;
    public static final int OP_HEADER = 2;
    public static final int OP_TIMESTAMP = 4;
    public static final int OP_NORMALIZE = 8;
    public static final int OP_DEDUPE = 16;

    /** 时间轴：{@code [mm:ss]} / {@code [mm:ss.xx]} / {@code [mm:ss.xxx]} / {@code [h:mm:ss.xx]}。 */
    private static final Pattern TIME_TAG = Pattern.compile(
            "\\[(\\d{1,2}):(\\d{1,2})(?:[.:](\\d{1,3}))?\\]");

    /** LRC 头部元信息：{@code [ti:...]} / {@code [ar:...]} / {@code [offset:0]} 这类。 */
    private static final Pattern HEADER_TAG = Pattern.compile(
            "\\[(ti|ar|al|au|by|offset|re|ve|length|tool|encoding)\\s*:[^\\]]*\\]",
            Pattern.CASE_INSENSITIVE);

    private LyricsTool() {
    }

    /** 统一换行、去掉 UTF-8 BOM、行尾空格。 */
    public static String normalize(String text) {
        if (text == null || text.isEmpty()) {
            return "";
        }
        String s = text;
        if (s.startsWith("\uFEFF")) {
            s = s.substring(1);
        }
        s = s.replace("\r\n", "\n").replace('\r', '\n');
        StringBuilder sb = new StringBuilder(s.length());
        String[] lines = s.split("\n", -1);
        for (int i = 0; i < lines.length; i++) {
            if (i > 0) {
                sb.append('\n');
            }
            sb.append(rtrim(lines[i]));
        }
        return sb.toString();
    }

    /** 删空行（只含空白也算空）。 */
    public static String stripEmptyLines(String text) {
        String s = normalize(text);
        if (s.isEmpty()) {
            return "";
        }
        StringBuilder sb = new StringBuilder(s.length());
        for (String line : s.split("\n", -1)) {
            if (line.trim().isEmpty()) {
                continue;
            }
            if (sb.length() > 0) {
                sb.append('\n');
            }
            sb.append(line);
        }
        return sb.toString();
    }

    /** 去掉 {@code [ti:][ar:][al:][by:][offset:]} 这类头部元信息（整行都是标签的才删）。 */
    public static String stripHeaders(String text) {
        String s = normalize(text);
        if (s.isEmpty()) {
            return "";
        }
        StringBuilder sb = new StringBuilder(s.length());
        for (String line : s.split("\n", -1)) {
            String rest = HEADER_TAG.matcher(line).replaceAll("").trim();
            if (rest.isEmpty()) {
                continue;   // 整行都是元信息 → 丢掉
            }
            if (sb.length() > 0) {
                sb.append('\n');
            }
            sb.append(line);
        }
        return sb.toString();
    }

    /**
     * 去掉时间轴，只留纯文本（用于「把歌词当文本贴给别人」或喂给不支持时间轴的播放器）。
     *
     * <p>一行有多个时间戳时（{@code [00:01.00][00:30.00]副歌}），只保留一次文本。
     */
    public static String stripTimestamps(String text) {
        String s = stripEmptyLines(text);
        if (s.isEmpty()) {
            return "";
        }
        StringBuilder sb = new StringBuilder(s.length());
        for (String line : s.split("\n", -1)) {
            String plain = TIME_TAG.matcher(line).replaceAll("").trim();
            if (plain.isEmpty()) {
                continue;
            }
            if (sb.length() > 0) {
                sb.append('\n');
            }
            sb.append(plain);
        }
        return sb.toString();
    }

    /**
     * 时间轴规范化：{@code [1:2.3]} → {@code [01:02.30]}，{@code [00:05]} → {@code [00:05.00]}。
     *
     * <p>各家歌词源写法不一，写进标签前统一一下，播放器才不会认错。
     */
    public static String normalizeTimestamps(String text) {
        String s = normalize(text);
        if (s.isEmpty()) {
            return "";
        }
        StringBuilder out = new StringBuilder(s.length() + 16);
        for (String line : s.split("\n", -1)) {
            if (out.length() > 0) {
                out.append('\n');
            }
            out.append(normalizeLineTags(line));
        }
        return out.toString();
    }

    /** 去掉完全重复的行（多源合并 / 二次抓取常见）。 */
    public static String dedupeLines(String text) {
        String s = normalize(text);
        if (s.isEmpty()) {
            return "";
        }
        Set<String> seen = new LinkedHashSet<String>();
        for (String line : s.split("\n", -1)) {
            if (!line.trim().isEmpty()) {
                seen.add(line);
            }
        }
        StringBuilder sb = new StringBuilder(s.length());
        for (String line : seen) {
            if (sb.length() > 0) {
                sb.append('\n');
            }
            sb.append(line);
        }
        return sb.toString();
    }

    /** 顺带统计：行数（不含空行），用来在预览里说「从 N 行变成 M 行」。 */
    public static int lineCount(String text) {
        if (text == null || text.isEmpty()) {
            return 0;
        }
        int n = 0;
        for (String line : normalize(text).split("\n", -1)) {
            if (!line.trim().isEmpty()) {
                n++;
            }
        }
        return n;
    }

    /** 一行里的所有时间戳（毫秒），按出现顺序；没有返回空列表。 */
    public static List<Long> timestamps(String line) {
        List<Long> out = new ArrayList<Long>();
        if (line == null) {
            return out;
        }
        Matcher m = TIME_TAG.matcher(line);
        while (m.find()) {
            out.add(toMillis(m.group(1), m.group(2), m.group(3)));
        }
        return out;
    }

    // ------------------------------------------------------------------

    private static String normalizeLineTags(String line) {
        Matcher m = TIME_TAG.matcher(line);
        StringBuffer sb = new StringBuffer(line.length() + 8);
        while (m.find()) {
            long ms = toMillis(m.group(1), m.group(2), m.group(3));
            m.appendReplacement(sb, Matcher.quoteReplacement(formatTag(ms)));
        }
        m.appendTail(sb);
        return sb.toString();
    }

    private static long toMillis(String min, String sec, String frac) {
        long m = parseLong(min);
        long s = parseLong(sec);
        long f = 0;
        if (frac != null && !frac.isEmpty()) {
            // 1 位 → 百毫秒，2 位 → 十毫秒，3 位 → 毫秒
            long v = parseLong(frac);
            if (frac.length() == 1) {
                f = v * 100;
            } else if (frac.length() == 2) {
                f = v * 10;
            } else {
                f = v;
            }
        }
        return m * 60000L + s * 1000L + f;
    }

    /** 毫秒 → {@code [mm:ss.xx]}；超过 1 小时用 {@code [h:mm:ss.xx]}。 */
    static String formatTag(long ms) {
        if (ms < 0) {
            ms = 0;
        }
        long totalSec = ms / 1000L;
        long centis = (ms % 1000L) / 10L;
        long h = totalSec / 3600L;
        long m = (totalSec % 3600L) / 60L;
        long s = totalSec % 60L;
        StringBuilder sb = new StringBuilder(12);
        sb.append('[');
        if (h > 0) {
            sb.append(h).append(':').append(pad2(m));
        } else {
            sb.append(pad2(m));
        }
        sb.append(':').append(pad2(s)).append('.').append(pad2(centis)).append(']');
        return sb.toString();
    }

    private static String pad2(long v) {
        return v < 10 ? "0" + v : String.valueOf(v);
    }

    private static long parseLong(String s) {
        try {
            return Long.parseLong(s);
        } catch (Exception e) {
            return 0L;
        }
    }

    private static String rtrim(String s) {
        int end = s.length();
        while (end > 0 && (s.charAt(end - 1) == ' ' || s.charAt(end - 1) == '\t')) {
            end--;
        }
        return s.substring(0, end);
    }
}
