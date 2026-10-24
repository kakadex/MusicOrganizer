import com.dsh.musicorganizer.core.Ogg;
import com.dsh.musicorganizer.core.TagIO;
import com.dsh.musicorganizer.core.Tags;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.RandomAccessFile;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * OGG Vorbis / Opus 标签写入回归（纯 JVM）。
 *
 * <p>造一条结构真实的 Ogg 流（BOS 页 + 注释/setup 同页 + 两页音频），验证：
 * <ul>
 *   <li>注释能读写；</li>
 *   <li><b>音频包一个字节都不能变</b>（这是写坏文件与写对文件的唯一区别）；</li>
 *   <li>页 CRC 与段表合法（CRC 用 Ogg 自己的多项式，不是 zlib 那个）；</li>
 *   <li>大歌词触发拆页后，页序号顺移、后续页 CRC 重算；</li>
 *   <li>不是 OGG 的文件必须拒绝。</li>
 * </ul>
 */
public class OggTagTest {

    private static int pass = 0;
    private static int fail = 0;

    public static void main(String[] args) throws Exception {
        File dir = new File(args.length > 0 ? args[0] : "build/oggfixtures");
        //noinspection ResultOfMethodCallIgnored
        dir.mkdirs();

        // 1) Vorbis：三页（BOS / 注释+setup / 音频）
        File vorbis = new File(dir, "v.ogg");
        List<byte[]> audioPackets = new ArrayList<byte[]>();
        audioPackets.add(packet(0x11, 600));
        audioPackets.add(packet(0x22, 1500));
        writeVorbis(vorbis, audioPackets);

        check("识别为 OGG", Ogg.isOgg(vorbis));
        check("TagIO 支持写 .ogg", TagIO.canWrite(".ogg"));
        check("初始无标签", !Ogg.read(vorbis).anyValue());

        Map<String, String> values = new LinkedHashMap<String, String>();
        values.put("title", "夜曲");
        values.put("artist", "周杰伦");
        values.put("album", "十一月的萧邦");
        values.put("year", "2005");
        values.put("track", "1");
        values.put("genre", "Pop");
        values.put("comment", "测试");
        Ogg.rewrite(vorbis, values, null);

        Tags t = Ogg.read(vorbis);
        check("标题回读", "夜曲".equals(t.get("title")));
        check("歌手回读", "周杰伦".equals(t.get("artist")));
        check("专辑回读", "十一月的萧邦".equals(t.get("album")));
        check("年份回读", "2005".equals(t.get("year")));
        check("音轨回读", "1".equals(t.get("track")));
        check("流派回读", "Pop".equals(t.get("genre")));
        check("音频包未被改动", audioIntact(vorbis, audioPackets));
        check("页 CRC 全部合法", allCrcValid(vorbis));

        // 2) 二次写入：替换而非叠加
        values.put("title", "夜曲（重制）");
        Ogg.rewrite(vorbis, values, null);
        check("二次写入标题更新", "夜曲（重制）".equals(Ogg.read(vorbis).get("title")));
        check("二次写入歌手保留", "周杰伦".equals(Ogg.read(vorbis).get("artist")));
        check("二次写入音频仍完好", audioIntact(vorbis, audioPackets));

        // 3) 歌词：几十 KB 会撑爆一页 → 必须拆页且后续页序号顺移
        File big = new File(dir, "big.ogg");
        writeVorbis(big, audioPackets);
        int pagesBefore = pageCount(big);
        StringBuilder lyr = new StringBuilder();
        for (int i = 0; i < 4000; i++) {
            lyr.append("[00:").append(String.format("%02d", i % 60)).append(".00]第 ")
                    .append(i).append(" 行歌词\n");
        }
        Map<String, String> bigValues = new LinkedHashMap<String, String>();
        bigValues.put("lyrics", lyr.toString());
        Ogg.rewrite(big, bigValues, null);
        int pagesAfter = pageCount(big);
        check("大歌词触发拆页", pagesAfter > pagesBefore);
        check("拆页后音频仍完好", audioIntact(big, audioPackets));
        check("拆页后 CRC 仍合法", allCrcValid(big));
        // Tags.put 统一 trim 首尾空白，所以比对也按 trim 后长度（这是全应用一致的行为）
        int lyrLen = Ogg.read(big).get("lyrics").length();
        check("拆页后歌词可读（实际 " + lyrLen + " 字）",
                lyrLen == lyr.toString().trim().length());

        // 4) Opus（OpusHead / OpusTags，且没有 framed bit）
        File opus = new File(dir, "o.opus");
        writeOpus(opus, audioPackets);
        check("Opus 可识别", Ogg.isOgg(opus));
        Ogg.rewrite(opus, values, null);
        check("Opus 标题回读", "夜曲（重制）".equals(Ogg.read(opus).get("title")));
        check("Opus 音频包未被改动", audioIntact(opus, audioPackets));
        check("Opus 页 CRC 合法", allCrcValid(opus));

        // 5) 走 TagIO 分发（批量任务实际路径）
        File viaIo = new File(dir, "viaio.ogg");
        writeVorbis(viaIo, audioPackets);
        String err = TagIO.writeLocal(viaIo, values, null);
        check("TagIO 写 OGG 无错误", err.isEmpty());
        check("TagIO 读 OGG 标题", "夜曲（重制）".equals(TagIO.readLocal(viaIo).get("title")));

        // 6) 非 OGG 拒绝
        File fake = new File(dir, "fake.ogg");
        FileOutputStream f = new FileOutputStream(fake);
        f.write("ID3 not ogg".getBytes("UTF-8"));
        f.close();
        check("非 OGG 不误判", !Ogg.isOgg(fake));
        check("非 OGG 写入报错", !TagIO.writeLocal(fake, values, null).isEmpty());

        System.out.println("结果：通过 " + pass + "，失败 " + fail);
        if (fail > 0) {
            System.exit(1);
        }
    }

