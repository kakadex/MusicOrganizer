package com.dsh.musicorganizer.core;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.RandomAccessFile;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * OGG Vorbis / Opus 的 Vorbis Comment 读写（不依赖第三方标签库）。
 *
 * <p>容器结构：文件由若干个 Ogg 页组成，每页头 27 字节 + 段表（lacing）；
 * 段值 255 表示「本包未结束，下一段续」，小于 255 表示包在这里结束。
 * 注释包固定是第 2 个包：
 * <ul>
 *   <li>Vorbis：{@code 0x03 "vorbis"} + vendor + 注释项 + 1 字节 framed bit；</li>
 *   <li>Opus：{@code "OpusTags"} + vendor + 注释项（无 framed bit）。</li>
 * </ul>
 *
 * <p><b>写入策略（保守且可验证）</b>：只重建「包含注释包的那一页」，后面的页原样保留
 * （页序号不变，CRC 自然有效）。只有注释大到一页装不下时才拆页，并把后续页序号顺移、
 * 重算 CRC。写完立刻重新解析一遍，逐包比对音频包哈希，不一致就报错回滚 ——
 * 宁可写失败，也不能写坏用户的音乐。
 */
public final class Ogg {

    private Ogg() {
    }

    /** 注释包最多允许占多少字节（超过一页就拆页，不设上限但会拆）。 */
    private static final int MAX_PAGE_SEGMENTS = 255;
    private static final int MAX_PAGE_PAYLOAD = 255 * 255;

    public static boolean isOgg(File file) {
        if (file == null || !file.isFile() || file.length() < 27) {
            return false;
        }
        RandomAccessFile raf = null;
        try {
            raf = new RandomAccessFile(file, "r");
            byte[] magic = new byte[4];
            raf.readFully(magic);
            return magic[0] == 'O' && magic[1] == 'g' && magic[2] == 'g' && magic[3] == 'S';
        } catch (Exception e) {
            return false;
        } finally {
            close(raf);
        }
    }

    // ------------------------------------------------------------------
    // 读
    // ------------------------------------------------------------------

    public static Tags read(File file) {
        Tags tags = new Tags();
        if (!isOgg(file)) {
            return tags;
        }
        try {
            List<Packet> packets = packets(file);
            if (packets.size() < 2) {
                return tags;
            }
            applyComments(tags, packets.get(1).data);
        } catch (Exception ignored) {
        }
        return tags;
    }

    /** OGG 里有没有内嵌封面（METADATA_BLOCK_PICTURE / COVERART）。 */
    public static boolean hasCover(File file) {
        try {
            List<Packet> packets = packets(file);
            if (packets.size() < 2) {
                return false;
            }
            Map<String, String> c = parseComments(packets.get(1).data);
            for (String key : c.keySet()) {
                String k = key.toUpperCase(Locale.US);
                if (k.startsWith("METADATA_BLOCK_PICTURE") || k.startsWith("COVERART")) {
                    return true;
                }
            }
        } catch (Exception ignored) {
        }
        return false;
    }

    private static void applyComments(Tags tags, byte[] commentPacket) {
        Map<String, String> c = parseComments(commentPacket);
        putIfPresent(tags, c, "title", "TITLE");
        putIfPresent(tags, c, "artist", "ARTIST");
        putIfPresent(tags, c, "album", "ALBUM");
        putIfPresent(tags, c, "year", "DATE");
        putIfPresent(tags, c, "genre", "GENRE");
        putIfPresent(tags, c, "comment", "COMMENT");
        putIfPresent(tags, c, "track", "TRACKNUMBER");
        // 歌词字段各家写法不一，按优先级取第一个非空的
        String[] lyricKeys = {"LYRICS", "UNSYNCEDLYRICS", "LYRIC", "SYNCEDLYRICS"};
        for (String k : lyricKeys) {
            String v = c.get(k);
            if (v != null && !v.trim().isEmpty()) {
                tags.put("lyrics", v);
                break;
            }
        }
    }

    private static void putIfPresent(Tags tags, Map<String, String> c, String field, String key) {
        String v = c.get(key);
        if (v != null) {
            tags.put(field, v);
        }
    }

