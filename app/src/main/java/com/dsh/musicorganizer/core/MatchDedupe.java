package com.dsh.musicorganizer.core;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

/**
 * 多源候选合并（v0.1.80）。
 *
 * <p>同一首歌在网易、QQ、酷狗都会返回，聚合后列表里就出现三条一模一样的条目 ——
 * 用户看不出区别，预览还更长。这里按「标题 + 艺人 + 时长」判同一首，合并成一条，
 * 保留置信度最高的那条，并记下「几源命中」（多源一致本身是可信度信号）。
 *
 * <p>纯逻辑，进桌面 JVM 回归（{@code tools/MatchDedupeTest}）。
 */
public final class MatchDedupe {

    /** 同一首的时长容差（秒）：VBR 文件与平台给出的时长常有 1~2 秒偏差。 */
    public static final double DURATION_TOLERANCE = 2.0;

    /** 一条候选（由调用方从自己的数据结构映射过来，{@code payload} 原样带回）。 */
    public static final class Entry {
        public String title = "";
        public String artist = "";
        public Double duration = null;
        public double score = 0;
        /** 来源显示名，如「网易云」 */
        public String source = "";
        /** 合并后命中的来源数 */
        public int merged = 1;
        /** 合并后命中的来源串，如「网易云 / QQ」 */
        public String sources = "";
        /** 原始对象，合并完由调用方取回 */
        public Object payload;
    }

    private MatchDedupe() {
    }

    /**
     * 合并同一首的候选。
     *
     * @return 合并后的列表，按「置信度降序、命中源数降序」排好
     */
    public static List<Entry> merge(List<Entry> input) {
        List<Entry> groups = new ArrayList<Entry>();
        if (input == null || input.isEmpty()) {
            return groups;
        }
        for (Entry e : input) {
            if (e == null) {
                continue;
            }
            Entry hit = null;
            for (Entry g : groups) {
                if (same(g, e)) {
                    hit = g;
                    break;
                }
            }
            if (hit == null) {
                Entry g = new Entry();
                g.title = e.title;
                g.artist = e.artist;
                g.duration = e.duration;
                g.score = e.score;
                g.source = e.source;
                g.payload = e.payload;
                g.merged = 1;
                g.sources = e.source == null ? "" : e.source;
                groups.add(g);
            } else {
                hit.merged++;
                hit.sources = join(hit.sources, e.source);
                if (e.score > hit.score) {
                    // 换代表：分数更高的那条更像正确答案
                    hit.score = e.score;
                    hit.source = e.source;
                    hit.payload = e.payload;
                    if (e.duration != null) {
                        hit.duration = e.duration;
                    }
                    if (!e.title.isEmpty()) {
                        hit.title = e.title;
                    }
                    if (!e.artist.isEmpty()) {
                        hit.artist = e.artist;
                    }
                }
            }
        }
        // 置信度优先，其次看几家一致
        java.util.Collections.sort(groups, new java.util.Comparator<Entry>() {
            @Override
            public int compare(Entry a, Entry b) {
                int c = Double.compare(b.score, a.score);
                if (c != 0) {
                    return c;
                }
                return Integer.compare(b.merged, a.merged);
            }
        });
        return groups;
    }

    /** 判同：标题像、艺人像、时长接近（未知时长视为「不阻挡」）。 */
    public static boolean same(Entry a, Entry b) {
        if (a == null || b == null) {
            return false;
        }
        if (!titleLike(a.title, b.title)) {
            return false;
        }
        if (!artistLike(a.artist, b.artist)) {
            return false;
        }
        if (a.duration != null && b.duration != null) {
            return Math.abs(a.duration - b.duration) <= DURATION_TOLERANCE;
        }
        return true;
    }

    private static boolean titleLike(String a, String b) {
        String x = titleKey(a);
        String y = titleKey(b);
        if (x.isEmpty() || y.isEmpty()) {
            return x.equals(y);
        }
        if (x.equals(y)) {
            return true;
        }
        return TextUtil.smartSimilarity(x, y) >= 0.90;
    }



    /**
     * 标题比较用的键：归一之后再去掉分隔符与空白。
     *
     * <p>「测试-标题」和「测试 标题」在平台上很常见，直接比相似度会擦着 0.90 掉下去，
     * 结果同一首歌被拆成两条。去掉 {@code - · — – _} 与空白之后再比就稳了。
     */
    static String titleKey(String s) {
        return TextUtil.normCompare(s).replaceAll("[-·—–_\\s]+", "");
    }

    private static boolean artistLike(String a, String b) {
        String x = TextUtil.normCompare(a);
        String y = TextUtil.normCompare(b);
        if (x.isEmpty() || y.isEmpty()) {
            // 一方没写艺人：只要标题对得上就认（平台常见缺艺人）
            return true;
        }
        if (x.equals(y)) {
            return true;
        }
        return TextUtil.smartSimilarity(x, y) >= 0.82;
    }

    private static String join(String acc, String add) {
        Set<String> set = new LinkedHashSet<String>();
        for (String part : split(acc)) {
            set.add(part);
        }
        for (String part : split(add)) {
            if (!part.isEmpty()) {
                set.add(part);
            }
        }
        StringBuilder sb = new StringBuilder();
        for (String s : set) {
            if (sb.length() > 0) {
                sb.append(" / ");
            }
            sb.append(s);
        }
        return sb.toString();
    }

    private static List<String> split(String s) {
        List<String> out = new ArrayList<String>();
        if (s == null || s.isEmpty()) {
            return out;
        }
        for (String part : s.split("\\s*/\\s*")) {
            String t = part.trim();
            if (!t.isEmpty()) {
                out.add(t);
            }
        }
        return out;
    }
}
