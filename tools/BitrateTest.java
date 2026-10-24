import com.dsh.musicorganizer.core.Bitrate;

/**
 * MP3 平均码率回归（纯 JVM，v0.1.76）。
 *
 * <p>背景：VBR 的 MP3 用系统接口读码率经常拿到「首帧」或「Xing 帧自己的」码率。
 * 实测一首 171 kbps 的歌在手机上被报成 32 kbps。这里用**合成帧头**（不掺任何真实音频样本）
 * 把「Xing / Info / VBRI / 无 VBR 头 / 单声道 / ID3 footer」几条路都钉死。
 *
 * <p>合成数据里的数值取自真实曲库观测到的那一例：帧数 9901、音频字节 5513329、44.1kHz，
 * 期望 171 kbps。
 */
public class BitrateTest {

    private static int pass = 0;
    private static int fail = 0;

    public static void main(String[] args) {
        // 1) VBR + Xing：帧数 + 字节数 → 平均值（不是首帧的 192）
        byte[] xing = vbrHead(94, "Xing", 9901, 5513329, false);
        check("Xing 平均码率 171", Bitrate.mp3Kbps(xing, 5513433L, 0L) == 171);
        check("Xing 不采用首帧 192", Bitrate.mp3Kbps(xing, 5513433L, 0L) != 192);

        // 2) Info（CBR 也有，LAME 写的另一种标记）同样按帧数算
        byte[] info = vbrHead(0, "Info", 9901, 5513329, false);
        check("Info 平均码率 171", Bitrate.mp3Kbps(info, 5513329L, 0L) == 171);

        // 3) 单声道：边信息 17 字节，Xing 位置要跟着变
        byte[] mono = vbrHead(0, "Xing", 9901, 5513329, true);
        check("单声道 Xing 也能找到", Bitrate.mp3Kbps(mono, 5513329L, 0L) == 171);

        // 4) 没有 VBR 头：退回「音频字节 ÷ 时长」（128 kbps CBR）
        long cbrBytes = 128L * 60000L / 8L;   // 60 秒 128kbps
        byte[] cbr = cbrHead(0, 0x90);        // brIndex 9 = 128kbps
        check("CBR 128（无 Xing）", Bitrate.mp3Kbps(cbr, cbrBytes, 60000L) == 128);
        check("CBR 首帧码率作兜底", Bitrate.mp3Kbps(cbr, 0L, 0L) == 128);

        // 5) ID3v2 标签要从音频字节里扣掉（否则大封面会把码率算高）
        byte[] withTag = cbrHead(2000, 0x90);
        long audioOnly = 128L * 60000L / 8L;
        check("ID3v2 2000 字节被扣除",
                Bitrate.mp3Kbps(withTag, audioOnly + 2000L, 60000L) == 128);

        // 6) VBRI（Fraunhofer 的 VBR 头）
        byte[] vbri = vbriHead(9901, 5513329);
        check("VBRI 平均码率 171", Bitrate.mp3Kbps(vbri, 5513329L, 0L) == 171);

        // 7) 容错：不是 MP3 一律返回 0，绝不抛异常
        check("空数组返回 0", Bitrate.mp3Kbps(new byte[0], 1000L, 1000L) == 0);
        check("null 返回 0", Bitrate.mp3Kbps(null, 1000L, 1000L) == 0);
        check("全零数据返回 0", Bitrate.mp3Kbps(new byte[512], 512L, 1000L) == 0);
        byte[] flac = new byte[64];
        flac[0] = 'f';
        flac[1] = 'L';
        flac[2] = 'a';
        flac[3] = 'C';
        check("FLAC 头返回 0", Bitrate.mp3Kbps(flac, 1024L, 1000L) == 0);

        // 8) ID3v2 长度：普通 / 带 footer
        check("ID3v2 长度 94", Bitrate.id3v2Size(vbrHead(94, "Xing", 1, 1, false)) == 94);
        check("ID3v2 footer 多 10 字节", Bitrate.id3v2Size(id3Node(94, true)) == 104);

        // 9) 一并带出更准的时长（Xing 帧数 ÷ 采样率），系统的时长是拿错码率倒推的
        long[] xi = Bitrate.mp3Info(xing, 5513433L, 250000L);
        check("Xing 码率 171", xi[0] == 171);
        check("Xing 时长约 258.6 秒", Math.abs(xi[1] - 258635L) <= 5L);
        check("无 VBR 头时时长给 0", Bitrate.mp3Info(cbr, cbrBytes, 60000L)[1] == 0L);

        // 9.5) 标签比读到的窗口还大时（内嵌大封面），要告诉调用方补读多少
        // 9.5) 标签比读到的窗口还大时（内嵌大封面），要告诉调用方补读多少
        byte[] hdBig = id3Node(200 * 1024, false);
        byte[] hdCut = new byte[1024];
        System.arraycopy(hdBig, 0, hdCut, 0, hdCut.length);
        int hdWant = Bitrate.headBytesWanted(hdCut);
        check("大标签要求补读", hdWant >= 200 * 1024);
        check("补读量不超过上限", hdWant <= Bitrate.MAX_HEAD_BYTES);
        check("标签已覆盖时不用补读",
                Bitrate.headBytesWanted(vbrHead(94, "Xing", 1, 1, false)) == 0);
        check("没有 ID3 时不用补读", Bitrate.headBytesWanted(cbr) == 0);
        check("null 不用补读", Bitrate.headBytesWanted(null) == 0);
        check("太短的头部不用补读", Bitrate.headBytesWanted(new byte[4]) == 0);

        // 10) 扩展名判断 —— 这里踩过坑：extOf 返回的是带点的 ".mp3"
        check(".mp3 认作 MP3", Bitrate.isMp3Name("歌.mp3"));
        check("大写 .MP3 也认", Bitrate.isMp3Name("歌.MP3"));
        check(".mp2 认作 MP3", Bitrate.isMp3Name("a.mp2"));
        check(".flac 不算 MP3", !Bitrate.isMp3Name("歌.flac"));
        check(".m4a 不算 MP3", !Bitrate.isMp3Name("歌.m4a"));
        check("无扩展名不算", !Bitrate.isMp3Name("歌"));
        check("空串不算", !Bitrate.isMp3Name(""));
        check("null 不算", !Bitrate.isMp3Name(null));

        System.out.println("结果：通过 " + pass + "，失败 " + fail);
        if (fail > 0) {
            System.exit(1);
        }
    }