    /**
     * 解析 Vorbis Comment 包。
     *
     * @return 键大写 → 值（同名键只留第一个，符合规范「读者取第一个」）
     */
    static Map<String, String> parseComments(byte[] packet) {
        Map<String, String> out = new LinkedHashMap<String, String>();
        if (packet == null) {
            return out;
        }
        int pos;
        if (startsWith(packet, new byte[]{0x03, 'v', 'o', 'r', 'b', 'i', 's'})) {
            pos = 7;
        } else if (startsWith(packet, "OpusTags".getBytes())) {
            pos = 8;
        } else {
            return out;
        }
        try {
            int vendorLen = readInt(packet, pos);
            pos += 4 + vendorLen;
            int count = readInt(packet, pos);
            pos += 4;
            for (int i = 0; i < count && pos + 4 <= packet.length; i++) {
                int len = readInt(packet, pos);
                pos += 4;
                if (len < 0 || pos + len > packet.length) {
                    break;
                }
                String entry = TagText.decodeUtf8(java.util.Arrays.copyOfRange(packet, pos, pos + len));
                pos += len;
                int eq = entry.indexOf('=');
                if (eq <= 0) {
                    continue;
                }
                String key = entry.substring(0, eq).toUpperCase(Locale.US);
                String value = entry.substring(eq + 1);
                if (!out.containsKey(key)) {
                    out.put(key, value);
                }
            }
        } catch (Exception ignored) {
        }
        return out;
    }

    /** 取 vendor 字符串（写回时保留原样，很多播放器靠它识别编码器）。 */
    static String vendorOf(byte[] packet) {
        try {
            int pos;
            if (startsWith(packet, new byte[]{0x03, 'v', 'o', 'r', 'b', 'i', 's'})) {
                pos = 7;
            } else if (startsWith(packet, "OpusTags".getBytes())) {
                pos = 8;
            } else {
                return "";
            }
            int len = readInt(packet, pos);
            if (len < 0 || pos + 4 + len > packet.length) {
                return "";
            }
            return TagText.decodeUtf8(java.util.Arrays.copyOfRange(packet, pos + 4, pos + 4 + len));
        } catch (Exception e) {
            return "";
        }
    }

    // ------------------------------------------------------------------
    // 写
    // ------------------------------------------------------------------

