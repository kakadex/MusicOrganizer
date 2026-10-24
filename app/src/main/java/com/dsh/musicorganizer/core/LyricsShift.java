package com.dsh.musicorganizer.core;

import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * 歌词时间轴整体偏移。
 *
 * <p>常见场景：歌词来自别的版本，整体快/慢半秒到一秒；或者自己唱的录音比歌词早。以前只能在
 * 电脑上用工具改，手机上没办法。这里把**所有时间戳**（行首 {@code [mm:ss.xx]} 与逐字
 * {@code <mm:ss.xx>}）统一加减同一个毫秒数。
 *
 * <p>几条约定：
 * <ul>
 *   <li>只动真正的数字时间戳，{@code [ar:歌手]}、{@code [ti:标题]} 这类元信息原样保留；</li>
 *   <li>偏移后小于 0 的钳到 0（负时间播放器不认）；</li>
 *   <li>保留原来的小数位数（两位就还是两位），不把 {@code [00:12.30]} 写成 {@code [00:12.3]}；</li>
 *   <li>一行多个时间戳（同一句重复出现）全部一起偏移。</li>
 * </ul>
 */
public final class LyricsShift {

    /** 只匹配「数字时间戳」：方括号是行时间，尖括号是逐字时间。 */
    private static final Pattern STAMP = Pattern.compile(
            "([\\[<])(\\d{1,3}):(\\d{1,2})(?:[.:](\\d{1,3}))?([\\]>])");

    private LyricsShift() {
    }

    /** 偏移全部时间戳；{@code deltaMs} 为正表示整体往后推。 */
    public static String shift(String lrc, long deltaMs) {
        if (lrc == null || lrc.isEmpty() || deltaMs == 0) {
            return lrc == null ? "" : lrc;
        }
        Matcher m = STAMP.matcher(lrc);
        StringBuffer sb = new StringBuffer(lrc.length() + 16);
        int last = 0;
        while (m.find()) {
            sb.append(lrc, last, m.start());
            sb.append(format(m, deltaMs));
            last = m.end();
        }
        sb.append(lrc, last, lrc.length());
        return sb.toString();
    }

    /** 有多少个时间戳（判断值不值得偏移、界面提示用）。 */
    public static int count(String lrc) {
        if (lrc == null || lrc.isEmpty()) {
            return 0;
        }
        int n = 0;
        Matcher m = STAMP.matcher(lrc);
        while (m.find()) {
            n++;
        }
        return n;
    }

    /** 第一个时间戳（毫秒），没有返回 -1。 */
    public static long firstStamp(String lrc) {
        if (lrc == null || lrc.isEmpty()) {
            return -1;
        }
        Matcher m = STAMP.matcher(lrc);
        if (!m.find()) {
            return -1;
        }
        return millisOf(m);
    }

    /** 最后一个时间戳（毫秒），没有返回 -1。 */
    public static long lastStamp(String lrc) {
        if (lrc == null || lrc.isEmpty()) {
            return -1;
        }
        Matcher m = STAMP.matcher(lrc);
        long v = -1;
        while (m.find()) {
            v = millisOf(m);
        }
        return v;
    }

    /** 偏移后是否会全部归零（说明偏移量比歌词本身还大，提示用户）。 */
    public static boolean collapsesToZero(String lrc, long deltaMs) {
        long first = firstStamp(lrc);
        return first >= 0 && first + deltaMs <= 0;
    }

    private static String format(Matcher m, long deltaMs) {
        long t = millisOf(m) + deltaMs;
        if (t < 0) {
            t = 0;
        }
        long totalSec = t / 1000;
        long min = totalSec / 60;
        long sec = totalSec % 60;
        long ms = t % 1000;
        String frac = m.group(4);
        StringBuilder out = new StringBuilder(12);
        out.append(m.group(1));
        out.append(pad(min, 2)).append(':').append(pad(sec, 2));
        if (frac != null && !frac.isEmpty()) {
            out.append('.');
            if (frac.length() == 1) {
                out.append(ms / 100);
            } else if (frac.length() == 2) {
                out.append(pad(ms / 10, 2));
            } else {
                out.append(pad(ms, 3));
            }
        }
        out.append(m.group(5));
        return out.toString();
    }

    private static long millisOf(Matcher m) {
        long min = Long.parseLong(m.group(2));
        long sec = Long.parseLong(m.group(3));
        String frac = m.group(4);
        long ms = 0;
        if (frac != null && !frac.isEmpty()) {
            if (frac.length() == 1) {
                ms = Long.parseLong(frac) * 100;
            } else if (frac.length() == 2) {
                ms = Long.parseLong(frac) * 10;
            } else {
                ms = Long.parseLong(frac);
            }
        }
        return min * 60000 + sec * 1000 + ms;
    }

    private static String pad(long value, int width) {
        StringBuilder sb = new StringBuilder(Long.toString(Math.max(0, value)));
        while (sb.length() < width) {
            sb.insert(0, '0');
        }
        return sb.toString();
    }
}