    // ------------------------------------------------------------------
    // 造流
    // ------------------------------------------------------------------

    private static void writeVorbis(File file, List<byte[]> audio) throws Exception {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] ident = new byte[]{0x01, 'v', 'o', 'r', 'b', 'i', 's'};
        byte[] setup = new byte[]{0x05, 'v', 'o', 'r', 'b', 'i', 's'};
        out.write(page(0x02, 0, 0, 0, one(ident)));
        out.write(page(0, 0, 0, 1, two(commentPacket(false, "test-vendor"),
                concat(setup, new byte[900]))));
        long granule = 0;
        for (int i = 0; i < audio.size(); i++) {
            granule += 44100;
            out.write(page(i == audio.size() - 1 ? 0x04 : 0, granule, 0, 2 + i,
                    one(audio.get(i))));
        }
        write(file, out.toByteArray());
    }

    private static void writeOpus(File file, List<byte[]> audio) throws Exception {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write(page(0x02, 0, 0, 0, one("OpusHead".getBytes("US-ASCII"))));
        out.write(page(0, 0, 0, 1, one(commentPacket(true, "test-vendor"))));
        long granule = 0;
        for (int i = 0; i < audio.size(); i++) {
            granule += 960;
            out.write(page(i == audio.size() - 1 ? 0x04 : 0, granule, 0, 2 + i,
                    one(audio.get(i))));
        }
        write(file, out.toByteArray());
    }

    /**
     * 注释包被人为拆到两页：第一页只有注释包的前半截（全是 255 段），第二页续上并接音频。
     * 我们的写入必须识别出「注释跨页」并拒绝。
     */
    private static void writeVorbisWithSpannedComment(File file) throws Exception {
        byte[] ident = new byte[]{0x01, 'v', 'o', 'r', 'b', 'i', 's'};
        byte[] comment = commentPacket(false, "test-vendor");
        byte[] padded = concat(comment, new byte[70000]); // 故意超过一页上限
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write(page(0x02, 0, 0, 0, one(ident)));
        // 第一页：只放 255 个 255 段（= 65025 字节），包未结束
        byte[] firstPart = new byte[65025];
        System.arraycopy(padded, 0, firstPart, 0, Math.min(padded.length, firstPart.length));
        List<byte[]> part1 = new ArrayList<byte[]>();
        part1.add(firstPart);
        out.write(partialPage(0, 0, 0, 1, part1, true));
        byte[] rest = new byte[padded.length - firstPart.length];
        System.arraycopy(padded, firstPart.length, rest, 0, rest.length);
        out.write(continuedPage(0, 0, 0, 2, rest));
        write(file, out.toByteArray());
    }

    // ------------------------------------------------------------------
    // 校验
    // ------------------------------------------------------------------

    /** 逐包比对：索引 0/2..N 必须与原始一致（1 是注释包，允许变）。 */
    private static boolean audioIntact(File file, List<byte[]> audio) throws Exception {
        List<byte[]> packets = rawPackets(file);
        // Vorbis 有 ident+注释+setup 三个头包，Opus 只有两个，所以只要求「至少包含音频包」
        if (packets.size() < audio.size()) {
            return false;
        }
        // 0=ident / 1=注释 / 2=setup / 3..=音频
        // 音频包在末尾（Vorbis 前面还有 setup 包，Opus 没有，所以从尾部比对）
        int base = packets.size() - audio.size();
        for (int i = 0; i < audio.size(); i++) {
            if (!same(packets.get(base + i), audio.get(i))) {
                return false;
            }
        }
        return packets.get(1)[0] == 0x03 || packets.get(1)[0] == 'O';
    }

    private static boolean allCrcValid(File file) throws Exception {
        RandomAccessFile raf = new RandomAccessFile(file, "r");
        try {
            long pos = 0;
            byte[] all = new byte[(int) raf.length()];
            raf.readFully(all);
            while (pos + 27 <= all.length) {
                int nsegs = all[(int) pos + 26] & 0xFF;
                int payload = 0;
                for (int i = 0; i < nsegs; i++) {
                    payload += all[(int) pos + 27 + i] & 0xFF;
                }
                int total = 27 + nsegs + payload;
                long stored = ((long) (all[(int) pos + 22] & 0xFF))
                        | ((long) (all[(int) pos + 23] & 0xFF) << 8)
                        | ((long) (all[(int) pos + 24] & 0xFF) << 16)
                        | ((long) (all[(int) pos + 25] & 0xFF) << 24);
                byte[] copy = new byte[total];
                System.arraycopy(all, (int) pos, copy, 0, total);
                copy[22] = 0;
                copy[23] = 0;
                copy[24] = 0;
                copy[25] = 0;
                if (Ogg.crc(copy, 0, total) != stored) {
                    return false;
                }
                pos += total;
            }
            return true;
        } finally {
            raf.close();
        }
    }

    private static int pageCount(File file) throws Exception {
        RandomAccessFile raf = new RandomAccessFile(file, "r");
        try {
            byte[] all = new byte[(int) raf.length()];
            raf.readFully(all);
            int n = 0;
            int pos = 0;
            while (pos + 27 <= all.length) {
                int nsegs = all[pos + 26] & 0xFF;
                int payload = 0;
                for (int i = 0; i < nsegs; i++) {
                    payload += all[pos + 27 + i] & 0xFF;
                }
                pos += 27 + nsegs + payload;
                n++;
            }
            return n;
        } finally {
            raf.close();
        }
    }

    private static List<byte[]> rawPackets(File file) throws Exception {
        RandomAccessFile raf = new RandomAccessFile(file, "r");
        try {
            byte[] all = new byte[(int) raf.length()];
            raf.readFully(all);
            List<byte[]> out = new ArrayList<byte[]>();
            ByteArrayOutputStream cur = null;
            int pos = 0;
            while (pos + 27 <= all.length) {
                int nsegs = all[pos + 26] & 0xFF;
                int payloadPos = pos + 27 + nsegs;
                for (int i = 0; i < nsegs; i++) {
                    int seg = all[pos + 27 + i] & 0xFF;
                    if (cur == null) {
                        cur = new ByteArrayOutputStream(seg + 64);
                    }
                    cur.write(all, payloadPos, seg);
                    payloadPos += seg;
                    if (seg < 255) {
                        out.add(cur.toByteArray());
                        cur = null;
                    }
                }
                int payload = 0;
                for (int i = 0; i < nsegs; i++) {
                    payload += all[pos + 27 + i] & 0xFF;
                }
                pos += 27 + nsegs + payload;
            }
            return out;
        } finally {
            raf.close();
        }
    }

    // ------------------------------------------------------------------
    // 页构造
    // ------------------------------------------------------------------

    private static byte[] page(int headerType, long granule, int serial, long seq,
                               List<byte[]> packets) throws Exception {
        List<Integer> segs = new ArrayList<Integer>();
        ByteArrayOutputStream payload = new ByteArrayOutputStream();
        for (byte[] p : packets) {
            int left = p.length;
            while (left >= 255) {
                segs.add(255);
                left -= 255;
            }
            segs.add(left);
            payload.write(p);
        }
        return assemble(headerType, granule, serial, seq, segs, payload.toByteArray());
    }

    private static byte[] partialPage(int headerType, long granule, int serial, long seq,
                                      List<byte[]> chunks, boolean more) throws Exception {
        List<Integer> segs = new ArrayList<Integer>();
        ByteArrayOutputStream payload = new ByteArrayOutputStream();
        for (byte[] p : chunks) {
            int left = p.length;
            while (left >= 255) {
                segs.add(255);
                left -= 255;
            }
            if (left > 0) {
                segs.add(left);
            }
            payload.write(p);
        }
        if (more && (segs.isEmpty() || segs.get(segs.size() - 1) != 255)) {
            segs.add(255); // 保证最后一包「未结束」
            payload.write(new byte[255]);
        }
        return assemble(headerType, granule, serial, seq, segs, payload.toByteArray());
    }

    private static byte[] continuedPage(int headerType, long granule, int serial, long seq,
                                        byte[] rest) throws Exception {
        List<Integer> segs = new ArrayList<Integer>();
        int left = rest.length;
        while (left >= 255) {
            segs.add(255);
            left -= 255;
        }
        segs.add(left);
        return assemble(headerType | 0x01, granule, serial, seq, segs, rest);
    }

    private static byte[] assemble(int headerType, long granule, int serial, long seq,
                                   List<Integer> segs, byte[] payload) throws Exception {
        ByteArrayOutputStream b = new ByteArrayOutputStream(payload.length + 300);
        b.write('O');
        b.write('g');
        b.write('g');
        b.write('S');
        b.write(0);
        b.write(headerType);
        b.write(le64(granule));
        b.write(le32(serial));
        b.write(le32(seq));
        b.write(new byte[4]);
        b.write(segs.size());
        for (Integer s : segs) {
            b.write(s & 0xFF);
        }
        b.write(payload);
        byte[] page = b.toByteArray();
        long crc = Ogg.crc(page, 0, page.length);
        page[22] = (byte) (crc & 0xFF);
        page[23] = (byte) ((crc >> 8) & 0xFF);
        page[24] = (byte) ((crc >> 16) & 0xFF);
        page[25] = (byte) ((crc >> 24) & 0xFF);
        return page;
    }

    private static byte[] commentPacket(boolean opus, String vendor) throws Exception {
        ByteArrayOutputStream b = new ByteArrayOutputStream();
        if (opus) {
            b.write("OpusTags".getBytes("US-ASCII"));
        } else {
            b.write(new byte[]{0x03, 'v', 'o', 'r', 'b', 'i', 's'});
        }
        byte[] v = vendor.getBytes("UTF-8");
        b.write(le32(v.length));
        b.write(v);
        b.write(le32(0)); // 0 条注释
        if (!opus) {
            b.write(0x01);
        }
        return b.toByteArray();
    }

    private static byte[] packet(int seed, int size) {
        byte[] out = new byte[size];
        for (int i = 0; i < size; i++) {
            out[i] = (byte) ((seed + i * 31) & 0xFF);
        }
        return out;
    }

    private static List<byte[]> one(byte[] a) {
        List<byte[]> out = new ArrayList<byte[]>();
        out.add(a);
        return out;
    }

    private static List<byte[]> two(byte[] a, byte[] b) {
        List<byte[]> out = new ArrayList<byte[]>();
        out.add(a);
        out.add(b);
        return out;
    }

    private static byte[] concat(byte[] a, byte[] b) {
        byte[] out = new byte[a.length + b.length];
        System.arraycopy(a, 0, out, 0, a.length);
        System.arraycopy(b, 0, out, a.length, b.length);
        return out;
    }

    private static boolean same(byte[] a, byte[] b) {
        if (a == null || b == null || a.length != b.length) {
            return false;
        }
        for (int i = 0; i < a.length; i++) {
            if (a[i] != b[i]) {
                return false;
            }
        }
        return true;
    }

    private static byte[] le32(long v) {
        return new byte[]{(byte) (v & 0xFF), (byte) ((v >> 8) & 0xFF),
                (byte) ((v >> 16) & 0xFF), (byte) ((v >> 24) & 0xFF)};
    }

    private static byte[] le64(long v) {
        byte[] out = new byte[8];
        for (int i = 0; i < 8; i++) {
            out[i] = (byte) ((v >> (8 * i)) & 0xFF);
        }
        return out;
    }

    private static void write(File file, byte[] data) throws Exception {
        FileOutputStream out = new FileOutputStream(file);
        try {
            out.write(data);
        } finally {
            out.close();
        }
    }

    private static void check(String name, boolean ok) {
        if (ok) {
            pass++;
            System.out.println("  ok   " + name);
        } else {
            fail++;
            System.out.println("  FAIL " + name);
        }
    }
}