    public static void rewrite(File file, Map<String, String> values, byte[] cover)
            throws IOException {
        if (!isOgg(file)) {
            throw new IOException("不是有效的 OGG 文件");
        }
        List<Page> pages = pages(file);
        if (pages.isEmpty()) {
            throw new IOException("OGG 文件没有可用页面");
        }
        List<Packet> packets = packets(file);
        if (packets.size() < 2) {
            throw new IOException("OGG 文件缺少注释包");
        }
        boolean opus = startsWith(packets.get(0).data, "OpusHead".getBytes());
        boolean vorbis = startsWith(packets.get(0).data,
                new byte[]{0x01, 'v', 'o', 'r', 'b', 'i', 's'});
        if (!opus && !vorbis) {
            throw new IOException("只支持 OGG Vorbis / Opus");
        }

        Packet comment = packets.get(1);
        if (comment.startPage != comment.endPage) {
            // 注释跨页时重建逻辑复杂且少见（歌词几十 KB 才会），宁可拒绝也不写坏文件
            throw new IOException("歌词体积过大（注释跨页），暂不支持写入，请改用 .lrc 文件");
        }
        Page hostPage = pages.get(comment.startPage);

        // 新注释包 = 原注释项（去掉要替换的键）+ 新值
        Map<String, String> merged = parseComments(comment.data);
        String vendor = vendorOf(comment.data);
        if (vendor.isEmpty()) {
            vendor = "MusicOrganizer";
        }
        for (Map.Entry<String, String> e : values.entrySet()) {
            String key = vorbisKey(e.getKey());
            if (key == null) {
                continue;
            }
            merged.remove(key);
            // 歌词不做 trim：尾部换行是内容的一部分；其它字段去掉首尾空格
            String raw = e.getValue() == null ? "" : e.getValue();
            String v = "lyrics".equals(e.getKey()) ? raw : raw.trim();
            if (!v.isEmpty()) {
                merged.put(key, v);
            }
        }
        byte[] newComment = buildComment(opus, vendor, merged);
        if (newComment.length > MAX_PAGE_PAYLOAD * 8) {
            throw new IOException("标签数据过大（超过 500KB），请减少歌词长度");
        }

        // 宿主页上「注释包之后」的包要跟着一起重排（Vorbis 的 setup header 与注释同页）
        List<byte[]> tail = new ArrayList<byte[]>();
        for (int i = 1; i < packets.size(); i++) {
            Packet p = packets.get(i);
            if (p.startPage == hostPage.index && p.indexInPage > comment.indexInPage) {
                tail.add(p.data);
            }
        }
        List<byte[]> newPackets = new ArrayList<byte[]>();
        newPackets.add(newComment);
        newPackets.addAll(tail);

        List<byte[]> newPages = buildPages(hostPage, newPackets);
        int extra = newPages.size() - 1;

        File tmp = new File(file.getParentFile(), file.getName() + ".mo_ogg.tmp");
        RandomAccessFile in = null;
        FileOutputStream out = null;
        try {
            in = new RandomAccessFile(file, "r");
            out = new FileOutputStream(tmp);
            // 1) 注释页之前的页：原样拷贝
            long before = hostPage.offset;
            copyRange(in, out, 0, before);
            // 2) 重建的页
            for (byte[] page : newPages) {
                out.write(page);
            }
            // 3) 之后的页：页数不变则原样；多出的页要把序号顺移并重算 CRC
            long afterOffset = hostPage.offset + hostPage.totalLen;
            long afterLen = file.length() - afterOffset;
            if (extra == 0) {
                copyRange(in, out, afterOffset, afterLen);
            } else {
                byte[] rest = new byte[(int) afterLen];
                in.seek(afterOffset);
                in.readFully(rest);
                int pos = 0;
                while (pos + 27 <= rest.length) {
                    int total = pageTotalLen(rest, pos);
                    if (total <= 0 || pos + total > rest.length) {
                        break;
                    }
                    long seq = readU32(rest, pos + 18);
                    writeU32(rest, pos + 18, seq + extra);
                    writeU32(rest, pos + 22, 0);
                    long crc = crc(rest, pos, total);
                    writeU32(rest, pos + 22, crc);
                    pos += total;
                }
                out.write(rest);
            }
        } finally {
            close(in);
            close(out);
        }

        // 4) 自检：包数一致、除注释包外每个包逐字节相同
        verify(tmp, packets, 1);
        // 5) 覆盖回原文件
        copyFile(tmp, file);
        //noinspection ResultOfMethodCallIgnored
        tmp.delete();
    }

    private static void verify(File rewritten, List<Packet> before, int commentIndex)
            throws IOException {
        List<Packet> after = packets(rewritten);
        if (after.size() != before.size()) {
            //noinspection ResultOfMethodCallIgnored
            rewritten.delete();
            throw new IOException("OGG 校验失败：包数量从 " + before.size()
                    + " 变成 " + after.size() + "，已取消写入");
        }
        for (int i = 0; i < before.size(); i++) {
            if (i == commentIndex) {
                continue;
            }
            if (!sameBytes(before.get(i).data, after.get(i).data)) {
                //noinspection ResultOfMethodCallIgnored
                rewritten.delete();
                throw new IOException("OGG 校验失败：第 " + (i + 1) + " 个数据包被改动，已取消写入");
            }
        }
        // 新注释必须能被自己读出来
        Map<String, String> c = parseComments(after.get(commentIndex).data);
        if (c.isEmpty() && !parseComments(before.get(commentIndex).data).isEmpty()) {
            //noinspection ResultOfMethodCallIgnored
            rewritten.delete();
            throw new IOException("OGG 校验失败：注释包无法回读，已取消写入");
        }
    }

    private static String vorbisKey(String field) {
        if ("title".equals(field)) {
            return "TITLE";
        }
        if ("artist".equals(field)) {
            return "ARTIST";
        }
        if ("album".equals(field)) {
            return "ALBUM";
        }
        if ("year".equals(field)) {
            return "DATE";
        }
        if ("track".equals(field)) {
            return "TRACKNUMBER";
        }
        if ("genre".equals(field)) {
            return "GENRE";
        }
        if ("comment".equals(field)) {
            return "COMMENT";
        }
        if ("lyrics".equals(field)) {
            return "LYRICS";
        }
        return null;
    }

