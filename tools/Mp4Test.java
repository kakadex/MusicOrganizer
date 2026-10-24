import com.dsh.musicorganizer.core.CoverArt;
import com.dsh.musicorganizer.core.Mp4;
import com.dsh.musicorganizer.core.Tags;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.RandomAccessFile;

/**
 * MP4 / M4A 标签写入回归测试（纯 JVM，自己合成一个最小 MP4）。
 *
 * 重点不是「能写进去」，而是**采样偏移必须跟着挪**：
 * moov 变大后 mdat 后移，stco 里旧的 chunk offset 会全部指错位置 ——
 * 那种文件能打开、能读出标签，但播放/拖动会坏，是最难发现的一类损坏。
 *
 * 覆盖：
 *   1. moov 在前（faststart）布局：写入后 stco 偏移必须等于 mdat 实际位置
 *   2. moov 在尾（编码器默认）布局：偏移不变
 *   3. 合并语义：只改一个字段，其余字段与未知 atom 保留
 *   4. 封面写入 / 替换 / 删除（covr）
 *   5. UTF-8 中文、音轨号、年份
 */
public final class Mp4Test {

    private static int passed = 0;
    private static int failed = 0;

    public static void main(String[] args) throws Exception {
        File dir = new File(args.length > 0 ? args[0] : System.getProperty("java.io.tmpdir"));
        dir.mkdirs();

        moovFirst(dir);
        moovLast(dir);
        mergeSemantics(dir);
        coverRoundTrip(dir);
        utf8AndTrack(dir);
        cleanup(dir);

        System.out.println();
        System.out.println("结果：通过 " + passed + "，失败 " + failed);
        if (failed > 0) {
            System.exit(1);
        }
    }

    // ------------------------------------------------------------------

    private static void moovFirst(File dir) throws Exception {
        section("moov 在前：stco 偏移必须跟着挪");
        File f = new File(dir, "moov-first.m4a");
        synth(f, true);
        long beforeOffset = Mp4.chunkOffsets(f)[0];
        long beforeLen = f.length();
        check("初始 stco 指向 mdat 数据", beforeOffset == mdatPayloadOffset(f));

        java.util.Map<String, String> v = new java.util.HashMap<String, String>();
        v.put("title", "晴天");
        v.put("artist", "周杰伦");
        Mp4.write(f, v, null);
        Tags tags = Mp4.read(f);
        check("标题写进去了", "晴天".equals(tags.get("title")));
        check("艺人写进去了", "周杰伦".equals(tags.get("artist")));
        check("文件变大了（新增 udta/meta/ilst）", f.length() > beforeLen);
        check("stco 仍等于 mdat 实际位置", Mp4.chunkOffsets(f)[0] == mdatPayloadOffset(f));
        check("偏移确实移动过", Mp4.chunkOffsets(f)[0] != beforeOffset);
    }

    private static void moovLast(File dir) throws Exception {
        section("moov 在尾：偏移不应变化");
        File f = new File(dir, "moov-last.m4a");
        synth(f, false);
        long before = Mp4.chunkOffsets(f)[0];
        java.util.Map<String, String> v = new java.util.HashMap<String, String>();
        v.put("album", "叶惠美");
        Mp4.write(f, v, null);
        check("专辑写进去了", "叶惠美".equals(Mp4.read(f).get("album")));
        check("chunk offset 不变", Mp4.chunkOffsets(f)[0] == before);
        check("偏移仍指向 mdat", Mp4.chunkOffsets(f)[0] == mdatPayloadOffset(f));
    }

    private static void mergeSemantics(File dir) throws Exception {
        section("合并语义");
        File f = new File(dir, "merge.m4a");
        synth(f, true);
        java.util.Map<String, String> all = new java.util.HashMap<String, String>();
        all.put("title", "A");
        all.put("artist", "B");
        all.put("album", "C");
        all.put("year", "2003");
        all.put("genre", "Pop");
        Mp4.write(f, all, null);
        java.util.Map<String, String> one = new java.util.HashMap<String, String>();
        one.put("title", "A2");
        Mp4.write(f, one, null);
        Tags t = Mp4.read(f);
        check("改的字段生效", "A2".equals(t.get("title")));
        check("其余字段保留：艺人", "B".equals(t.get("artist")));
        check("其余字段保留：专辑", "C".equals(t.get("album")));
        check("其余字段保留：年份", "2003".equals(t.get("year")));
        check("其余字段保留：流派", "Pop".equals(t.get("genre")));
        check("偏移依然正确", Mp4.chunkOffsets(f)[0] == mdatPayloadOffset(f));
        // 空字符串 = 清除该字段
        java.util.Map<String, String> clear = new java.util.HashMap<String, String>();
        clear.put("genre", "");
        Mp4.write(f, clear, null);
        check("空值清除字段", Mp4.read(f).get("genre").isEmpty());
        check("清除后 title 还在", "A2".equals(Mp4.read(f).get("title")));
    }

