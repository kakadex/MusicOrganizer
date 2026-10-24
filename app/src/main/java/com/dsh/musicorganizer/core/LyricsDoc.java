package com.dsh.musicorganizer.core;

import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * 歌词文档模型（只放纯逻辑，不依赖 UI 框架）。
 *
 * <p>以前歌词是「一整段字符串」直接落盘，于是三件事做不到：
 * <ol>
 *   <li><b>翻译轨</b>：网易云返回的 {@code tlyric}、QQ 返回的 {@code trans} 都被丢掉，
 *       外语歌只能看原文；</li>
 *   <li><b>元信息行清洗</b>：国内源的 LRC 常带「作词 : 某某」「OP : 某某音乐」这类无时间轴的行，
 *       播放器会把它们当歌词一直显示；</li>
 *   <li><b>质量判断</b>：只能数「有没有时间戳」，没法按行看。</li>
 * </ol>
 *
 * <p>本类定义「行 = 时间戳 + 文本」的最小模型，并提供解析、清洗、合并翻译三件事。
 * 输出仍是标准 LRC（双语就是同一时间点两行），这样任何播放器都能直接吃。
 */
public final class LyricsDoc {

    private LyricsDoc() {
    }

    /** 逐字音节（增强型 LRC 的 {@code <mm:ss.xx>字}，或 TTML 的 {@code <span>}）。 */
    public static final class Word {
        public long timeMs;
        public String text = "";

        public Word() {
        }

        public Word(long timeMs, String text) {
            this.timeMs = timeMs;
            this.text = text == null ? "" : text;
        }
    }

    /** 一行歌词。 */
    public static final class Line {
        /** 毫秒 */
        public long timeMs;
        public String text = "";
        /** 解析顺序（同一时间点多行时保持稳定） */
        public int order;
        /** 逐字时间；普通 LRC 为空表。 */
        public final List<Word> words = new ArrayList<Word>();

        public Line() {
        }

        public Line(long timeMs, String text) {
            this.timeMs = timeMs;
            this.text = text == null ? "" : text;
        }
    }

    /** {@code [mm:ss]} / {@code [mm:ss.xx]} / {@code [mm:ss.xxx]}，允许一行多个时间戳。 */
    private static final Pattern TS_RE =
            Pattern.compile("\\[(\\d{1,3}):(\\d{1,2})(?:[.:](\\d{1,3}))?\\]");

    /** 增强型 LRC 的逐字时间戳：{@code <00:12.34>}。 */
    private static final Pattern WORD_RE =
            Pattern.compile("<(\\d{1,3}):(\\d{1,2})(?:[.:](\\d{1,3}))?>");

    /**
     * 元信息行关键词：这些行如果<b>没有时间戳</b>，就不是歌词而是制作信息，
     * 留在 .lrc 里会被播放器当成歌词显示（「作词 : 小寒」挂一整首）。
     */
    private static final String[] META_WORDS = {
            "作词", "作曲", "编曲", "制作人", "监制", "出品", "发行", "混音", "母带", "录音",
            "和声", "吉他", "贝斯", "鼓", "键盘", "弦乐", "和声编写", "配唱", "词", "曲",
            "演唱", "原唱", "翻唱", "版权", "企划", "统筹", "录音室", "混音室", "母带室",
            "出品人", "音乐总监", "制作", "策划", "宣传", "op", "sp", "lyricist", "composer",
            "arranger", "producer", "mixed", "mastered", "recorded",
    };

    /** 是不是「制作信息行」（调用方保证已去掉时间戳）。 */
    public static boolean isMetadataLine(String raw) {
        if (raw == null) {
            return false;
        }
        String s = raw.trim();
        if (s.isEmpty()) {
            return false;
        }
        String lower = s.toLowerCase();
        for (String w : META_WORDS) {
            if (!lower.startsWith(w)) {
                continue;
            }
            // 「作词：xxx」「作词 : xxx」「作词 xxx」都算；但「作曲家的眼泪」这种歌名不算
            if (s.length() == w.length()) {
                return true;
            }
            char next = s.charAt(w.length());
            if (next == ':' || next == '：' || next == ' ' || next == '\t'
                    || next == '/' || next == '-' || next == '—') {
                return true;
            }
        }
        return false;
    }

    // ------------------------------------------------------------------
    // 解析
    // ------------------------------------------------------------------

