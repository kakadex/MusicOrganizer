package com.dsh.musicorganizer.core;

import java.util.ArrayList;
import java.util.List;

/**
 * 歌词时间轴 → 当前行/逐字进度的纯计算（v0.1.37 歌词查看器用）。
 *
 * <p>没有播放器也能「对歌词」：给定一个毫秒位置，算出应该高亮哪一行、这一行读到第几个字、
 * 百分之几。逐字时间来自增强型 LRC 的 {@code <mm:ss.xx>}（{@link LyricsDoc.Line#words}）。
 *
 * <p>刻意不依赖 Android：界面层只负责计时与滚动，判定逻辑全部在这里，方便回归。
 */
public final class LyricsTimeline {

    private LyricsTimeline() {
    }

    /**
     * 当前位置应高亮的行（{@code lines} 需按时间升序）。
     *
     * @return 行下标；还没到第一行返回 -1；超出最后一行返回最后一行下标
     */
    public static int lineIndexAt(List<LyricsDoc.Line> lines, long ms) {
        if (lines == null || lines.isEmpty()) {
            return -1;
        }
        int lo = 0;
        int hi = lines.size() - 1;
        int found = -1;
        while (lo <= hi) {
            int mid = (lo + hi) >>> 1;
            if (lines.get(mid).timeMs <= ms) {
                found = mid;
                lo = mid + 1;
            } else {
                hi = mid - 1;
            }
        }
        return found;
    }

    /**
     * 当前行读到了第几个字（逐字词的下标）。
     *
     * @return 0 表示还没读到第一个字；等于词数表示这一行读完；没有逐字信息返回 -1
     */
    public static int wordIndexAt(LyricsDoc.Line line, long ms) {
        if (line == null || line.words == null || line.words.isEmpty()) {
            return -1;
        }
        int idx = 0;
        for (int i = 0; i < line.words.size(); i++) {
            if (line.words.get(i).timeMs <= ms) {
                idx = i + 1;
            } else {
                break;
            }
        }
        return idx;
    }

    /**
     * 当前行进度（0~1）：按逐字时间插值；没有逐字信息时退回「行开始到下一行开始」的线性进度。
     *
     * @param nextLineMs 下一行的开始时间（最后一行的下一行用 {@code lineEndMs}）
     */
    public static double progressAt(LyricsDoc.Line line, long ms, long nextLineMs) {
        if (line == null) {
            return 0;
        }
        int words = line.words == null ? 0 : line.words.size();
        if (words > 0) {
            int idx = wordIndexAt(line, ms);
            if (idx <= 0) {
                return 0;
            }
            if (idx >= words) {
                // 最后一个字已经开口：用「最后一字到下一行」的时长估它念完的比例
                long lastStart = line.words.get(words - 1).timeMs;
                if (nextLineMs <= lastStart) {
                    return 1;
                }
                double tail = (ms - lastStart) * 1.0 / (nextLineMs - lastStart);
                if (tail < 0) {
                    tail = 0;
                }
                if (tail > 1) {
                    tail = 1;
                }
                return ((words - 1) + tail) / words;
            }
            long wordStart = line.words.get(idx - 1).timeMs;
            long wordEnd = line.words.get(idx).timeMs;
            if (wordEnd <= wordStart) {
                return 1;
            }
            double frac = (ms - wordStart) * 1.0 / (wordEnd - wordStart);
            if (frac < 0) {
                frac = 0;
            }
            if (frac > 1) {
                frac = 1;
            }
            return (idx - 1 + frac) / words;
        }
        if (nextLineMs <= line.timeMs) {
            // 下一行和这一行同点（或没给下一行时间）：只在真正越过之后算读完
            return ms > line.timeMs ? 1 : 0;
        }
        double p = (ms - line.timeMs) * 1.0 / (nextLineMs - line.timeMs);
        if (p < 0) {
            p = 0;
        }
        if (p > 1) {
            p = 1;
        }
        return p;
    }

    /** 最后一行的时间（判断「唱完了」用）；空返回 -1。 */
    public static long lastTime(List<LyricsDoc.Line> lines) {
        if (lines == null || lines.isEmpty()) {
            return -1;
        }
        return lines.get(lines.size() - 1).timeMs;
    }

    /** 逐字歌词的行数（界面提示「其中 N 行带逐字时间」）。 */
    public static int enhancedLineCount(List<LyricsDoc.Line> lines) {
        int n = 0;
        if (lines == null) {
            return 0;
        }
        for (LyricsDoc.Line l : lines) {
            if (l.words != null && !l.words.isEmpty()) {
                n++;
            }
        }
        return n;
    }

    /** 按时间排序后的副本（传入的可能是按文件顺序，多时间戳行会乱）。 */
    public static List<LyricsDoc.Line> sortedCopy(List<LyricsDoc.Line> lines) {
        List<LyricsDoc.Line> out = new ArrayList<LyricsDoc.Line>();
        if (lines != null) {
            out.addAll(lines);
        }
        java.util.Collections.sort(out, new java.util.Comparator<LyricsDoc.Line>() {
            @Override
            public int compare(LyricsDoc.Line a, LyricsDoc.Line b) {
                int c = Long.compare(a.timeMs, b.timeMs);
                return c != 0 ? c : Integer.compare(a.order, b.order);
            }
        });
        return out;
    }

    /** {@code mm:ss} 显示（查看器左侧时间列）。 */
    public static String stamp(long ms) {
        long s = Math.max(0, ms) / 1000;
        return String.format(java.util.Locale.US, "%02d:%02d", s / 60, s % 60);
    }

    /** 当前位置的说明文字：「第 3/48 行 · 逐字 40%」。 */
    public static String statusText(List<LyricsDoc.Line> lines, long ms) {
        int idx = lineIndexAt(lines, ms);
        if (idx < 0) {
            return "还没开始（" + stamp(ms) + "）";
        }
        long next = idx + 1 < lines.size() ? lines.get(idx + 1).timeMs : lines.get(idx).timeMs + 5000;
        double p = progressAt(lines.get(idx), ms, next);
        return "第 " + (idx + 1) + "/" + lines.size() + " 行 · "
                + Math.round(p * 100) + "% · " + stamp(ms);
    }
}