    /** 组装注释包：头 + vendor + 计数 + 「KEY=value」 + Vorbis 的 framed bit。 */
    static byte[] buildComment(boolean opus, String vendor, Map<String, String> comments)
            throws IOException {
        java.io.ByteArrayOutputStream body = new java.io.ByteArrayOutputStream(1024);
        if (opus) {
            body.write("OpusTags".getBytes("US-ASCII"));
        } else {
            body.write(new byte[]{0x03, 'v', 'o', 'r', 'b', 'i', 's'});
        }
        byte[] vb = vendor.getBytes("UTF-8");
        body.write(intBytes(vb.length));
        body.write(vb);
        body.write(intBytes(comments.size()));
        for (Map.Entry<String, String> e : comments.entrySet()) {
            byte[] kv = (e.getKey() + "=" + e.getValue()).getBytes("UTF-8");
            body.write(intBytes(kv.length));
            body.write(kv);
        }
        if (!opus) {
            body.write(0x01); // Vorbis 规范要求的 framing bit
        }
        return body.toByteArray();
    }

    /**
     * 把若干包排成页；沿用宿主页的序号、granule 与 serial。
     *
     * <p>单个包可以跨页（歌词几十 KB 就会），跨页时下一页要带「续页」标志 0x01，
     * 段表最多 255 项 —— 这两点任一漏掉，播放器会把这个包读成垃圾或直接截断文件。
     */
    private static List<byte[]> buildPages(Page host, List<byte[]> packets)
            throws IOException {
        List<byte[]> out = new ArrayList<byte[]>();
        List<Integer> segs = new ArrayList<Integer>();
        java.io.ByteArrayOutputStream payload = new java.io.ByteArrayOutputStream(8192);
        boolean startsContinued = false;
        boolean midPacket = false;
        for (byte[] p : packets) {
            int off = 0;
            while (true) {
                if (segs.size() == MAX_PAGE_SEGMENTS) {
                    out.add(emitPage(host, out.size(), segs, payload.toByteArray(),
                            startsContinued, midPacket));
                    segs = new ArrayList<Integer>();
                    payload = new java.io.ByteArrayOutputStream(8192);
                    startsContinued = midPacket;
                }
                int take = Math.min(255, p.length - off);
                segs.add(take);
                payload.write(p, off, take);
                off += take;
                midPacket = (p.length - off) > 0;
                if (take < 255) {
                    break;
                }
                if (off == p.length) {
                    // 长度正好是 255 的倍数：必须补一个 0 段，表示这个包到此结束
                    if (segs.size() == MAX_PAGE_SEGMENTS) {
                        out.add(emitPage(host, out.size(), segs, payload.toByteArray(),
                                startsContinued, true));
                        segs = new ArrayList<Integer>();
                        payload = new java.io.ByteArrayOutputStream(8192);
                        startsContinued = true;
                    }
                    segs.add(0);
                    midPacket = false;
                    break;
                }
            }
        }
        out.add(emitPage(host, out.size(), segs, payload.toByteArray(), startsContinued, false));
        return out;
    }

    /**
     * 生成一页。
     *
     * @param indexOffset   第几页（0 = 宿主页本身，沿用原 headerType / granule）
     * @param startsContinued 本页第一个包是否从上一页续过来
     * @param midPacket     本页结束时是否停在包中间（决定下一页的续页标志）
     */
    private static byte[] emitPage(Page host, long indexOffset, List<Integer> segs,
                                   byte[] payload, boolean startsContinued, boolean midPacket)
            throws IOException {
        java.io.ByteArrayOutputStream b = new java.io.ByteArrayOutputStream(payload.length + 300);
        b.write('O');
        b.write('g');
        b.write('g');
        b.write('S');
        b.write(0);
        int type;
        long granule;
        if (indexOffset == 0) {
            type = host.headerType;
            granule = host.granule;
        } else {
            // 拆出来的页没有完成任何音频包，granule 记 0；中间页若续着包就要带 0x01
            type = startsContinued ? 0x01 : 0;
            granule = 0;
        }
        if (midPacket && indexOffset == 0) {
            type |= 0x00; // 宿主页自身标志已含续页信息，不额外改
        }
        b.write(type);
        b.write(longBytes(granule));
        b.write(intBytes(host.serial));
        b.write(intBytes(host.seq + indexOffset)); // 页序号 4 字节，写成 8 会让页头错位
        b.write(new byte[4]); // CRC 占位
        b.write(segs.size());
        for (Integer s : segs) {
            b.write(s & 0xFF);
        }
        b.write(payload, 0, payload.length);
        byte[] page = b.toByteArray();
        long crc = crc(page, 0, page.length);
        writeU32(page, 22, crc);
        return page;
    }

