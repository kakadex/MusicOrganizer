package com.dsh.musicorganizer.core;

/**
 * 数据源优先级与候选排序（v0.1.44）。
 *
 * <p><b>为什么国内源在前</b>：中文歌的标题 / 艺人 / 专辑 / 年份在国内站是母语录入，
 * 海外库里同一首歌常是罗马字或英文译名（「Jay Chou」而不是「周杰伦」），照抄下来就把标签写坏了。
 * 海外源仍然保留 —— 冷门外语歌、国内站点没收的曲目还得靠它们。
 *
 * <p><b>为什么不把国内源无条件排最前</b>：置信度明显更高时（差 &gt; {@link #TOLERANCE}）
 * 仍按置信度排。否则「国内源给了个错同名歌」会硬压掉海外源的正确结果。
 *
 * <p>纯 Java，零 Android / 零 org.json 依赖，可在桌面 JVM 回归。
 */
public final class SourceRank {

    /**
     * 优先级顺序，下标越小越靠前。
     *
     * <p>国内五家按召回质量排：网易（字段最全，有 publishTime 年份）→ QQ（有 index_album 音轨）
     * → 酷狗 → 酷我 → 咪咕（只用来补流派）；海外三家：MusicBrainz 作为锚点仍在 Deezer/iTunes 之前。
     */
    /**
     * 优先级顺序（中文曲目）：下标越小越靠前。
     *
     * <p>国内五家按召回质量排：网易（字段最全，有 publishTime 年份）→ QQ（有 index_album 音轨）
     * → 酷狗 → 酷我 → 咪咕（只用来补流派）；海外三家：MusicBrainz 作为锚点仍在 Deezer/iTunes 之前。
     */
    private static final String[] ORDER = {
            "netease", "qqmusic", "kugou", "kuwo", "migu",
            "musicbrainz", "deezer", "itunes"
    };

    /**
     * 优先级顺序（外文曲目）：海外三家在前、国内五家在后。
     *
     * <p>外文歌的母语录入在 MusicBrainz/Deezer/iTunes，国内站要么没收、要么只有罗马字译名；
     * 这时让海外源优先，避免「Jay Chou」被硬压。中文曲目的顺序见 {@link #ORDER}。
     */
    private static final String[] ORDER_OVERSEAS_FIRST = {
            "musicbrainz", "deezer", "itunes",
            "netease", "qqmusic", "kugou", "kuwo", "migu"
    };

    /** 国内源的个数（前 5 个）。 */
    private static final int CHINESE_COUNT = 5;

    /**
     * 中文曲目下「国内源优先」的置信度宽容带。
     *
     * <p>各源基数不同：海外 MusicBrainz 0.85 / Deezer·iTunes 0.75，国内五家统一 0.60。
     * 若只比绝对置信度，0.85 的「Jay Chou」会永远压过 0.60 的「周杰伦」，
     * 顺序表里的「国内优先」根本触发不了。给中文曲目一个 0.30 的宽容带：
     * 只要 |差| ≤ 0.30（含 0.85−0.60=0.25），国内源即压过海外源；
     * 差得更多（海外明显更可信）仍按置信度，避免错配。
     */
    private static final double CN_PREFER_BAND = 0.30;

    /**
     * 置信度容差：差在这个范围内的两个候选视为「持平」。
     *
     * <p>各源的置信度来自不同算法，0.8031 与 0.8025 之间没有意义；
     * 但直接比浮点数会让海外源偶然领先一名，结果同一张专辑里
     * 有的写「周杰伦」有的写「Jay Chou」。
     */
    public static final double TOLERANCE = 0.001;

    /** 吸收浮点误差的极小余量（见 {@link #compare}）。 */
    private static final double EPSILON = 1e-9;

    private SourceRank() {
    }

    /**
     * 按优先级排列的源列表（副本，调用方随便改）。
     *
     * <p>召回时按这个顺序建任务队列：虽然各源是并发发出的，
     * 但结果先到先入列，顺序会影响到「同一置信度下谁在前面」。
     *
     * @param chinese 曲目是否中文；true 用国内优先表，false 用海外优先表
     */
    public static String[] order(boolean chinese) {
        String[] src = chinese ? ORDER : ORDER_OVERSEAS_FIRST;
        String[] copy = new String[src.length];
        System.arraycopy(src, 0, copy, 0, src.length);
        return copy;
    }

