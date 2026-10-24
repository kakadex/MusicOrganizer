package com.dsh.musicorganizer.core;

/**
 * 音频平均码率估算（v0.1.76）。
 *
 * <p><b>为什么不用系统的 {@code METADATA_KEY_BITRATE}</b>：对 VBR（可变码率）MP3，
 * 不少系统的解析器报的是「首帧码率」或「Xing 帧自己的码率」，而不是整首的平均值。
 * 实测一首 171 kbps 的 VBR 歌，系统报 32 kbps —— 差了五倍。播放器显示的是
 * 平均值，因为它们自己按 Xing/帧数算。
 *
 * <p>这里给 MP3 家族（MPEG1/2/2.5 Layer I~III）算平均值，两条路：
 * <ol>
 *   <li><b>Xing / Info / VBRI 头</b>：编码器写好的「总帧数 + 音频字节数」，
 *       平均码率 = 字节数 × 8 ÷ 时长，最准；</li>
 *   <li>没有 VBR 头（CBR 常见）：用「音频字节数 ÷ 时长」，
 *       音频字节数 = 文件大小 − ID3v2 标签长度。</li>
 * </ol>
 *
 * <p>纯 JVM、不碰 Android API —— 可以直接进离线回归（{@code tools/BitrateTest.java}）。
 */
public final class Bitrate {

    /** MPEG1 Layer III 码率表（kbps）。 */
    private static final int[] BR_V1_L3 =
            {0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320};
    /** MPEG1 Layer II。 */
    private static final int[] BR_V1_L2 =
            {0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384};
    /** MPEG1 Layer I。 */
    private static final int[] BR_V1_L1 =
            {0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448};
    /** MPEG2 / MPEG2.5 Layer II & III。 */
    private static final int[] BR_V2 =
            {0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160};
    /** MPEG2 / MPEG2.5 Layer I。 */
    private static final int[] BR_V2_L1 =
            {0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256};

    /** 采样率表：按 (b1 >> 3) & 3 索引；1 是保留值。 */
    private static final int[][] SAMPLE_RATES = {
            {11025, 12000, 8000},   // MPEG2.5
            {0, 0, 0},              // 保留
            {22050, 24000, 16000},  // MPEG2
            {44100, 48000, 32000}   // MPEG1
    };

    private Bitrate() {
    }

    /**
     * 算 MP3 的平均码率。
     *
     * @param head       文件头部字节（建议 ≥ 64KB，够覆盖 ID3v2 + 首帧 + Xing 头）
     * @param fileSize   整个文件的字节数
     * @param durationMs 时长（毫秒）；只有缺少 VBR 头时才会用到，≤0 表示未知
     * @return kbps（四舍五入）；解析不出来返回 0
     */
    public static long mp3Kbps(byte[] head, long fileSize, long durationMs) {
        return mp3Info(head, fileSize, durationMs)[0];
    }

    /**
     * 一次解析出码率和（可能更准的）时长。
     *
     * <p>为什么不只给码率：VBR 文件上系统报的时长是按它自己那个错的码率估出来的
     * （{@code 大小 ÷ 码率}），所以码率一错、时长跟着错。Xing 头里的帧数才是硬数据，
     * 顺手把时长也带回去，列表里「时长 · 质量」两个数才不会互相矛盾。
     *
     * @return {@code [kbps, durationMs]}；第二项为 0 表示这次没拿到更准的时长
     */
    public static long[] mp3Info(byte[] head, long fileSize, long durationMs) {
        long[] out = new long[]{0L, 0L};
        if (head == null || head.length < 4) {
            return out;
        }
        int tagBytes = id3v2Size(head);
        int offset = findFrame(head, tagBytes);
        if (offset < 0) {
            return out;
        }
        Frame frame = parseFrame(head, offset);
        if (frame == null) {
            return out;
        }
        // ① VBR 头：Xing / Info（LAME 系）或 VBRI（Fraunhofer）
        long[] vbr = vbrHeader(head, frame);
        if (vbr != null && vbr[0] > 0 && vbr[1] > 0) {
            double seconds = vbr[0] * (double) frame.samplesPerFrame / frame.sampleRate;
            if (seconds > 0.5d) {
                out[0] = Math.round(vbr[1] * 8.0d / seconds / 1000.0d);
                out[1] = Math.round(seconds * 1000.0d);
                return out;
            }
        }
        // ② 没有 VBR 头：音频字节 ÷ 时长（bits ÷ ms 就是 kbps）
        long audioBytes = fileSize > tagBytes ? fileSize - tagBytes : fileSize;
        if (audioBytes > 0 && durationMs > 0) {
            out[0] = Math.round(audioBytes * 8.0d / durationMs);
            return out;
        }
        // ③ 只能给首帧码率 —— CBR 情况下它就是整首的码率
        out[0] = frame.bitrateKbps;
        return out;
    }

