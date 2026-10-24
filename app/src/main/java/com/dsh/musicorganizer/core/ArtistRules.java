package com.dsh.musicorganizer.core;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * 歌手返回合理性校验（R-02）—— 对应 Python 版 is_reasonable_artist_return。
 *
 * 七条校验：非空长度 / 含文字 / 不等于歌名 / 不等于原名 / 无非法字符 /
 * 非占位词 / 与候选一致。
 */
public final class ArtistRules {

    private ArtistRules() {
    }

    private static final Set<String> GENERIC_ARTISTS = new HashSet<String>();

    static {
        String[] arr = {"unknown", "unknownartist", "n/a", "na", "none", "null",
                "未知", "未知歌手", "未知艺术家", "artist", "歌手", "various", "variousartists",
                "va", "v.a.", "群星", "合辑", "华语群星", "群星合辑", "华语合辑",
                "网络歌手", "佚名", "unknownartist", "traditional", "未知专辑"};
        // 说明：这些只是「不能拿来当歌手目录名」的占位标签，
        // 实测把「华语群星」当歌手会把整盘合辑归到同一个错误目录（某歌手-某歌名 → 华语群星/）。
        for (String s : arr) {
            GENERIC_ARTISTS.add(s);
        }
    }

    private static final Pattern AUDIO_EXT_RE = Pattern.compile(
            "\\.(?:mp3|flac|m4a|wav|ogg|aac|wma|ape|opus|lrc|krc|qrc|trc|srt)$",
            Pattern.CASE_INSENSITIVE);
    private static final Pattern SPLIT_RE = Pattern.compile(
            "(?:、|·|・|/|＆|&|,|，|;|；|\\+|\\bfeat\\.?\\b|\\bft\\.?\\b|\\bwith\\b)",
            Pattern.CASE_INSENSITIVE);
    private static final Pattern MAIN_SPLIT_RE = Pattern.compile(
            "\\bfeat\\b|\\bft\\b|（|（|\\(|\\bwith\\b", Pattern.CASE_INSENSITIVE);
    private static final Pattern HAS_TEXT_RE =
            Pattern.compile("[A-Za-z\\u4e00-\\u9fff\\u3040-\\u30ff\\uac00-\\ud7af]");
    private static final Pattern URL_RE = Pattern.compile("https?://|www\\.", Pattern.CASE_INSENSITIVE);

    public static String normalizeCandidate(String text) {
        String v = TextUtil.toSimplified(text == null ? "" : text).trim();
        v = TextUtil.stripTrailingNumericSuffix(v);
        v = v.replaceAll("\\s+", " ").trim();
        return trimEdge(v);
    }

    private static String trimEdge(String v) {
        int start = 0;
        int end = v.length();
        while (start < end && " ._".indexOf(v.charAt(start)) >= 0) {
            start++;
        }
        while (end > start && " ._".indexOf(v.charAt(end - 1)) >= 0) {
            end--;
        }
        return v.substring(start, end);
    }

    private static List<String> artistTokens(String text) {
        String normalized = TextUtil.normCompare(TextUtil.toSimplified(text));
        List<String> out = new ArrayList<String>();
        if (normalized.isEmpty()) {
            return out;
        }
        for (String part : SPLIT_RE.split(normalized)) {
            if (!part.trim().isEmpty()) {
                out.add(part.trim());
            }
        }
        return out;
    }

    /** 期望歌手与返回歌手是否相容（相等 / 包含 / 分词交集 / 主体匹配 / 相似度）。 */
    public static boolean artistsCompatible(String expected, String returned) {
        String exp = TextUtil.normCompare(TextUtil.toSimplified(expected));
        String ret = TextUtil.normCompare(TextUtil.toSimplified(returned));
        if (exp.isEmpty() || ret.isEmpty()) {
            return false;
        }
        if (exp.equals(ret)) {
            return true;
        }
        if (exp.length() >= 2 && ret.length() >= 2 && (exp.contains(ret) || ret.contains(exp))) {
            return true;
        }
        Set<String> a = new HashSet<String>(artistTokens(expected));
        for (String t : artistTokens(returned)) {
            if (a.contains(t)) {
                return true;
            }
        }
        String expMain = firstSegment(exp);
        String retMain = firstSegment(ret);
        if (!expMain.isEmpty() && !retMain.isEmpty()
                && (expMain.contains(retMain) || retMain.contains(expMain))) {
            return true;
        }
        return TextUtil.ratio(exp, ret) >= 0.80;
    }