    /**
     * 按优先级排列的源列表（默认中文曲目语义：国内优先）。
     *
     * @deprecated 请改用 {@link #order(boolean)} 并显式传入曲目语种，
     * 以便外文曲目走海外优先、中文曲目走国内优先。
     */
    @Deprecated
    public static String[] order() {
        return order(true);
    }

    /** 源优先级（中文曲目语义：国内优先）；未登记的源排最后。 */
    public static int priority(String source) {        if (source == null) {
            return ORDER.length;
        }
        for (int i = 0; i < ORDER.length; i++) {
            if (ORDER[i].equals(source)) {
                return i;
            }
        }
        return ORDER.length;
    }

    /** 源在指定语种顺序表里的下标；未登记排最后。 */
    private static int rankIndex(String source, boolean chinese) {
        String[] src = chinese ? ORDER : ORDER_OVERSEAS_FIRST;
        if (source == null) {
            return src.length;
        }
        for (int i = 0; i < src.length; i++) {
            if (src[i].equals(source)) {
                return i;
            }
        }
        return src.length;
    }

    /** 是否国内源（网易 / QQ / 酷狗 / 酷我 / 咪咕）。 */
    public static boolean isChinese(String source) {
        return priority(source) < CHINESE_COUNT;
    }

    /** 源的展示名（日志与「低置信」提示用）。 */
    public static String label(String source) {
        if (source == null) {
            return "";
        }
        if ("netease".equals(source)) {
            return "网易云";
        }
        if ("qqmusic".equals(source)) {
            return "QQ 音乐";
        }
        if ("kugou".equals(source)) {
            return "酷狗";
        }
        if ("kuwo".equals(source)) {
            return "酷我";
        }
        if ("migu".equals(source)) {
            return "咪咕";
        }
        if ("musicbrainz".equals(source)) {
            return "MusicBrainz";
        }
        if ("deezer".equals(source)) {
            return "Deezer";
        }
        if ("itunes".equals(source)) {
            return "iTunes";
        }
        return source;
    }

    /**
     * 比较两个候选（默认中文曲目语义：国内优先）。
     *
     * @see #compare(String, double, String, double, boolean)
     */
    public static int compare(String sourceA, double confidenceA,
                              String sourceB, double confidenceB) {
        return compare(sourceA, confidenceA, sourceB, confidenceB, true);
    }

    /**
     * 比较两个候选。
     *
     * <p><b>中文曲目（chinese=true）</b>：置信度高者在前；但国内源与海外源之间，
     * 只要置信度差在 {@link #CN_PREFER_BAND} 内（含海外 0.85 vs 国内 0.60 的 0.25 落差），
     * 一律让国内源在前 —— 海外库的同一首中文歌常是罗马音译名，照抄会写坏标签。
     * 差距明显更大（海外明显更可信）时仍按置信度，避免错配。
     *
     * <p><b>外文曲目（chinese=false）</b>：海外优先表生效，行为相反 —— 外文歌的母语录入在
     * MusicBrainz/Deezer/iTunes，国内站多为罗马字译名，让海外源优先。
     *
     * <p>同为国内或同为海外时，再按置信度；差在 {@link #TOLERANCE} 内视为持平。
     *
     * @return 负值表示 a 排在 b 前面（与 {@code Comparator} 约定一致）
     */
    public static int compare(String sourceA, double confidenceA,
                              String sourceB, double confidenceB, boolean chinese) {
        double diff = confidenceA - confidenceB;
        if (chinese) {
            // 中文曲目：国内源优先带。仅当「一边国内、一边海外」且差距不大时生效，
            // 避免把「海外明显更准」的结果硬压掉。
            boolean aCn = isChinese(sourceA);
            boolean bCn = isChinese(sourceB);
            if (aCn != bCn && Math.abs(diff) <= CN_PREFER_BAND) {
                return aCn ? -1 : 1;
            }
        }
        // +EPSILON：0.9000 - 0.9010 在 double 里是 -0.0010000000000000009，
        // 正好卡在边界上会被误判成「明显不同」，加个极小的余量吸收浮点误差
        if (Math.abs(diff) > TOLERANCE + EPSILON) {
            return diff > 0 ? -1 : 1;
        }
        int pa = rankIndex(sourceA, chinese);
        int pb = rankIndex(sourceB, chinese);
        if (pa != pb) {
            return pa - pb;
        }
        if (diff > 0) {
            return -1;
        }
        return diff < 0 ? 1 : 0;
    }
}
