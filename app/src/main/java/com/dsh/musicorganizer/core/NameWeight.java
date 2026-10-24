package com.dsh.musicorganizer.core;

/**
 * 文件名权重 —— 联网查标签 / 歌词时，决定「信文件名」还是「信已有标签」。
 *
 * <p>权重 0%：只信已有标签，文件名仅作兜底；
 * 100%：只信文件名解析结果，标签仅作兜底；
 * 50% 为分界线（50% 及以上以文件名为准）。
 *
 * <p>纯 Java 实现，不依赖 Android，便于跑离线回归测试。
 */
public final class NameWeight {

    private NameWeight() {
    }

    /** 默认权重（百分比）：文件名作为弱信号，主要仍以已有标签为准。 */
    public static final int DEFAULT_PERCENT = 20;

    public static final int MIN_PERCENT = 0;
    public static final int MAX_PERCENT = 100;

    /** 把任意权重收敛到 [0,1]。 */
    public static double clamp(double weight) {
        if (Double.isNaN(weight)) {
            return fromPercent(DEFAULT_PERCENT);
        }
        if (weight < 0) {
            return 0;
        }
        if (weight > 1) {
            return 1;
        }
        return weight;
    }

    /** 百分比（0~100）转权重（0~1）。 */
    public static double fromPercent(int percent) {
        int p = percent;
        if (p < MIN_PERCENT) {
            p = MIN_PERCENT;
        }
        if (p > MAX_PERCENT) {
            p = MAX_PERCENT;
        }
        return p / 100.0;
    }

    /** 是否以文件名为主（>= 50%）。 */
    public static boolean preferFilename(double weight) {
        return clamp(weight) >= 0.5;
    }

    /**
     * 按权重选出主用值：以文件名为准时空则回退标签，反之亦然。
     * 两边都为空返回 ""。
     */
    public static String pick(String filenameValue, String tagValue, double weight) {
        String f = trim(filenameValue);
        String t = trim(tagValue);
        if (preferFilename(weight)) {
            return f.isEmpty() ? t : f;
        }
        return t.isEmpty() ? f : t;
    }

    /**
     * 与 {@link #pick} 相反的次要值，用于主用值查不到时再试一次。
     * 与主用值相同（或为空）时返回 ""，表示无需二次尝试。
     */
    public static String pickSecondary(String filenameValue, String tagValue, double weight) {
        String f = trim(filenameValue);
        String t = trim(tagValue);
        String primary = pick(f, t, weight);
        String secondary = preferFilename(weight) ? t : f;
        if (secondary.isEmpty()) {
            return "";
        }
        if (TextUtil.normCompare(secondary).equals(TextUtil.normCompare(primary))) {
            return "";
        }
        return secondary;
    }

    private static String trim(String value) {
        return value == null ? "" : value.trim();
    }
}