    /**
     * 文件名是不是 MP3 家族。
     *
     * <p>刻意不用 {@link TagIO#extOf}：那个返回的是**带点的小写**扩展名（{@code ".mp3"}），
     * 上一版就是拿它跟 {@code "mp3"} 比，判断永远不成立，精确解析一次都没走到。
     * 这里自己取扩展名（不带点），两种写法都不再有机会出错。
     */
    public static boolean isMp3Name(String name) {
        if (name == null) {
            return false;
        }
        String lower = name.toLowerCase(java.util.Locale.ROOT);
        int dot = lower.lastIndexOf('.');
        if (dot < 0 || dot == lower.length() - 1) {
            return false;
        }
        String ext = lower.substring(dot + 1);
        return "mp3".equals(ext) || "mp2".equals(ext) || "mp1".equals(ext) || "mpa".equals(ext);
    }

    /** ID3v2 标签总长度（含 10 字节头；带 footer 再 +10）；没有返回 0。 */
    public static int id3v2Size(byte[] head) {
        if (head == null || head.length < 10) {
            return 0;
        }
        if (head[0] != 'I' || head[1] != 'D' || head[2] != '3') {
            return 0;
        }
        int flags = head[5] & 0xFF;
        int size = ((head[6] & 0x7F) << 21) | ((head[7] & 0x7F) << 14)
                | ((head[8] & 0x7F) << 7) | (head[9] & 0x7F);
        int total = 10 + size;
        if ((flags & 0x10) != 0) {
            total += 10; // footer present（v2.4）
        }
        return total;
    }

    /**
     * 要解析这帧，得读多少头部字节？
     *
     * <p>为什么需要这个：ID3 里塞一张大封面时，标签本身可能几百 KB，而调用方一般只读
     * 几十 KB 的头部 —— 第一帧根本不在窗口里，{@link #mp3Kbps} 只能返回 0，
     * 于是界面就退回系统那个可能是「某一帧」的码率（实测 171 被显示成 32）。
     * 调用方拿这个返回值补读一次即可。
     *
     * @param head 已经读到的头部（可以为 null）
     * @return 建议读取的字节数；0 表示当前这段已经够用（或压根没有标签）
     */
    public static int headBytesWanted(byte[] head) {
        if (head == null || head.length < 10) {
            return 0;
        }
        int tag = id3v2Size(head);
        if (tag <= 0 || tag + 4 <= head.length) {
            return 0;
        }
        return Math.min(tag + 64 * 1024, MAX_HEAD_BYTES);
    }

    /** 头部最多读这么多：再大就是异常文件了，不值得为它一次吃掉几十 MB 内存。 */
    public static final int MAX_HEAD_BYTES = 4 * 1024 * 1024;

    /** 从 from 开始找第一个合法帧同步头；找不到返回 -1。 */
    static int findFrame(byte[] head, int from) {
        int limit = head.length - 4;
        for (int i = Math.max(0, from); i <= limit; i++) {
            if ((head[i] & 0xFF) != 0xFF) {
                continue;
            }
            if (parseFrame(head, i) != null) {
                return i;
            }
        }
        return -1;
    }

