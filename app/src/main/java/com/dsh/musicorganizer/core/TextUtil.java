package com.dsh.musicorganizer.core;

import java.text.Normalizer;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * 通用文本工具 —— 对应 Python 版 core.py 的通用工具部分。
 *
 * 包含：繁转简（内置映射表，零外部依赖）、规范化比较、相似度、
 * 尾部污染后缀剥离、重编码标记剥离、文件名合法化、轨道前缀剥离。
 */
public final class TextUtil {

    private TextUtil() {
    }

    public static final String UNKNOWN_ARTIST = "未知歌手";
    public static final String UNRECOGNIZED_DIR = "未识别";

    // ------------------------------------------------------------------
    // 繁转简（移植 ChineseConverter 的短语表 + 逐字映射表）
    // ------------------------------------------------------------------

    private static final String[] TRAD_PHRASES = {
            "鄧麗君", "周傑倫", "陳奕迅", "劉德華", "張學友", "張惠妹", "孫燕姿", "梁靜茹",
            "蕭敬騰", "林俊傑", "羅大佑", "李宗盛", "黃品源", "莫文蔚", "張韶涵", "范瑋琪",
            "劉若英", "蘇打綠", "陳綺貞", "張靚穎", "鍾漢良", "譚詠麟", "楊丞琳", "林憶蓮",
            "陳慧嫻", "鄭秀文", "容祖兒", "楊千嬅", "謝霆鋒", "張信哲", "庾澄慶", "張震嶽",
            "潘越雲", "鳳飛飛", "費玉清", "鄧紫棋", "林宥嘉", "田馥甄", "盧廣仲", "韋禮安",
            "徐佳瑩", "蕭亞軒", "王心凌", "黃鴻升", "炎亞綸", "吳青峰", "小虎隊", "飛兒樂團",
            "動力火車", "信樂團",
    };
    private static final String[] SIMP_PHRASES = {
            "邓丽君", "周杰伦", "陈奕迅", "刘德华", "张学友", "张惠妹", "孙燕姿", "梁静茹",
            "萧敬腾", "林俊杰", "罗大佑", "李宗盛", "黄品源", "莫文蔚", "张韶涵", "范玮琪",
            "刘若英", "苏打绿", "陈绮贞", "张靓颖", "钟汉良", "谭咏麟", "杨丞琳", "林忆莲",
            "陈慧娴", "郑秀文", "容祖儿", "杨千嬅", "谢霆锋", "张信哲", "庾澄庆", "张震岳",
            "潘越云", "凤飞飞", "费玉清", "邓紫棋", "林宥嘉", "田馥甄", "卢广仲", "韦礼安",
            "徐佳莹", "萧亚轩", "王心凌", "黄鸿升", "炎亚纶", "吴青峰", "小虎队", "飞儿乐团",
            "动力火车", "信乐团",
    };

    private static final Map<Character, Character> TRAD_CHARS = new HashMap<Character, Character>();

    static {
        String trad = "張學劉華鄧麗傑倫陳齊瑋靜蕭騰楊許羅黃萬蘇綠綺貞靚穎鍾漢譚詠憶嫻葉鄭兒謝鋒趙傳慶嶽昇凱雲鳳飛費盧廣韋瑩亞軒吳綸樂團動車愛夢時間後來這裡為與無聲語說聽風電話讓給對錯過還會開關門問題實現發變樣點線緣願雙親寶貝媽爺鄉國際場東興陽陰紅藍顏歲紀懷戀氣畫詩書長馬龍龜齒鬥臺灣貓雞魚";
        String simp = "张学刘华邓丽杰伦陈齐玮静萧腾杨许罗黄万苏绿绮贞靓颖钟汉谭咏忆娴叶郑儿谢锋赵传庆岳升凯云凤飞费卢广韦莹亚轩吴纶乐团动车爱梦时间后来这里为与无声语说听风电话让给对错过还会开关门问题实现发变样点线缘愿双亲宝贝妈爷乡国际场东兴阳阴红蓝颜岁纪怀恋气画诗书长马龙龟齿斗台湾猫鸡鱼";
        for (int i = 0; i < trad.length() && i < simp.length(); i++) {
            TRAD_CHARS.put(trad.charAt(i), simp.charAt(i));
        }
    }

