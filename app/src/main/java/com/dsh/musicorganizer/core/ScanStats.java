package com.dsh.musicorganizer.core;

/**
 * 扫描统计（纯 Java，方便在桌面 JVM 里单测）。
 *
 * <p>原先是 {@code Scanner.Stats} 的静态内部类，但 {@code Scanner} 依赖 Android 的
 * {@code ContentResolver}，一旦测试里 new 它就得拉 android.jar 进来。把这块数据单独拎出来，
 * 快照序列化（{@link ScanSnapshot}）就能在纯 JVM 里跑回归。
 */
public class ScanStats {

    /** 扫到的音频文件总数（含已归位 / 未识别里的），也就是用户口中的「曲目数」。 */
    public int audio;
    /** 扫到的歌词文件数（.lrc 等）。整理时会跟着同基名的音频一起搬，但不算曲目。 */
    public int lyrics;
    /** 待整理的音频文件数（跳过已归位 / 未识别之后的剩余）。 */
    public int files;
    public int groups;
    public int skippedArtist;
    public int skippedUnrecognized;
    public int ignored;

    public String summary() {
        StringBuilder sb = new StringBuilder();
        if (audio > 0 || lyrics > 0) {
            // 曲目数只算音频：以前把 .lrc 也算进「文件」，911 首歌会显示成 1493 个文件，
            // 和系统播放器对不上，用户直接怀疑漏扫了。
            sb.append("曲目 ").append(audio).append(" 首");
            if (lyrics > 0) {
                sb.append(" · 歌词 ").append(lyrics).append(" 个");
            }
        } else {
            sb.append("共 ").append(files).append(" 个文件");
        }
        sb.append(" · 待整理 ").append(files).append(" 个文件 / ").append(groups).append(" 组");
        sb.append("；跳过已归位 ").append(skippedArtist)
                .append("，跳过未识别 ").append(skippedUnrecognized)
                .append("，忽略非音乐 ").append(ignored);
        return sb.toString();
    }
}