    private static String firstSegment(String s) {
        String[] parts = MAIN_SPLIT_RE.split(s);
        return parts.length > 0 ? parts[0] : s;
    }

    public static boolean isReasonableArtistReturn(String artist, String searchTitle,
                                                   String originalStem, String expectedArtist) {
        String text = normalizeCandidate(artist);
        if (text.isEmpty() || text.length() > 120) {
            return false;
        }
        if (!HAS_TEXT_RE.matcher(text).find()) {
            return false;
        }
        if (TextUtil.normCompare(text).equals(TextUtil.normCompare(NameParser.stripNameNoise(searchTitle)))) {
            return false;
        }
        String cleanOriginal = NameParser.stripNameNoise(originalStem);
        if (TextUtil.normCompare(text).equals(TextUtil.normCompare(originalStem))
                || TextUtil.normCompare(text).equals(TextUtil.normCompare(cleanOriginal))) {
            return false;
        }
        if (text.contains("<") || text.contains(">") || text.contains("\"")
                || text.contains("|") || text.contains("?") || text.contains("*")
                || text.contains("\r") || text.contains("\n") || text.contains("\t")
                || text.contains("\\") || text.contains("/")) {
            return false;
        }
        if (URL_RE.matcher(text).find()) {
            return false;
        }
        for (int i = 0; i < text.length(); i++) {
            if (text.charAt(i) < 32) {
                return false;
            }
        }
        if (GENERIC_ARTISTS.contains(TextUtil.normCompare(text))) {
            return false;
        }
        if (AUDIO_EXT_RE.matcher(text.toLowerCase(Locale.ROOT)).find()) {
            return false;
        }
        int dash = 0;
        int under = 0;
        for (int i = 0; i < text.length(); i++) {
            if (text.charAt(i) == '-') {
                dash++;
            } else if (text.charAt(i) == '_') {
                under++;
            }
        }
        if (dash >= 4 || under >= 5) {
            return false;
        }
        if (expectedArtist != null && !expectedArtist.trim().isEmpty()) {
            return artistsCompatible(expectedArtist, text);
        }
        return true;
    }

    /**
     * 是否是「占位歌手标签」（群星 / 华语群星 / Various Artists / 未知 …）。
     *
     * <p>这类值不能当歌手目录：整盘合辑会被归进同一个错误目录
     * （实测某歌手-某歌名 → 华语群星/）。命中时应丢弃该标签、改用文件名解析。
     */
    public static boolean isGenericArtist(String text) {
        String key = TextUtil.normCompare(text == null ? "" : text);
        if (key.isEmpty()) {
            return true;
        }
        return GENERIC_ARTISTS.contains(key)
                || key.equals(TextUtil.normCompare(TextUtil.UNKNOWN_ARTIST))
                || key.equals(TextUtil.normCompare(TextUtil.UNRECOGNIZED_DIR));
    }

    /**
     * 歌手目录的归一键：写法不同、实际同一艺人的名字要落到同一个目录。
     *
     * <p>实测 v0.1.16：`示例乐队 / 示例乐队 &amp; The Band / 示例乐队 And The Band` 三个目录并存，
     * 差别只在连接符（&amp; / and / ＆）。这里把 `&amp; 、 ， , + ＆` 统一成 `and`，
     * 配合 NFKC + 小写 + 去空白，就能判为同一个。
     */
    public static String folderKey(String text) {
        String n = TextUtil.normCompare(TextUtil.toSimplified(text == null ? "" : text));
        return n.replace("&", "and").replace("＆", "and").replace("、", "and")
                .replace("，", "and").replace(",", "and").replace("+", "and");
    }
}