    public static String toSimplified(String text) {
        if (text == null || text.isEmpty()) {
            return "";
        }
        for (int i = 0; i < TRAD_PHRASES.length; i++) {
            if (text.indexOf(TRAD_PHRASES[i]) >= 0) {
                text = text.replace(TRAD_PHRASES[i], SIMP_PHRASES[i]);
            }
        }
        StringBuilder sb = new StringBuilder(text.length());
        boolean changed = false;
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            Character m = TRAD_CHARS.get(c);
            if (m != null) {
                sb.append(m.charValue());
                changed = true;
            } else {
                sb.append(c);
            }
        }
        return changed ? sb.toString() : text;
    }

    // ------------------------------------------------------------------
    // 规范化与比较
    // ------------------------------------------------------------------

    private static final Pattern WS_RE = Pattern.compile("\\s+");

    /** 连字符家族：半角、全角、短横、长破折号、减号等统一成 '-'。 */
    private static final Pattern DASH_RE = Pattern.compile(
            "[\\-\\u2010\\u2011\\u2012\\u2013\\u2014\\u2015\\u2212\\ufe63\\uff0d]");

    /** NFKC（含全角→半角）+ casefold + 连字符归一 + 去空白，等价 Python norm_compare。 */
    public static String normCompare(String text) {
        if (text == null || text.isEmpty()) {
            return "";
        }
        String n = Normalizer.normalize(text, Normalizer.Form.NFKC).toLowerCase(Locale.ROOT);
        // 连字符归一：避免「周杰伦－晴天」匹配不上「周杰伦-晴天」这类全半角/变体差异
        n = DASH_RE.matcher(n).replaceAll("-");
        return WS_RE.matcher(n).replaceAll("");
    }

    public static boolean containsChinese(String text) {
        if (text == null) {
            return false;
        }
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            if (c >= 0x4E00 && c <= 0x9FFF) {
                return true;
            }
        }
        return false;
    }

    public static String safeStr(String s) {
        return s == null ? "" : s.trim();
    }

    // ------------------------------------------------------------------
    // 相似度（bigram Dice + Levenshtein ratio 兜底）
    // ------------------------------------------------------------------

    public static double levenshtein(String a, String b) {
        int la = a.length();
        int lb = b.length();
        if (la == 0) {
            return lb;
        }
        if (lb == 0) {
            return la;
        }
        int[] prev = new int[lb + 1];
        int[] cur = new int[lb + 1];
        for (int j = 0; j <= lb; j++) {
            prev[j] = j;
        }
        for (int i = 1; i <= la; i++) {
            cur[0] = i;
            char ca = a.charAt(i - 1);
            for (int j = 1; j <= lb; j++) {
                int cost = (ca == b.charAt(j - 1)) ? 0 : 1;
                int v = Math.min(Math.min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost);
                cur[j] = v;
            }
            int[] t = prev;
            prev = cur;
            cur = t;
        }
        return prev[lb];
    }

    /** 近似 difflib.SequenceMatcher.ratio：1 - 距离/较长串。 */
    public static double ratio(String a, String b) {
        int max = Math.max(a.length(), b.length());
        if (max == 0) {
            return 1.0;
        }
        return 1.0 - (levenshtein(a, b) / (double) max);
    }

    /** 综合相似度：繁转简 + 归一后，用字符残差 / Levenshtein / bigram Dice 混合。 */
    public static double textSimilarity(String left, String right) {
        String a = normCompare(toSimplified(left == null ? "" : left));
        String b = normCompare(toSimplified(right == null ? "" : right));
        return smartSimilarity(a, b);
    }

    /**
     * 多算法混合相似度：
     * 短串（≤3 字符）更信 Levenshtein（两字歌名重合一字时，字符 Dice 会虚高），
     * 长串更信字符残差 + bigram Dice；再与「子串包含」取较大值。
     * 入参应已做归一（normCompare / toSimplified）。
     */
    public static double smartSimilarity(String a, String b) {
        if (a.isEmpty() && b.isEmpty()) {
            return 1.0;
        }
        if (a.isEmpty() || b.isEmpty()) {
            return 0.0;
        }
        if (a.equals(b)) {
            return 1.0;
        }
        double charSim = charRemainderSimilarity(a, b);
        double levSim = ratio(a, b);
        double dice = bigramDice(a, b);
        double contains = containsSimilarity(a, b);
        int minLen = Math.min(codePointCount(a), codePointCount(b));
        double blended = minLen <= 3
                ? 0.35 * charSim + 0.45 * levSim + 0.20 * dice
                : 0.50 * charSim + 0.30 * levSim + 0.20 * dice;
        return Math.max(contains, blended);
    }

    /** 字符残差相似度：两串公共字符（按 codePoint 多重集）占两串总字符的比例。 */
    public static double charRemainderSimilarity(String a, String b) {
        if (a.isEmpty() && b.isEmpty()) {
            return 1.0;
        }
        if (a.isEmpty() || b.isEmpty()) {
            return 0.0;
        }
        Map<Integer, Integer> ca = codePointCounts(a);
        Map<Integer, Integer> cb = codePointCounts(b);
        int common = 0;
        for (Map.Entry<Integer, Integer> e : ca.entrySet()) {
            Integer other = cb.get(e.getKey());
            if (other != null) {
                common += Math.min(e.getValue(), other.intValue());
            }
        }
        int total = codePointCount(a) + codePointCount(b);
        return total == 0 ? 0.0 : 2.0 * common / (double) total;
    }

    /** 子串包含相似度：短串是长串的子串时给 0.80 + 长度占比 0.20，否则 0。 */
    public static double containsSimilarity(String a, String b) {
        if (a.isEmpty() || b.isEmpty()) {
            return 0.0;
        }
        String longer = a.length() >= b.length() ? a : b;
        String shorter = a.length() >= b.length() ? b : a;
        if (longer.contains(shorter)) {
            return 0.80 + 0.20 * ((double) shorter.length() / longer.length());
        }
        return 0.0;
    }

    private static double bigramDice(String a, String b) {
        if (a.length() < 2 || b.length() < 2) {
            return ratio(a, b);
        }
        Map<String, Integer> gramsA = bigramCounts(a);
        Map<String, Integer> gramsB = bigramCounts(b);
        int overlap = 0;
        int totalA = 0;
        int totalB = 0;
        for (Integer n : gramsA.values()) {
            totalA += n;
        }
        for (Integer n : gramsB.values()) {
            totalB += n;
        }
        for (Map.Entry<String, Integer> e : gramsA.entrySet()) {
            Integer other = gramsB.get(e.getKey());
            if (other != null) {
                overlap += Math.min(e.getValue(), other);
            }
        }
        return 2.0 * overlap / (double) (totalA + totalB);
    }

    private static int codePointCount(String s) {
        return s.codePointCount(0, s.length());
    }

    private static Map<Integer, Integer> codePointCounts(String s) {
        Map<Integer, Integer> map = new HashMap<Integer, Integer>();
        for (int i = 0; i < s.length(); ) {
            int cp = s.codePointAt(i);
            Integer n = map.get(cp);
            map.put(cp, n == null ? 1 : n + 1);
            i += Character.charCount(cp);
        }
        return map;
    }

    private static Map<String, Integer> bigramCounts(String s) {
        Map<String, Integer> map = new HashMap<String, Integer>();
        for (int i = 0; i + 2 <= s.length(); i++) {
            String g = s.substring(i, i + 2);
            Integer n = map.get(g);
            map.put(g, n == null ? 1 : n + 1);
        }
        return map;
    }

    // ------------------------------------------------------------------
    // 尾部污染后缀 / 重编码标记
    // ------------------------------------------------------------------

    /** _N / _N_N / (N) / （N） / _(N) / _副本 等混合污染链。 */
    private static final Pattern TRAILING_SUFFIX_RE = Pattern.compile(
            "(?:_\\d+(?:[~.\\-、 _]\\d+|[\\s\\u3000]*[（(]\\s*\\d+\\s*[)）])*"
                    + "|_(?:副本|拷贝|copy|複製|复制)\\s*\\d*"
                    + "|[\\s\\u3000_]*[（(]\\s*\\d+\\s*[)）])+$",
            Pattern.CASE_INSENSITIVE);

    public static String stripTrailingNumericSuffix(String stem) {
        if (stem == null) {
            return "";
        }
        return TRAILING_SUFFIX_RE.matcher(stem).replaceFirst("");
    }

    private static final String[] RECODE_KEYWORDS = {
            "h264_videotoolbox", "hevc_videotoolbox", "libx264", "libx265",
            "h264_nvenc", "hevc_nvenc", "h264_qsv", "hevc_qsv", "h264_amf",
            "hevc_amf", "h264_vaapi", "hevc_vaapi",
            "x264", "x265", "h264", "h265", "hevc", "av1", "vp8", "vp9",
            "recode", "reencoded", "encoded", "ffmpeg", "new",
    };

    private static final Pattern CRF_RE = Pattern.compile(
            "_crf\\s*\\d+(?:\\.\\d+)?(?:_[a-z]+)*$", Pattern.CASE_INSENSITIVE);
    private static final Pattern BRACKET_RE = Pattern.compile(
            "_\\[[^\\]]+\\]$|_\\([^)]+\\)$", Pattern.CASE_INSENSITIVE);

    /** 剥离 FFmpegFreeUI / HandBrake 等重编码工具追加的标记（最多 10 轮）。 */
    public static String stripRecodeMarker(String stem) {
        if (stem == null || stem.isEmpty()) {
            return stem == null ? "" : stem;
        }
        String result = stem;
        for (int round = 0; round < 10; round++) {
            String original = result;
            for (String kw : RECODE_KEYWORDS) {
                result = result.replaceAll("(?i)_" + Pattern.quote(kw) + "(?:\\s*\\d+(?:\\.\\d+)?)?$", "");
            }
            result = CRF_RE.matcher(result).replaceFirst("");
            result = BRACKET_RE.matcher(result).replaceFirst("");
            result = stripTrailingNumericSuffix(result);
            if (result.equals(original)) {
                break;
            }
        }
        return result.isEmpty() ? stem : result;
    }

    private static final Pattern SPACE_CHARS_RE =
            Pattern.compile("[\\s\\u3000\\u00a0\\u2000-\\u200b\\u202f\\u205f]+");

    /** 清理归一化：去污染后缀 + 重编码标记；含中文则去全部空格。 */
    public static String normalizeStemForCleanup(String stem) {
        if (stem == null || stem.isEmpty()) {
            return stem == null ? "" : stem;
        }
        String cleaned = stripRecodeMarker(stem);
        if (containsChinese(cleaned)) {
            String noSpace = SPACE_CHARS_RE.matcher(cleaned).replaceAll("");
            if (!noSpace.isEmpty()) {
                cleaned = noSpace;
            }
        }
        if (cleaned.trim().isEmpty()) {
            return stem;
        }
        return cleaned;
    }

    // ------------------------------------------------------------------
    // 文件名合法化 / 轨道前缀
    // ------------------------------------------------------------------

    public static final String ILLEGAL_FILENAME_CHARS = "<>:\"/\\|?*";

    public static String sanitizeFilenameComponent(String name, String fallback, int maxLength) {
        String text = Normalizer.normalize(name == null ? "" : name, Normalizer.Form.NFKC);
        text = text.replace("\r", " ").replace("\n", " ").replace("\t", " ");
        for (int i = 0; i < ILLEGAL_FILENAME_CHARS.length(); i++) {
            text = text.replace(ILLEGAL_FILENAME_CHARS.charAt(i), '_');
        }
        StringBuilder sb = new StringBuilder(text.length());
        for (int i = 0; i < text.length(); i++) {
            if (text.charAt(i) >= 32) {
                sb.append(text.charAt(i));
            }
        }
        text = sb.toString().trim();
        text = stripDots(text);
        if (text.isEmpty()) {
            return fallback;
        }
        if (text.length() > maxLength) {
            text = text.substring(0, maxLength);
        }
        text = stripDots(text);
        return text.isEmpty() ? fallback : text;
    }

    private static String stripDots(String s) {
        int start = 0;
        int end = s.length();
        while (start < end && (s.charAt(start) == '.' || s.charAt(start) == ' ')) {
            start++;
        }
        while (end > start && (s.charAt(end - 1) == '.' || s.charAt(end - 1) == ' ')) {
            end--;
        }
        return s.substring(start, end);
    }

    private static final Pattern TRACK_PREFIX_RE = Pattern.compile(
            "^\\s*(?:\\[(?:\\d{1,4})\\]|\\((?:\\d{1,4})\\)|(?:\\d{1,4})\\s*[.．、_\\-]\\s*|(?:\\d{1,4})\\s+)(?=\\S)");

    /** 剥离「01.」「(03)」「08 -」等轨道前缀，剥离结果必须含文字才采用。 */
    public static String stripTrackPrefix(String stem) {
        if (stem == null) {
            return "";
        }
        String original = stem;
        String candidate = TRACK_PREFIX_RE.matcher(stem).replaceFirst("").trim();
        if (!candidate.isEmpty() && !candidate.equals(original)) {
            if (candidate.matches(".*[-–—_].*") || containsChinese(candidate)) {
                return candidate;
            }
            for (int i = 0; i < candidate.length(); i++) {
                char c = candidate.charAt(i);
                if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
                        || (c >= 0x4E00 && c <= 0x9FFF)) {
                    return candidate;
                }
            }
        }
        return original;
    }

    public static String formatSize(long bytes) {
        if (bytes < 1024) {
            return bytes + " B";
        }
        double v = bytes;
        String[] units = {"KB", "MB", "GB", "TB"};
        for (String unit : units) {
            v /= 1024.0;
            if (v < 1024.0 || unit.equals("TB")) {
                return String.format(Locale.US, "%.1f %s", v, unit);
            }
        }
        return bytes + " B";
    }

    public static String formatDuration(Double seconds) {
        if (seconds == null || seconds.isNaN() || seconds.isInfinite() || seconds <= 0) {
            return "--:--";
        }
        int total = (int) Math.round(seconds);
        int h = total / 3600;
        int m = (total % 3600) / 60;
        int s = total % 60;
        if (h > 0) {
            return String.format(Locale.US, "%d:%02d:%02d", h, m, s);
        }
        return String.format(Locale.US, "%d:%02d", m, s);
    }

    public static String shortError(Throwable t) {
        if (t == null) {
            return "未知错误";
        }
        String msg = t.getMessage();
        String text = (msg == null || msg.trim().isEmpty())
                ? t.getClass().getSimpleName() : msg.trim();
        return text.length() > 180 ? text.substring(0, 180) : text;
    }

    public static String joinArtists(List<String> names, String sep) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < names.size(); i++) {
            if (i > 0) {
                sb.append(sep);
            }
            sb.append(names.get(i));
        }
        return sb.toString();
    }

    // ------------------------------------------------------------------
    // 多艺人拆分（按分隔符与括号提示切分）
    // ------------------------------------------------------------------

    /** 含分隔符的组合艺人名，不能被拆开（整串白名单，normCompare 后比对）。 */
    private static final String[] NO_SPLIT_ARTISTS = {
            "simon & garfunkel", "earth, wind & fire", "guns n' roses",
            "crosby, stills, nash & young", "a great big world",
            "fitz and the tantrums", "twenty one pilots", "boyz ii men",
    };

    private static final Pattern ARTIST_SEP_RE = Pattern.compile(
            "\\s*(?:/|／|、|;|；|,|，|&|＆|\\bfeat\\.?\\b|\\bft\\.?\\b|\\bfeaturing\\b)\\s*",
            Pattern.CASE_INSENSITIVE);

    /** 拆多艺人：按分隔符拆，白名单保护会被误拆的组合名，结果去空 + 去重。 */
    public static List<String> splitArtists(String raw) {
        List<String> out = new ArrayList<String>();
        if (raw == null || raw.trim().isEmpty()) {
            return out;
        }
        String key = normCompare(raw);
        for (String noSplit : NO_SPLIT_ARTISTS) {
            if (key.equals(normCompare(noSplit))) {
                out.add(raw.trim());
                return out;
            }
        }
        for (String part : ARTIST_SEP_RE.split(raw)) {
            String p = part.trim();
            if (p.isEmpty() || containsNorm(out, p)) {
                continue;
            }
            out.add(p);
        }
        return out.isEmpty() ? java.util.Collections.singletonList(raw.trim()) : out;
    }

    private static boolean containsNorm(List<String> list, String s) {
        String key = normCompare(s);
        for (String e : list) {
            if (normCompare(e).equals(key)) {
                return true;
            }
        }
        return false;
    }

    /** 多艺人最佳相似度：拆分双方，取「任一本地艺人 × 任一候选艺人」的最大相似度。 */
    public static double bestArtistSimilarity(String a, String b) {
        List<String> as = splitArtists(a);
        List<String> bs = splitArtists(b);
        if (as.isEmpty() || bs.isEmpty()) {
            return 0.0;
        }
        double best = 0.0;
        for (String x : as) {
            for (String y : bs) {
                double s = textSimilarity(x, y);
                if (s > best) {
                    best = s;
                }
            }
        }
        return best;
    }

    /** 简易 Matcher 工具：返回所有匹配组。 */
    public static List<String> findAll(Pattern p, String text, int group) {
        List<String> out = new ArrayList<String>();
        Matcher m = p.matcher(text);
        while (m.find()) {
            out.add(m.group(group));
        }
        return out;
    }
}
