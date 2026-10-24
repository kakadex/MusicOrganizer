package com.dsh.musicorganizer.ui;

import android.content.ContentResolver;
import android.media.MediaMetadataRetriever;
import android.os.ParcelFileDescriptor;

import com.dsh.musicorganizer.core.Bitrate;
import com.dsh.musicorganizer.core.Storage;
import com.dsh.musicorganizer.core.VFile;

/**
 * 读音频的技术参数：时长（毫秒）与码率（kbps）。
 *
 * <p>从 {@code BrowsePage} 里抽出来（v0.1.53），因为单曲详情面板也要用：
 * 列表行是「滚到哪读到哪」，详情面板打开时那一条可能还没轮到，于是时长/质量显示空。
 *
 * <p>两个坑写在这里免得再踩：
 * <ul>
 *   <li>{@code METADATA_KEY_BITRATE} 返回的是 <b>bps</b>（320000），要除 1000；</li>
 *   <li>{@code release()} 在部分系统版本抛 {@code IOException}，必须自己吞掉。</li>
 * </ul>
 *
 * <p><b>为什么 MP3 不用系统的码率（v0.1.76）</b>：VBR 文件上
 * {@code METADATA_KEY_BITRATE} 常常报的是首帧或 Xing 帧自己的码率 —— 实测 171 kbps 的歌
 * 报成 32 kbps，而且系统给的**时长**也是拿这个错码率倒推出来的（大小 ÷ 码率），
 * 于是「时长 / 质量」两个数一起错。MP3 家族一律以 {@link Bitrate} 自己解析的
 * Xing / VBRI / 帧信息为准，系统值只当兜底。
 */
public final class AudioInfo {

    /** {时长毫秒, 码率 kbps}；读不出来是 {0, 0}。 */
    public static final long[] ZERO = new long[]{0L, 0L};

    /** 读 MP3 帧头用的头部字节数：ID3v2 + 首帧 + Xing 都在最前面，64KB 富余。 */
    private static final int HEAD_BYTES = 64 * 1024;

    private AudioInfo() {
    }

    public static long[] read(ContentResolver resolver, Storage st, VFile f) {
        if (resolver == null || st == null || f == null) {
            return ZERO;
        }
        MediaMetadataRetriever r = new MediaMetadataRetriever();
        ParcelFileDescriptor pfd = null;
        try {
            pfd = resolver.openFileDescriptor(st.documentUri(f), "r");
            if (pfd == null) {
                return ZERO;
            }
            r.setDataSource(pfd.getFileDescriptor());
            long durationMs = parseLong(r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION));
            long systemKbps = parseLong(r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_BITRATE)) / 1000L;

            if (Bitrate.isMp3Name(f.name)) {
                long[] info = ZERO;
                try {
                    byte[] head = st.headBytes(f, HEAD_BYTES);
                    // 大封面（ID3 里塞了几百 KB 的图）时，标签长度会超过我们读到的 64KB，
                    // 第一帧根本不在窗口里 —— 按标签长度补读一次，否则解析必然失败、
                    // 界面就会退回系统那个"某一帧"的码率。
                    int want = Bitrate.headBytesWanted(head);
                    if (want > 0 && head != null && f.size > head.length) {
                        head = st.headBytes(f, (int) Math.min(want, f.size));
                    }
                    info = Bitrate.mp3Info(head, f.size, durationMs);
                } catch (Throwable ignored) {
                    // 读头失败就退回粗略估算，不能因为解析失败让整行没数据
                }
                if (info[1] > 0) {
                    durationMs = pickDuration(durationMs, info[1]);
                }
                long kbps = info[0];
                if (kbps <= 0 && f.size > 0 && durationMs > 0) {
                    // 解析不出来（罕见标签写法 / 读取失败）：宁可给「大小 ÷ 时长」的粗估值，
                    // 也不用系统那个可能只是某一帧的码率。
                    kbps = Math.round(f.size * 8.0d / durationMs);
                }
                if (kbps <= 0) {
                    kbps = systemKbps;
                }
                if (systemKbps > 0 && kbps > 0 && Math.abs(kbps - systemKbps) * 4 > kbps) {
                    // 差得远就记一条：下次用户再报「码率不对」时能直接看出是解析失败还是回退了
                    com.dsh.musicorganizer.core.AppLog.write(
                            com.dsh.musicorganizer.core.AppLog.INFO, "码率",
                            f.name + "：系统 " + systemKbps + " → 采用 " + kbps
                                    + "（时长 " + durationMs + "ms，头 " + (info[0] > 0 ? "解析成功" : "未解析") + "）");
                }
                return new long[]{durationMs, kbps};
            }
            return new long[]{durationMs, fixedBitrate(f, durationMs, systemKbps)};
        } catch (Throwable ignored) {
            return ZERO;
        } finally {
            if (pfd != null) {
                try {
                    pfd.close();
                } catch (Throwable ignored) {
                    // 关不掉就算了：fd 泄漏总比把读取结果丢了强
                }
            }
            try {
                r.release();
            } catch (Throwable ignored) {
                // 部分系统版本 release() 抛 IOException
            }
        }
    }

    private static long parseLong(String s) {
        if (s == null || s.isEmpty()) {
            return 0L;
        }
        try {
            return Long.parseLong(s.trim());
        } catch (NumberFormatException e) {
            return 0L;
        }
    }

    /**
     * 时长取谁：Xing 里是「总帧数 ÷ 采样率」，是硬数据；系统那个数是拿码率倒推的。
     *
     * <p>只在两者相差不大（≤20% 或 2 秒内）时才采用 Xing 的值 —— 相差很大通常说明
     * VBR 头本身不可信（文件被截断 / 拼接），这时宁可信系统。
     */
    private static long pickDuration(long systemMs, long xingMs) {
        if (systemMs <= 0) {
            return xingMs;
        }
        long diff = Math.abs(xingMs - systemMs);
        if (diff <= Math.max(2000L, systemMs / 5)) {
            return xingMs;
        }
        return systemMs;
    }

    /**
     * 非 MP3 的码率兜底（v0.1.76）：系统值和自己按「大小 ÷ 时长」估的差 25% 以内就用系统值，
     * 差得远说明系统那个数不可信，用估算值。
     *
     * <p>FLAC / M4A / WAV 的系统码率本来就准，一般走不到重算这一步。
     */
    private static long fixedBitrate(VFile f, long durationMs, long systemKbps) {
        if (f == null || durationMs <= 0 || f.size <= 0) {
            return systemKbps;
        }
        long approx = Math.round(f.size * 8.0d / durationMs);
        if (approx <= 0) {
            return systemKbps;
        }
        if (systemKbps >= approx * 3 / 4 && systemKbps <= approx * 5 / 4) {
            return systemKbps;
        }
        return approx;
    }
}