    /** 包 → lacing 段；长度正好是 255 的倍数时，末尾要补一个 0 段表示「包结束」。 */
    private static List<Integer> lacing(byte[] packet) {
        List<Integer> out = new ArrayList<Integer>();
        int left = packet.length;
        while (left >= 255) {
            out.add(255);
            left -= 255;
        }
        out.add(left);
        return out;
    }

    // ------------------------------------------------------------------
    // 页 / 包解析
    // ------------------------------------------------------------------

    private static final class Page {
        int index;
        long offset;
        int headerType;
        long granule;
        int serial;
        long seq;
        byte[] raw; // 整页字节（含头）
        int totalLen;
    }

    private static final class Packet {
        byte[] data;
        int indexInPage;
        int startPage;
        int endPage;
        long granule;
    }

    private static List<Page> pages(File file) throws IOException {
        List<Page> out = new ArrayList<Page>();
        RandomAccessFile raf = new RandomAccessFile(file, "r");
        try {
            long len = file.length();
            long pos = 0;
            int index = 0;
            while (pos + 27 <= len) {
                raf.seek(pos);
                byte[] head = new byte[27];
                raf.readFully(head);
                if (head[0] != 'O' || head[1] != 'g' || head[2] != 'g' || head[3] != 'S') {
                    break;
                }
                int nsegs = head[26] & 0xFF;
                byte[] segTable = new byte[nsegs];
                if (nsegs > 0) {
                    raf.readFully(segTable);
                }
                int payload = 0;
                for (byte s : segTable) {
                    payload += (s & 0xFF);
                }
                int total = 27 + nsegs + payload;
                if (pos + total > len) {
                    break;
                }
                Page p = new Page();
                p.index = index++;
                p.offset = pos;
                p.headerType = head[5] & 0xFF;
                p.granule = readLong(head, 6);
                p.serial = (int) readU32(head, 14);
                p.seq = readU32(head, 18);
                p.totalLen = total;
                p.raw = new byte[total];
                raf.seek(pos);
                raf.readFully(p.raw);
                out.add(p);
                pos += total;
            }
        } finally {
            close(raf);
        }
        return out;
    }

    /** 按页顺序拼包（处理 255 续段）。 */
    private static List<Packet> packets(File file) throws IOException {
        List<Packet> out = new ArrayList<Packet>();
        // 缓冲必须跨页保留：一个包可能续到下一页，每页都重置会把包切断
        // （大歌词必然跨页，切断后注释只能读出一半，表现为「歌词写进去却读不出来」）
        java.io.ByteArrayOutputStream cur = new java.io.ByteArrayOutputStream(4096);
        boolean open = false;
        int startPage = -1;
        for (Page page : pages(file)) {
            int segCount = page.raw[26] & 0xFF;
            int payloadPos = 27 + segCount;
            int indexInPage = 0;
            for (int i = 0; i < segCount; i++) {
                int seg = page.raw[27 + i] & 0xFF;
                if (!open) {
                    open = true;
                    startPage = page.index;
                    cur = new java.io.ByteArrayOutputStream(seg + 64);
                }
                cur.write(page.raw, payloadPos, seg);
                payloadPos += seg;
                if (seg < 255) {
                    Packet p = new Packet();
                    p.data = cur.toByteArray();
                    p.indexInPage = indexInPage++;
                    p.startPage = startPage;
                    p.endPage = page.index;
                    p.granule = page.granule;
                    out.add(p);
                    open = false;
                }
            }
        }
        return out;
    }