    /** 解析成行（保持原文顺序；同一行多个时间戳会展开成多行）。 */
    public static List<Line> parse(String lrc) {
        List<Line> out = new ArrayList<Line>();
        if (lrc == null || lrc.trim().isEmpty()) {
            return out;
        }
        String[] rawLines = lrc.replace("\r\n", "\n").replace('\r', '\n').split("\n");
        int order = 0;
        for (String raw : rawLines) {
            Matcher m = TS_RE.matcher(raw);
            List<Long> stamps = new ArrayList<Long>();
            int lastEnd = 0;
            while (m.find()) {
                stamps.add(toMillis(m));
                lastEnd = m.end();
            }
            String body = raw.substring(lastEnd);
            List<Word> words = new ArrayList<Word>();
            String text = stripWordTags(body, words, stamps.isEmpty() ? 0 : stamps.get(0).longValue());
            if (stamps.isEmpty()) {
                continue;
            }
            for (int si = 0; si < stamps.size(); si++) {
                Line line = new Line(stamps.get(si).longValue(), text);
                line.order = order++;
                // 逐字时间只挂第一个时间戳（多时间戳 = 整行重复，逐字表相同）
                if (si == 0 && !words.isEmpty()) {
                    line.words.addAll(words);
                }
                out.add(line);
            }
        }
        return out;
    }

    /**
     * 剥离 {@code <mm:ss.xx>} 逐字标记，返回纯文本，并把逐字时间填进 {@code words}。
     *
     * <p>歌词文件里同时存在两种写法（网易、QQ 的「逐字」歌词都是第一种）：
     * <pre>[00:12.00]我&lt;00:12.00&gt;是&lt;00:12.40&gt;谁</pre>
     * 播放器不认识 {@code <>} 就会把标记直接显示出来，所以文本必须剥离，
     * 逐字时间单独留着（后续做逐字高亮或写增强型 LRC）。
     */
    private static String stripWordTags(String body, List<Word> words, long lineTime) {
        if (body == null || body.isEmpty()) {
            return "";
        }
        Matcher m = WORD_RE.matcher(body);
        if (!m.find()) {
            return body.trim();
        }
        StringBuilder cur = new StringBuilder();
        StringBuilder plain = new StringBuilder();
        long time = lineTime;
        int pos = 0;
        do {
            cur.append(body, pos, m.start());
            if (cur.length() > 0) {
                words.add(new Word(time, cur.toString()));
                plain.append(cur);
            }
            cur.setLength(0);
            time = toMillis(m);
            pos = m.end();
        } while (m.find());
        cur.append(body.substring(pos));
        if (cur.length() > 0) {
            words.add(new Word(time, cur.toString()));
            plain.append(cur);
        }
        return plain.toString().trim();
    }

    /** 是否增强型 LRC（含逐字时间标记）。 */
    public static boolean isEnhanced(String lrc) {
        return lrc != null && WORD_RE.matcher(lrc).find();
    }

    /** 逐字音节总数（摘要 / 日志用）。 */
    public static int wordCount(String lrc) {
        int n = 0;
        for (Line line : parse(lrc)) {
            n += line.words.size();
        }
        return n;
    }

    /**
     * 把任意歌词文本归一成标准 LRC。
     *
     * <p>目前处理 TTML（QQ / 酷狗 / YT Music 抓取常见）→ LRC；其余格式原样返回。
     * 归一放在「打分与质量校验之前」，否则 TTML 会被当成「没有时间轴的纯文本」拒掉。
     */
    public static String normalizeFormat(String raw) {
        if (raw == null) {
            return "";
        }
        if (Ttml.looksLike(raw)) {
            String lrc = Ttml.toLrc(raw);
            if (!lrc.trim().isEmpty()) {
                return lrc;
            }
        }
        return raw;
    }

    /** 有时间轴的行数。 */
    public static int timedLineCount(String lrc) {
        return parse(lrc).size();
    }

    /**
     * 清洗：去掉无时间戳的制作信息行与空行，保留全部时间轴行（含纯音乐占位行）。
     * 已经把「时间戳 + 文本」拆开的行原样拼回，格式统一成 {@code [mm:ss.xx]}。
     */
    public static String clean(String lrc) {
        if (lrc == null) {
            return "";
        }
        Map<Long, String> byTime = new LinkedHashMap<Long, String>();
        for (Line line : parse(lrc)) {
            if (!byTime.containsKey(line.timeMs)) {
                byTime.put(line.timeMs, line.text);
            }
        }
        // 没有时间轴的行：只有「不是制作信息、也不为空」的才保留为纯文本歌词
        StringBuilder plain = new StringBuilder();
        String[] rawLines = lrc.replace("\r\n", "\n").replace('\r', '\n').split("\n");
        boolean hasTimed = !byTime.isEmpty();
        if (!hasTimed) {
            for (String raw : rawLines) {
                String s = raw == null ? "" : raw.trim();
                if (s.isEmpty() || isMetadataLine(s)) {
                    continue;
                }
                plain.append(s).append('\n');
            }
            return plain.toString();
        }
        StringBuilder sb = new StringBuilder();
        for (Map.Entry<Long, String> e : byTime.entrySet()) {
            sb.append(format(e.getKey().longValue())).append(e.getValue()).append('\n');
        }
        return sb.toString();
    }

    // ------------------------------------------------------------------
    // 合并翻译
    // ------------------------------------------------------------------

