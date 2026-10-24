package com.dsh.musicorganizer.core;

import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * 文件名解析 —— 对应 Python 版 core.py 的「文件名解析」部分。
 *
 * strip_name_noise / split_artist_title（居中分隔符优先、双向识别）/ 候选生成。
 */
public final class NameParser {

    private NameParser() {
    }

    private static final Pattern DASH_RE =
            Pattern.compile("\\s*(?:-|–|—|－|~|～)\\s*");

    public static class Split {
        public final String left;
        public final String right;
        public final String style;

        public Split(String left, String right, String style) {
            this.left = left;
            this.right = right;
            this.style = style;
        }
    }

    public static class Candidate {
        public final String artist; // 可能为 null
        public final String title;
        public final String style;

        public Candidate(String artist, String title, String style) {
            this.artist = artist;
            this.title = title;
            this.style = style;
        }

        @Override
        public boolean equals(Object o) {
            if (!(o instanceof Candidate)) {
                return false;
            }
            Candidate c = (Candidate) o;
            String a = TextUtil.normCompare(artist == null ? "" : artist);
            String b = TextUtil.normCompare(c.artist == null ? "" : c.artist);
            return a.equals(b) && TextUtil.normCompare(title).equals(TextUtil.normCompare(c.title));
        }

        @Override
        public int hashCode() {
            return TextUtil.normCompare(title).hashCode() * 31
                    + TextUtil.normCompare(artist == null ? "" : artist).hashCode();
        }
    }

    /** 去污染后缀 + 轨道前缀 + 首尾书名号/方括号。 */
    public static String stripNameNoise(String stem) {
        String text = TextUtil.stripTrailingNumericSuffix(stem == null ? "" : stem.trim());
        text = TextUtil.stripTrackPrefix(text).trim();
        if (text.length() >= 2
                && ((text.charAt(0) == '[' && text.charAt(text.length() - 1) == ']')
                || (text.charAt(0) == '《' && text.charAt(text.length() - 1) == '》'))) {
            text = text.substring(1, text.length() - 1).trim();
        }
        return text;
    }

    /** 拆分为 (左, 右, 风格)。居中分隔符优先；无分隔符返回 null。 */
    public static Split splitArtistTitle(String stem) {
        String text = stripNameNoise(stem);
        Matcher m = DASH_RE.matcher(text);
        List<int[]> ranges = new ArrayList<int[]>();
        while (m.find()) {
            ranges.add(new int[]{m.start(), m.end()});
        }
        if (ranges.isEmpty()) {
            return null;
        }
        double center = text.length() / 2.0;
        int[] chosen = null;
        double best = Double.NEGATIVE_INFINITY;
        for (int[] r : ranges) {
            String left = text.substring(0, r[0]).trim();
            String right = text.substring(r[1]).trim();
            if (left.isEmpty() || right.isEmpty()) {
                continue;
            }
            double score = -Math.abs((r[0] + r[1]) / 2.0 - center);
            if (score > best) {
                best = score;
                chosen = r;
            }
        }
        if (chosen == null) {
            return null;
        }
        boolean spaced = Pattern.compile("\\s[-–—－~～]\\s").matcher(text).find();
        return new Split(
                text.substring(0, chosen[0]).trim(),
                text.substring(chosen[1]).trim(),
                spaced ? "F1" : "F3");
    }

    /** 文件名候选：有分隔符时给出双向两个候选，否则单段歌名。 */
    public static List<Candidate> nameCandidates(String stem) {
        String normalized = stripNameNoise(stem);
        List<Candidate> out = new ArrayList<Candidate>();
        if (normalized.isEmpty()) {
            return out;
        }
        Split split = splitArtistTitle(stem);
        if (split != null) {
            String reverse = split.style.equals("F1") ? "F2" : "F4";
            out.add(new Candidate(split.left, split.right, split.style));
            out.add(new Candidate(split.right, split.left, reverse));
        } else {
            out.add(new Candidate(null, normalized, "F5/F6"));
        }
        return out;
    }

    /** 文件名解析结果 → (artist, title) 对，供聚合器与歌词匹配使用。 */
    public static List<String[]> candidatePairs(String stem) {
        List<String[]> pairs = new ArrayList<String[]>();
        for (Candidate c : nameCandidates(stem)) {
            String artist = c.artist == null ? "" : c.artist.trim();
            String title = c.title == null ? "" : c.title.trim();
            if (!title.isEmpty() && !containsPair(pairs, artist, title)) {
                pairs.add(new String[]{artist, title});
            }
        }
        return pairs;
    }

    private static boolean containsPair(List<String[]> pairs, String artist, String title) {
        for (String[] p : pairs) {
            if (p[0].equals(artist) && p[1].equals(title)) {
                return true;
            }
        }
        return false;
    }
}