    // ------------------------------------------------------------------
    // 造数据（不依赖任何真实音频文件）
    // ------------------------------------------------------------------

    /**
     * 造一个 MP3 头部：ID3v2 标签（tagSize 字节）+ 一帧 MPEG1 Layer III + VBR 头。
     *
     * @param tagSize   ID3v2 标签总长度（0 表示没有标签）
     * @param marker    "Xing" / "Info"
     * @param frames    帧数
     * @param bytes     音频字节数
     * @param mono      是否单声道（边信息长度 17 而不是 32）
     */
    private static byte[] vbrHead(int tagSize, String marker, long frames, long bytes, boolean mono) {
        int side = mono ? 17 : 32;
        int frameAt = Math.max(0, tagSize);
        int xingAt = frameAt + 4 + side;
        int size = xingAt + 8 + 8 + 64;
        byte[] out = new byte[size];
        if (tagSize > 0) {
            byte[] node = id3Node(tagSize, false);
            System.arraycopy(node, 0, out, 0, Math.min(node.length, tagSize));
        }
        // 帧头：0xFF 0xFB（MPEG1 Layer III 无 CRC）0xB0（192kbps / 44.1kHz）0x00|0xC0（声道模式）
        out[frameAt] = (byte) 0xFF;
        out[frameAt + 1] = (byte) 0xFB;
        out[frameAt + 2] = (byte) 0xB0;
        out[frameAt + 3] = (byte) (mono ? 0xC0 : 0x00);
        for (int i = 0; i < marker.length(); i++) {
            out[xingAt + i] = (byte) marker.charAt(i);
        }
        writeU32(out, xingAt + 4, 0x03);       // flags: 同时有 frames / bytes
        writeU32(out, xingAt + 8, frames);
        writeU32(out, xingAt + 12, bytes);
        return out;
    }

    /** 造一个 MPEG1 Layer III 头部（只有 ID3 + 一帧头），b2 是比特率/采样率字节。 */
    private static byte[] cbrHead(int tagSize, int b2) {
        byte[] out = new byte[Math.max(0, tagSize) + 512];
        if (tagSize > 0) {
            byte[] node = id3Node(tagSize, false);
            System.arraycopy(node, 0, out, 0, Math.min(node.length, tagSize));
        }
        out[tagSize] = (byte) 0xFF;
        out[tagSize + 1] = (byte) 0xFB;
        out[tagSize + 2] = (byte) b2;
        out[tagSize + 3] = (byte) 0x00;
        return out;
    }

    /** 造 VBRI 版本的头部。 */
    private static byte[] vbriHead(long frames, long bytes) {
        int frameAt = 0;
        int vbriAt = frameAt + 4 + 32;
        byte[] out = new byte[vbriAt + 18 + 32];
        out[frameAt] = (byte) 0xFF;
        out[frameAt + 1] = (byte) 0xFB;
        out[frameAt + 2] = (byte) 0xB0;
        out[frameAt + 3] = (byte) 0x00;
        out[vbriAt] = 'V';
        out[vbriAt + 1] = 'B';
        out[vbriAt + 2] = 'R';
        out[vbriAt + 3] = 'I';
        writeU32(out, vbriAt + 10, bytes);
        writeU32(out, vbriAt + 14, frames);
        return out;
    }

    /** 只造 ID3v2 头（含 flags 与 syncsafe 长度）。 */
    private static byte[] id3Node(int totalSize, boolean footer) {
        int payload = Math.max(0, totalSize - 10);
        byte[] out = new byte[Math.max(totalSize, 10)];
        out[0] = 'I';
        out[1] = 'D';
        out[2] = '3';
        out[3] = 4;                     // v2.4
        out[4] = 0;
        out[5] = (byte) (footer ? 0x10 : 0x00);
        out[6] = (byte) ((payload >> 21) & 0x7F);
        out[7] = (byte) ((payload >> 14) & 0x7F);
        out[8] = (byte) ((payload >> 7) & 0x7F);
        out[9] = (byte) (payload & 0x7F);
        return out;
    }

    private static void writeU32(byte[] data, int off, long v) {
        data[off] = (byte) ((v >> 24) & 0xFF);
        data[off + 1] = (byte) ((v >> 16) & 0xFF);
        data[off + 2] = (byte) ((v >> 8) & 0xFF);
        data[off + 3] = (byte) (v & 0xFF);
    }

    private static void check(String label, boolean ok) {
        if (ok) {
            pass++;
            System.out.println("  ok   " + label);
        } else {
            fail++;
            System.out.println("  FAIL " + label);
        }
    }
}