    /**
     * 把译文按时间点插到原文行后面，生成双语 LRC。
     *
     * <p><b>时间戳必须按毫秒取最近邻</b>：网易原文是 {@code [00:19.629]}、译文是
     * {@code [00:19.64]}，差 11ms —— 拿时间戳字符串当 key 比对会全部落空
     * （容差 150ms 是实测出来的）。
     *
     * @return 合并后的 LRC；没有可用译文时返回清洗后的原文
     */
    public static String mergeTranslation(String original, String translation) {
        String base = clean(original);
        List<Line> trans = parse(translation);
        if (trans.isEmpty()) {
            return base;
        }
        List<Line> orig = parse(original);
        if (orig.isEmpty()) {
            return base;
        }
        Map<Long, String> transByTime = new LinkedHashMap<Long, String>();
        for (Line t : trans) {
            if (t.text.isEmpty() || isMetadataLine(t.text)) {
                continue;
            }
            if (!transByTime.containsKey(t.timeMs)) {
                transByTime.put(t.timeMs, t.text);
            }
        }
        if (transByTime.isEmpty()) {
            return base;
        }
        long[] keys = new long[transByTime.size()];
        int i = 0;
        for (Long k : transByTime.keySet()) {
            keys[i++] = k.longValue();
        }
        java.util.Arrays.sort(keys);

        StringBuilder sb = new StringBuilder(base.length() + 64 * transByTime.size());
        for (Line line : orig) {
            sb.append(format(line.timeMs)).append(line.text).append('\n');
            long nearest = nearest(keys, line.timeMs);
            if (nearest < 0) {
                continue;
            }
            String tr = transByTime.get(Long.valueOf(nearest));
            if (tr == null || tr.equals(line.text)) {
                continue; // 原文与译文相同（纯音乐占位行常见）就不重复
            }
            sb.append(format(line.timeMs)).append(tr).append('\n');
        }
        return sb.toString();
    }

    /** 翻译行数（合并结果里与原文成对存在的行数，用来在预览里显示「含译文 N 行」）。 */
    public static int translationLineCount(String merged) {
        List<Line> lines = parse(merged);
        int pairs = 0;
        for (int i = 1; i < lines.size(); i++) {
            if (lines.get(i).timeMs == lines.get(i - 1).timeMs) {
                pairs++;
            }
        }
        return pairs;
    }

    private static long nearest(long[] sorted, long target) {
        if (sorted.length == 0) {
            return -1;
        }
        int idx = java.util.Arrays.binarySearch(sorted, target);
        if (idx >= 0) {
            return sorted[idx];
        }
        int insert = -idx - 1;
        long best = -1;
        long bestDiff = Long.MAX_VALUE;
        if (insert < sorted.length) {
            best = sorted[insert];
            bestDiff = Math.abs(best - target);
        }
        if (insert - 1 >= 0) {
            long prev = sorted[insert - 1];
            long diff = Math.abs(prev - target);
            if (diff < bestDiff) {
                best = prev;
            }
        }
        if (best < 0 || Math.abs(best - target) > TRANSLATION_TOLERANCE_MS) {
            return -1;
        }
        return best;
    }

    /** 译文与原文时间点的最大容差。 */
    public static final long TRANSLATION_TOLERANCE_MS = 150;

    /** 毫秒 → {@code [mm:ss.xx]}。 */
    public static String format(long timeMs) {
        long ms = Math.max(0, timeMs);
        long totalSec = ms / 1000;
        long min = totalSec / 60;
        long sec = totalSec % 60;
        long cs = (ms % 1000) / 10;
        return String.format(java.util.Locale.US, "[%02d:%02d.%02d]", min, sec, cs);
    }

    private static long toMillis(Matcher m) {
        long minutes = Long.parseLong(m.group(1));
        long seconds = Long.parseLong(m.group(2));
        String frac = m.group(3);
        long millis = 0;
        if (frac != null) {
            if (frac.length() == 1) {
                millis = Long.parseLong(frac) * 100;
            } else if (frac.length() == 2) {
                millis = Long.parseLong(frac) * 10;
            } else {
                millis = Long.parseLong(frac);
            }
        }
        return minutes * 60000 + seconds * 1000 + millis;
    }

    /** 按时间排序后的行（预览里显示前几行用）。 */
    public static List<Line> sorted(String lrc) {
        List<Line> lines = parse(lrc);
        Collections.sort(lines, new Comparator<Line>() {
            @Override
            public int compare(Line a, Line b) {
                int c = Long.compare(a.timeMs, b.timeMs);
                return c != 0 ? c : Integer.compare(a.order, b.order);
            }
        });
        return lines;
    }

    /** 摘要：「58 行 · 含译文 52 行」。 */
    public static String summary(String content) {
        int total = timedLineCount(content);
        int trans = translationLineCount(content);
        if (total == 0) {
            return "纯文本（无时间轴）";
        }
        return total + " 行" + (trans > 0 ? " · 含译文 " + trans + " 行" : "");
    }
}