    private static void coverRoundTrip(File dir) throws Exception {
        section("封面写入 / 替换 / 删除");
        File f = new File(dir, "cover.m4a");
        synth(f, true);
        byte[] jpeg = fakeJpeg(120, 90);
        check("初始无封面", !Mp4.hasCover(f));
        java.util.Map<String, String> v = new java.util.HashMap<String, String>();
        v.put("title", "有封面");
        Mp4.write(f, v, jpeg);
        check("写入后有封面", Mp4.hasCover(f));
        check("字段仍然正确", "有封面".equals(Mp4.read(f).get("title")));
        check("偏移仍然正确", Mp4.chunkOffsets(f)[0] == mdatPayloadOffset(f));
        long sizeWithCover = f.length();

        byte[] png = fakePng(200, 200);
        Mp4.write(f, new java.util.HashMap<String, String>(), png);
        check("换封面后仍有封面", Mp4.hasCover(f));
        check("换封面后文件大小变化", f.length() != sizeWithCover);
        check("偏移仍然正确", Mp4.chunkOffsets(f)[0] == mdatPayloadOffset(f));

        Mp4.write(f, new java.util.HashMap<String, String>(), new byte[0]);
        check("空数组删除封面", !Mp4.hasCover(f));
        check("删封面后字段还在", "有封面".equals(Mp4.read(f).get("title")));
        check("删封面后偏移仍然正确", Mp4.chunkOffsets(f)[0] == mdatPayloadOffset(f));
    }

    private static void utf8AndTrack(File dir) throws Exception {
        section("中文 / 音轨号 / 类型");
        File f = new File(dir, "utf8.m4a");
        synth(f, true);
        java.util.Map<String, String> v = new java.util.HashMap<String, String>();
        v.put("title", "打上花火");
        v.put("artist", "DAOKO × 米津玄師");
        v.put("track", "3/12");
        Mp4.write(f, v, null);
        Tags t = Mp4.read(f);
        check("中文标题往返", "打上花火".equals(t.get("title")));
        check("含特殊符号的艺人往返", "DAOKO × 米津玄師".equals(t.get("artist")));
        check("音轨号往返", "3".equals(t.get("track")));
        java.util.Map<String, String> lyr = new java.util.HashMap<String, String>();
        lyr.put("lyrics", "[00:01.00]第一句\n[00:02.00]第二句");
        Mp4.write(f, lyr, null);
        check("歌词写入 ©lyr", Mp4.read(f).get("lyrics").contains("第二句"));
    }

    private static void cleanup(File dir) {
        section("清理");
        int n = 0;
        File[] files = dir.listFiles();
        if (files != null) {
            for (File f : files) {
                if (f.getName().endsWith(".m4a") && f.delete()) {
                    n++;
                }
            }
        }
        check("临时文件已清理", n >= 5);
    }

    // ------------------------------------------------------------------
    // 合成一个最小 MP4：ftyp + [moov] + mdat（或 ftyp + mdat + moov）
    // ------------------------------------------------------------------

    private static void synth(File file, boolean moovFirst) throws Exception {
        byte[] ftyp = atom("ftyp", concat(ascii("M4A "), be32(0x200), ascii("M4A mp42")));
        byte[] mdatPayload = new byte[64];
        for (int i = 0; i < mdatPayload.length; i++) {
            mdatPayload[i] = (byte) (i * 3);
        }
        byte[] mdat = atom("mdat", mdatPayload);

        // 先用占位偏移算出 moov 长度（stco 内容长度与数值无关）
        byte[] moov = buildMoov(0);
        long mdatPayloadOffset = moovFirst
                ? ftyp.length + moov.length + 8            // ftyp + moov + mdat 头
                : ftyp.length + 8;                          // ftyp + mdat 头
        moov = buildMoov(mdatPayloadOffset);

        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write(ftyp);
        if (moovFirst) {
            out.write(moov);
            out.write(mdat);
        } else {
            out.write(mdat);
            out.write(moov);
        }
        FileOutputStream fos = new FileOutputStream(file);
        try {
            fos.write(out.toByteArray());
        } finally {
            fos.close();
        }
    }