    // ------------------------------------------------------------------
    // 工具
    // ------------------------------------------------------------------

    /** Ogg 用的 CRC32：多项式 0x04C11DB7，初值 0，不反射、不取反（和 zlib 的 CRC32 不同）。 */
    public static long crc(byte[] data, int off, int len) {
        int crc = 0;
        for (int i = off; i < off + len; i++) {
            crc = (crc << 8) ^ TABLE[((crc >>> 24) ^ (data[i] & 0xFF)) & 0xFF];
        }
        return crc & 0xFFFFFFFFL;
    }

    private static final int[] TABLE = new int[256];

    static {
        for (int i = 0; i < 256; i++) {
            int r = i << 24;
            for (int j = 0; j < 8; j++) {
                r = (r & 0x80000000) != 0 ? (r << 1) ^ 0x04C11DB7 : (r << 1);
            }
            TABLE[i] = r;
        }
    }

    private static int pageTotalLen(byte[] buf, int pos) {
        int nsegs = buf[pos + 26] & 0xFF;
        int payload = 0;
        for (int i = 0; i < nsegs; i++) {
            payload += buf[pos + 27 + i] & 0xFF;
        }
        return 27 + nsegs + payload;
    }

    private static void copyRange(RandomAccessFile in, FileOutputStream out, long from, long len)
            throws IOException {
        in.seek(from);
        byte[] buf = new byte[65536];
        long left = len;
        while (left > 0) {
            int n = in.read(buf, 0, (int) Math.min(buf.length, left));
            if (n <= 0) {
                break;
            }
            out.write(buf, 0, n);
            left -= n;
        }
    }

    private static void copyFile(File src, File dst) throws IOException {
        FileInputStream in = null;
        FileOutputStream out = null;
        try {
            in = new FileInputStream(src);
            out = new FileOutputStream(dst);
            byte[] buf = new byte[65536];
            int n;
            while ((n = in.read(buf)) > 0) {
                out.write(buf, 0, n);
            }
            out.getFD().sync();
        } finally {
            close(in);
            close(out);
        }
    }

    private static boolean startsWith(byte[] data, byte[] prefix) {
        if (data == null || data.length < prefix.length) {
            return false;
        }
        for (int i = 0; i < prefix.length; i++) {
            if (data[i] != prefix[i]) {
                return false;
            }
        }
        return true;
    }

    private static boolean sameBytes(byte[] a, byte[] b) {
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

    private static int readInt(byte[] b, int off) {
        return (b[off] & 0xFF) | ((b[off + 1] & 0xFF) << 8)
                | ((b[off + 2] & 0xFF) << 16) | ((b[off + 3] & 0xFF) << 24);
    }

    private static long readU32(byte[] b, int off) {
        return ((long) (b[off] & 0xFF)) | ((long) (b[off + 1] & 0xFF) << 8)
                | ((long) (b[off + 2] & 0xFF) << 16) | ((long) (b[off + 3] & 0xFF) << 24);
    }

    private static long readLong(byte[] b, int off) {
        long v = 0;
        for (int i = 7; i >= 0; i--) {
            v = (v << 8) | (b[off + i] & 0xFFL);
        }
        return v;
    }

    private static void writeU32(byte[] b, int off, long v) {
        b[off] = (byte) (v & 0xFF);
        b[off + 1] = (byte) ((v >> 8) & 0xFF);
        b[off + 2] = (byte) ((v >> 16) & 0xFF);
        b[off + 3] = (byte) ((v >> 24) & 0xFF);
    }

    private static byte[] intBytes(long v) {
        return new byte[]{(byte) (v & 0xFF), (byte) ((v >> 8) & 0xFF),
                (byte) ((v >> 16) & 0xFF), (byte) ((v >> 24) & 0xFF)};
    }

    private static byte[] longBytes(long v) {
        byte[] out = new byte[8];
        for (int i = 0; i < 8; i++) {
            out[i] = (byte) ((v >> (8 * i)) & 0xFF);
        }
        return out;
    }

    private static void close(java.io.Closeable c) {
        if (c != null) {
            try {
                c.close();
            } catch (Exception ignored) {
            }
        }
    }
}