    /** 解析指定位置的帧头；不是合法帧返回 null。 */
    static Frame parseFrame(byte[] head, int off) {
        if (off < 0 || off + 4 > head.length) {
            return null;
        }
        int b0 = head[off] & 0xFF;
        int b1 = head[off + 1] & 0xFF;
        int b2 = head[off + 2] & 0xFF;
        int b3 = head[off + 3] & 0xFF;
        if (b0 != 0xFF || (b1 & 0xE0) != 0xE0) {
            return null;
        }
        int versionBits = (b1 >> 3) & 0x03;   // 0=2.5 1=保留 2=MPEG2 3=MPEG1
        int layerBits = (b1 >> 1) & 0x03;     // 0=保留 1=III 2=II 3=I
        if (versionBits == 1 || layerBits == 0) {
            return null;
        }
        int layer = 4 - layerBits;            // 1/2/3
        int brIndex = (b2 >> 4) & 0x0F;
        int srIndex = (b2 >> 2) & 0x03;
        if (brIndex == 0 || brIndex == 15 || srIndex == 3) {
            return null;
        }
        boolean mpeg1 = versionBits == 3;
        int bitrateKbps;
        if (mpeg1) {
            bitrateKbps = layer == 1 ? BR_V1_L1[brIndex]
                    : (layer == 2 ? BR_V1_L2[brIndex] : BR_V1_L3[brIndex]);
        } else {
            bitrateKbps = layer == 1 ? BR_V2_L1[brIndex] : BR_V2[brIndex];
        }
        int sampleRate = SAMPLE_RATES[versionBits][srIndex];
        if (bitrateKbps <= 0 || sampleRate <= 0) {
            return null;
        }
        boolean padding = ((b2 >> 1) & 1) == 1;
        Frame f = new Frame();
        f.offset = off;
        f.layer = layer;
        f.bitrateKbps = bitrateKbps;
        f.sampleRate = sampleRate;
        f.padding = padding;
        f.channelMode = (b3 >> 6) & 0x03;     // 3 = 单声道
        f.mpeg1 = mpeg1;
        f.samplesPerFrame = layer == 1 ? 384 : (layer == 2 ? 1152 : (mpeg1 ? 1152 : 576));
        // 帧长：Layer I 按 4 字节槽算，II/III 用 144/72 系数
        if (layer == 1) {
            f.frameLength = (12 * bitrateKbps * 1000 / sampleRate + (padding ? 1 : 0)) * 4;
        } else if (mpeg1) {
            f.frameLength = 144 * bitrateKbps * 1000 / sampleRate + (padding ? 1 : 0);
        } else {
            f.frameLength = 72 * bitrateKbps * 1000 / sampleRate + (padding ? 1 : 0);
        }
        return f.frameLength > 4 ? f : null;
    }

    /**
     * 读 VBR 头。
     *
     * @return {@code [帧数, 音频字节数]}；没有返回 null
     */
    static long[] vbrHeader(byte[] head, Frame frame) {
        boolean mono = frame.channelMode == 3;
        // Xing/Info 紧跟在「帧头 + 边信息」之后
        int sideInfo = frame.mpeg1 ? (mono ? 17 : 32) : (mono ? 9 : 17);
        int xing = frame.offset + 4 + sideInfo;
        if (matches(head, xing, "Xing") || matches(head, xing, "Info")) {
            long[] out = readXing(head, xing + 4);
            if (out != null) {
                return out;
            }
        }
        // VBRI：固定在第 32 字节偏移处
        int vbri = frame.offset + 4 + 32;
        if (matches(head, vbri, "VBRI")) {
            long[] out = readVbri(head, vbri);
            if (out != null) {
                return out;
            }
        }
        return null;
    }

    private static long[] readXing(byte[] head, int flagsOff) {
        if (flagsOff + 8 > head.length) {
            return null;
        }
        int flags = ((head[flagsOff] & 0xFF) << 24) | ((head[flagsOff + 1] & 0xFF) << 16)
                | ((head[flagsOff + 2] & 0xFF) << 8) | (head[flagsOff + 3] & 0xFF);
        int pos = flagsOff + 4;
        long frames = 0L;
        long bytes = 0L;
        if ((flags & 0x01) != 0) {          // Frames 字段
            if (pos + 4 > head.length) {
                return null;
            }
            frames = readU32(head, pos);
            pos += 4;
        }
        if ((flags & 0x02) != 0) {          // Bytes 字段
            if (pos + 4 > head.length) {
                return null;
            }
            bytes = readU32(head, pos);
        }
        return frames > 0 && bytes > 0 ? new long[]{frames, bytes} : null;
    }

    private static long[] readVbri(byte[] head, int off) {
        // 结构：VBRI(4) 版本(2) 延迟(2) 质量(2) 字节数(4) 帧数(4)
        if (off + 18 > head.length) {
            return null;
        }
        long bytes = readU32(head, off + 10);
        long frames = readU32(head, off + 14);
        return frames > 0 && bytes > 0 ? new long[]{frames, bytes} : null;
    }

    private static boolean matches(byte[] data, int off, String tag) {
        if (off < 0 || off + tag.length() > data.length) {
            return false;
        }
        for (int i = 0; i < tag.length(); i++) {
            if ((data[off + i] & 0xFF) != tag.charAt(i)) {
                return false;
            }
        }
        return true;
    }

    private static long readU32(byte[] data, int off) {
        return ((long) (data[off] & 0xFF) << 24) | ((data[off + 1] & 0xFF) << 16)
                | ((data[off + 2] & 0xFF) << 8) | (data[off + 3] & 0xFF);
    }

    /** 一帧帧头的关键参数。 */
    static final class Frame {
        int offset;
        int layer;
        int bitrateKbps;
        int sampleRate;
        int samplesPerFrame;
        int frameLength;
        int channelMode;
        boolean mpeg1;
        boolean padding;
    }
}