    /** mdat 里第一个采样数据的真实文件偏移（测试自己算，不信任被测代码）。 */
    private static long mdatPayloadOffset(File file) throws Exception {
        RandomAccessFile raf = new RandomAccessFile(file, "r");
        try {
            long len = file.length();
            byte[] head = new byte[8];
            long pos = 0;
            while (pos + 8 <= len) {
                raf.seek(pos);
                raf.readFully(head);
                long size = ((head[0] & 0xFFL) << 24) | ((head[1] & 0xFFL) << 16)
                        | ((head[2] & 0xFFL) << 8) | (head[3] & 0xFFL);
                String type = new String(head, 4, 4, "ISO-8859-1");
                if ("mdat".equals(type)) {
                    return pos + 8;
                }
                if (size <= 0) {
                    break;
                }
                pos += size;
            }
        } finally {
            raf.close();
        }
        return -1;
    }

    private static byte[] buildMoov(long chunkOffset) {
        byte[] stco = atom("stco", concat(be32(0), be32(1), be32(chunkOffset)));
        byte[] stbl = atom("stbl", stco);
        byte[] minf = atom("minf", stbl);
        byte[] mdia = atom("mdia", minf);
        byte[] trak = atom("trak", mdia);
        byte[] mvhd = atom("mvhd", new byte[100]);
        return atom("moov", concat(mvhd, trak));
    }

    private static byte[] fakeJpeg(int w, int h) {
        // FFD8 + SOF0(精度8, 高, 宽, 3 分量) + FFD9
        byte[] sof = new byte[]{
                (byte) 0xFF, (byte) 0xC0, 0x00, 0x11, 0x08,
                (byte) ((h >> 8) & 0xFF), (byte) (h & 0xFF),
                (byte) ((w >> 8) & 0xFF), (byte) (w & 0xFF),
                0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01,
        };
        return concat(new byte[]{(byte) 0xFF, (byte) 0xD8}, sof,
                new byte[]{(byte) 0xFF, (byte) 0xD9});
    }

    private static byte[] fakePng(int w, int h) {
        byte[] sig = new byte[]{(byte) 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A};
        byte[] ihdr = atom("IHDR", concat(be32(w), be32(h),
                new byte[]{8, 6, 0, 0, 0}, new byte[4]));
        return concat(sig, ihdr);
    }

    // ---- 位工具 ----

    private static byte[] atom(String type, byte[] payload) {
        byte[] out = new byte[8 + payload.length];
        long size = out.length;
        out[0] = (byte) ((size >> 24) & 0xFF);
        out[1] = (byte) ((size >> 16) & 0xFF);
        out[2] = (byte) ((size >> 8) & 0xFF);
        out[3] = (byte) (size & 0xFF);
        byte[] t = ascii(type);
        System.arraycopy(t, 0, out, 4, 4);
        System.arraycopy(payload, 0, out, 8, payload.length);
        return out;
    }

    private static byte[] be32(long v) {
        return new byte[]{(byte) ((v >> 24) & 0xFF), (byte) ((v >> 16) & 0xFF),
                (byte) ((v >> 8) & 0xFF), (byte) (v & 0xFF)};
    }

    private static byte[] ascii(String s) {
        byte[] out = new byte[s.length()];
        for (int i = 0; i < s.length(); i++) {
            out[i] = (byte) s.charAt(i);
        }
        return out;
    }

    private static byte[] concat(byte[]... parts) {
        int total = 0;
        for (byte[] p : parts) {
            total += p.length;
        }
        byte[] out = new byte[total];
        int off = 0;
        for (byte[] p : parts) {
            System.arraycopy(p, 0, out, off, p.length);
            off += p.length;
        }
        return out;
    }

    private static void section(String title) {
        System.out.println("[ " + title + " ]");
    }

    private static void check(String name, boolean ok) {
        if (ok) {
            passed++;
            System.out.println("  ok   " + name);
        } else {
            failed++;
            System.out.println("  FAIL " + name);
        }
    }
}
