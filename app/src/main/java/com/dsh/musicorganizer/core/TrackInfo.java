package com.dsh.musicorganizer.core;

/**
 * 曲目技术信息的格式化（时长 / 码率）—— v0.1.51 曲库列表改版用。
 *
 * <p>库页每一行右侧要显示「时长 · 大小 · 质量」三行小字（保持紧凑的列表密度），
 * 其中时长与码率来自 {@code MediaMetadataRetriever}，取不到时是 0 —— 这时应该**什么都不显示**，
 * 而不是印一个 "0:00" 或 "0kbps" 让人以为是真实值。
 *
 * <p>纯 Java，零 Android 依赖，可在桌面 JVM 回归。
 */
public final class TrackInfo {

    private TrackInfo() {
    }

    /**
     * 毫秒 → {@code m:ss}（超过一小时补小时位）。
     *
     * <p>四舍五入到秒：播放器显示的也是整秒，留着 300ms 的零头只会让人觉得对不上。
     *
     * @return 格式化结果；{@code ms <= 0} 返回空串（未知）
     */
    public static String duration(long ms) {
        if (ms <= 0) {
            return "";
        }
        long total = (ms + 500L) / 1000L;
        long minutes = total / 60L;
        long seconds = total % 60L;
        if (minutes >= 60L) {
            long hours = minutes / 60L;
            minutes = minutes % 60L;
            return hours + ":" + pad(minutes) + ":" + pad(seconds);
        }
        return minutes + ":" + pad(seconds);
    }

    /**
     * kbps → {@code 320kbps}。
     *
     * @return 格式化结果；{@code kbps <= 0} 返回空串（未知）
     */
    public static String bitrate(int kbps) {
        return kbps > 0 ? kbps + "kbps" : "";
    }

    private static String pad(long v) {
        return v < 10L ? "0" + v : String.valueOf(v);
    }
}
