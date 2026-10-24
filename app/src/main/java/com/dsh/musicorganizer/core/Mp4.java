package com.dsh.musicorganizer.core;

import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.RandomAccessFile;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * MP4 / M4A 标签读写（moov &gt; udta &gt; meta &gt; ilst）。
 *
 * <p><b>读</b>：遍历 moov/udta/meta/ilst，把 {@code ©nam} / {@code ©ART} / {@code trkn}
 * 等 atom 映射成统一字段；{@code covr} 只用来判断「有没有封面」。
 *
 * <p><b>写</b>（v0.1.9 起）：以前这里是「只读」，因为改 udta 会改变 moov 大小、
 * 从而让 {@code stco}/{@code co64} 里的采样偏移全部错位。做法是标准的
 * <i>偏移修正</i>：
 * <ol>
 *   <li>把 moov 整块读进内存，只重建其中的 udta&gt;meta&gt;ilst；</li>
 *   <li>算出新 moov 与原 moov 的长度差 {@code delta}；</li>
 *   <li>若 mdat 排在 moov 之后（faststart 布局），把每个 chunk offset 加上 {@code delta}；</li>
 *   <li>按原顺序重写文件（moov 换成新块，其余 atom 原样拷贝）。</li>
 * </ol>
 * moov 在文件尾（多数编码器的默认布局）时 delta 不影响任何偏移，第 3 步自然空转。
 */
public final class Mp4 {

    private Mp4() {
    }

    private static final Map<String, String> ATOM_FIELDS = new HashMap<String, String>();

    static {
        ATOM_FIELDS.put("\u00a9nam", "title");
        ATOM_FIELDS.put("\u00a9ART", "artist");
        ATOM_FIELDS.put("\u00a9alb", "album");
        ATOM_FIELDS.put("\u00a9day", "year");
        ATOM_FIELDS.put("trkn", "track");
        ATOM_FIELDS.put("\u00a9gen", "genre");
        ATOM_FIELDS.put("gnre", "genre");
        ATOM_FIELDS.put("\u00a9cmt", "comment");
        ATOM_FIELDS.put("\u00a9lyr", "lyrics");
    }

    public static boolean isMp4(File file) {
        FileInputStream in = null;
        try {
            in = new FileInputStream(file);
            byte[] head = new byte[8];
            if (in.read(head) != 8) {
                return false;
            }
            return head[4] == 'f' && head[5] == 't' && head[6] == 'y' && head[7] == 'p';
        } catch (Exception e) {
            return false;
        } finally {
            if (in != null) {
                try {
                    in.close();
                } catch (Exception ignored) {
                }
            }
        }
    }

    public static Tags read(File file) {
        Tags tags = new Tags();
        RandomAccessFile raf = null;
        try {
            raf = new RandomAccessFile(file, "r");
            walk(raf, 0, file.length(), tags, 0);
        } catch (Exception ignored) {
        } finally {
            if (raf != null) {
                try {
                    raf.close();
                } catch (Exception ignored) {
                }
            }
        }
        return tags;
    }

    private static void walk(RandomAccessFile raf, long start, long end,
                             Tags tags, int depth) throws Exception {
        if (depth > 8) {
            return;
        }
        long pos = start;
        byte[] head = new byte[8];
        while (pos + 8 <= end) {
            raf.seek(pos);
            if (raf.read(head) != 8) {
                break;
            }
            long size = ((head[0] & 0xFFL) << 24) | ((head[1] & 0xFFL) << 16)
                    | ((head[2] & 0xFFL) << 8) | (head[3] & 0xFFL);
            String type = new String(head, 4, 4, "ISO-8859-1");
            if (size == 1) {
                byte[] ext = new byte[8];
                raf.readFully(ext);
                size = ((ext[0] & 0xFFL) << 56) | ((ext[1] & 0xFFL) << 48)
                        | ((ext[2] & 0xFFL) << 40) | ((ext[3] & 0xFFL) << 32)
                        | ((ext[4] & 0xFFL) << 24) | ((ext[5] & 0xFFL) << 16)
                        | ((ext[6] & 0xFFL) << 8) | (ext[7] & 0xFFL);
                pos += 8;
            } else if (size == 0) {
                size = end - pos;
            }
            if (size < 8 || pos + size > end) {
                break;
            }
            if (type.equals("moov")) {
                walk(raf, pos + 8, pos + size, tags, depth + 1);
            } else if (type.equals("udta")) {
                walk(raf, pos + 8, pos + size, tags, depth + 1);
            } else if (type.equals("meta")) {
                walk(raf, pos + 12, pos + size, tags, depth + 1); // meta 带 4 字节版本标志
            } else if (type.equals("ilst")) {
                parseIlst(raf, pos + 8, pos + size, tags);
                return;
            }
            pos += size;
        }
    }

    private static void parseIlst(RandomAccessFile raf, long start, long end,
                                  Tags tags) throws Exception {
        long pos = start;
        byte[] head = new byte[8];
        while (pos + 8 <= end) {
            raf.seek(pos);
            if (raf.read(head) != 8) {
                break;
            }
            long size = ((head[0] & 0xFFL) << 24) | ((head[1] & 0xFFL) << 16)
                    | ((head[2] & 0xFFL) << 8) | (head[3] & 0xFFL);
            String atomName = new String(head, 4, 4, "ISO-8859-1");
            if (size < 8 || pos + size > end) {
                break;
            }
            String field = ATOM_FIELDS.get(atomName);
            if (field != null) {
                // 在该 atom 内找 'data' 子块
                long p = pos + 8;
                byte[] sub = new byte[8];
                while (p + 8 <= pos + size) {
                    raf.seek(p);
                    if (raf.read(sub) != 8) {
                        break;
                    }
                    long dsize = ((sub[0] & 0xFFL) << 24) | ((sub[1] & 0xFFL) << 16)
                            | ((sub[2] & 0xFFL) << 8) | (sub[3] & 0xFFL);
                    String dtype = new String(sub, 4, 4, "ISO-8859-1");
                    if (dsize >= 16 && dtype.equals("data")) {
                        byte[] payload = new byte[(int) (dsize - 16)];
                        raf.seek(p + 16);
                        raf.readFully(payload);
                        apply(tags, field, atomName, payload);
                        break;
                    }
                    if (dsize < 8) {
                        break;
                    }
                    p += dsize;
                }
            }
            pos += size;
        }
    }

    private static void apply(Tags tags, String field, String atom, byte[] payload) {
        if (atom.equals("trkn")) {
            if (payload.length >= 4) {
                int value = ((payload[2] & 0xFF) << 8) | (payload[3] & 0xFF);
                if (value > 0) {
                    tags.put("track", String.valueOf(value));
                }
            }
            return;
        }
        if (atom.equals("gnre")) {
            if (payload.length >= 2) {
                int id = ((payload[0] & 0xFF) << 8) | (payload[1] & 0xFF);
                if (id >= 1 && id <= 80) {
                    tags.put("genre", "ID3 Genre " + (id - 1));
                }
            }
            return;
        }
        // 其余为 UTF-8 文本（data 版本标志 1）
        try {
            String v = TagText.decodeUtf8(payload).trim();
            if (!v.isEmpty()) {
                tags.put(field, v);
            }
        } catch (Exception ignored) {
        }
    }

    // ------------------------------------------------------------------
    // 写入（v0.1.9）
    // ------------------------------------------------------------------

    /** ilst 里字段对应的 atom 名。 */
    private static final Map<String, String> FIELD_ATOMS = new HashMap<String, String>();

    static {
        FIELD_ATOMS.put("title", "\u00a9nam");
        FIELD_ATOMS.put("artist", "\u00a9ART");
        FIELD_ATOMS.put("album", "\u00a9alb");
        FIELD_ATOMS.put("year", "\u00a9day");
        FIELD_ATOMS.put("track", "trkn");
        FIELD_ATOMS.put("genre", "\u00a9gen");
        FIELD_ATOMS.put("comment", "\u00a9cmt");
        FIELD_ATOMS.put("lyrics", "\u00a9lyr");
    }

    /**
     * 写入文本字段（{@code cover} 为 null 表示不动封面；长度为 0 表示删除封面）。
     * 合并语义：只替换 values 里出现的字段，其余 atom（含未知 atom）原样保留。
     */
    public static void write(File file, Map<String, String> values, byte[] cover) throws IOException {
        long len = file.length();
        List<long[]> atoms = new ArrayList<long[]>();
        List<String> types = new ArrayList<String>();
        RandomAccessFile raf = null;
        byte[] moov;
        long moovStart;
        long moovSize;
        try {
            raf = new RandomAccessFile(file, "r");
            byte[] head = new byte[8];
            long pos = 0;
            while (pos + 8 <= len) {
                raf.seek(pos);
                if (raf.read(head) != 8) {
                    break;
                }
                long size = be32(head, 0);
                String type = new String(head, 4, 4, "ISO-8859-1");
                int headerLen = 8;
                if (size == 1) {
                    byte[] ext = new byte[8];
                    raf.readFully(ext);
                    size = be64(ext, 0);
                    headerLen = 16;
                } else if (size == 0) {
                    size = len - pos;
                }
                if (size < headerLen || pos + size > len) {
                    break;
                }
                atoms.add(new long[]{pos, size, headerLen});
                types.add(type);
                pos += size;
            }
            int moovIdx = types.indexOf("moov");
            if (moovIdx < 0) {
                throw new IOException("MP4 里找不到 moov 块");
            }
            moovStart = atoms.get(moovIdx)[0];
            moovSize = atoms.get(moovIdx)[1];
            if (moovSize <= 0 || moovSize > Integer.MAX_VALUE - 16) {
                throw new IOException("moov 块大小异常");
            }
            moov = new byte[(int) moovSize];
            raf.seek(moovStart);
            raf.readFully(moov);
        } finally {
            close(raf);
        }

        byte[] newMoov = rebuildMoov(moov, values, cover);
        long delta = newMoov.length - moovSize;
        if (delta != 0) {
            // moov 之后的 chunk offset 全部右移（moov 在文件尾时这里自然改不到任何条）
            patchChunkOffsets(newMoov, moovStart + moovSize, delta);
        }

        File tmp = new File(file.getParentFile(), file.getName() + ".mo_mp4.tmp");
        java.io.RandomAccessFile out = null;
        java.io.FileInputStream in = null;
        try {
            out = new java.io.RandomAccessFile(tmp, "rw");
            out.setLength(0);
            in = new java.io.FileInputStream(file);
            byte[] buf = new byte[65536];
            for (int i = 0; i < atoms.size(); i++) {
                long start = atoms.get(i)[0];
                long size = atoms.get(i)[1];
                if (types.get(i).equals("moov")) {
                    out.write(newMoov);
                    continue;
                }
                in.getChannel().position(start);
                long remain = size;
                while (remain > 0) {
                    int n = in.read(buf, 0, (int) Math.min(buf.length, remain));
                    if (n <= 0) {
                        break;
                    }
                    out.write(buf, 0, n);
                    remain -= n;
                }
            }
        } finally {
            close(out);
            close(in);
        }
        if (!tmp.renameTo(file)) {
            File backup = new File(file.getParentFile(), file.getName() + ".mo_old.tmp");
            if (!file.renameTo(backup)) {
                //noinspection ResultOfMethodCallIgnored
                tmp.delete();
                throw new IOException("无法替换原文件");
            }
            if (!tmp.renameTo(file)) {
                //noinspection ResultOfMethodCallIgnored
                backup.renameTo(file);
                //noinspection ResultOfMethodCallIgnored
                tmp.delete();
                throw new IOException("无法替换原文件");
            }
            //noinspection ResultOfMethodCallIgnored
            backup.delete();
        }
    }

    /** 这个 MP4 里有没有封面（covr）。 */
    public static boolean hasCover(File file) {
        byte[] ilst = findIlst(readAtomOrNull(file, "moov"));
        if (ilst == null) {
            return false;
        }
        return findChild(ilst, 8, ilst.length, "covr") != null;
    }

    /** 第一个 stco/co64 的偏移列表（诊断/测试用）。 */
    public static long[] chunkOffsets(File file) {
        byte[] moov = readAtomOrNull(file, "moov");
        if (moov == null) {
            return new long[0];
        }
        List<long[]> found = new ArrayList<long[]>();
        collectChunkOffsets(moov, 0, moov.length, found);
        if (found.isEmpty()) {
            return new long[0];
        }
        // 只回第一个 stbl 的偏移（够诊断用）
        return found.get(0);
    }

    // ---- 内部：重建 moov ----

    private static byte[] rebuildMoov(byte[] moov, Map<String, String> values, byte[] cover)
            throws IOException {
        if (moov.length < 8) {
            throw new IOException("moov 块损坏");
        }
        int start = 8;
        List<byte[]> children = split(moov, start, moov.length);
        byte[] udta = findChild(children, "udta");
        byte[] oldMeta = udta == null ? null : findChild(split(udta, 8, udta.length), "meta");

        List<byte[]> metaChildren = new ArrayList<byte[]>();
        byte[] hdlr = null;
        byte[] oldIlst = null;
        if (oldMeta != null) {
            // meta 的头之后有 4 字节 version/flags
            metaChildren = split(oldMeta, 12, oldMeta.length);
            for (byte[] child : metaChildren) {
                String t = typeOf(child);
                if ("hdlr".equals(t)) {
                    hdlr = child;
                } else if ("ilst".equals(t)) {
                    oldIlst = child;
                }
            }
        }
        byte[] newIlst = rebuildIlst(oldIlst, values, cover);
        byte[] newMeta = atom("meta", concat(new byte[4], hdlr == null ? defaultHdlr() : hdlr,
                newIlst));
        byte[] newUdta = udta == null
                ? atom("udta", newMeta)
                : atom("udta", concat(withoutChild(udta, "meta"), newMeta));
        byte[] newMoov = atom("moov", udta == null
                ? concat(join(children), newUdta)
                : concat(withoutChild(moov, "udta"), newUdta));
        return newMoov;
    }

    private static byte[] rebuildIlst(byte[] oldIlst, Map<String, String> values, byte[] cover)
            throws IOException {
        List<byte[]> children = oldIlst == null ? new ArrayList<byte[]>()
                : split(oldIlst, 8, oldIlst.length);
        // 删除 / 替换由 values 指定的字段
        List<String> remove = new ArrayList<String>();
        List<byte[]> add = new ArrayList<byte[]>();
        if (values != null) {
            for (Map.Entry<String, String> e : values.entrySet()) {
                String atomName = FIELD_ATOMS.get(e.getKey());
                if (atomName == null) {
                    continue;
                }
                remove.add(atomName);
                String v = e.getValue() == null ? "" : e.getValue().trim();
                if (v.isEmpty()) {
                    continue;
                }
                if ("trkn".equals(atomName)) {
                    add.add(trackAtom(v));
                } else if ("\u00a9gen".equals(atomName)) {
                    add.add(textAtom(atomName, v));
                    remove.add("gnre"); // 旧式流派编号，留着会和文本流派打架
                } else {
                    add.add(textAtom(atomName, v));
                }
            }
        }
        if (cover != null) {
            remove.add("covr");
            if (cover.length > 0) {
                add.add(coverAtom(cover));
            }
        }
        List<byte[]> kept = new ArrayList<byte[]>();
        for (byte[] child : children) {
            String t = typeOf(child);
            if (!remove.contains(t)) {
                kept.add(child);
            }
        }
        kept.addAll(add);
        return atom("ilst", join(kept));
    }

    /** 文本 atom：data = type 1(UTF-8) + locale 0 + UTF-8 正文。 */
    private static byte[] textAtom(String name, String value) throws IOException {
        byte[] body = value.getBytes("UTF-8");
        byte[] data = new byte[8 + body.length];
        be32(data, 0, 1);
        System.arraycopy(body, 0, data, 8, body.length);
        return atom(name, atom("data", data));
    }

    /** 音轨号 atom：data = type 0 + 8 字节（保留/曲目/总数/保留）。 */
    private static byte[] trackAtom(String value) throws IOException {
        int track = 0;
        int total = 0;
        String v = value.trim();
        int slash = v.indexOf('/');
        try {
            track = Integer.parseInt((slash >= 0 ? v.substring(0, slash) : v).trim());
            if (slash >= 0) {
                total = Integer.parseInt(v.substring(slash + 1).trim());
            }
        } catch (NumberFormatException ignored) {
        }
        byte[] data = new byte[8 + 8];
        be32(data, 0, 0);
        data[10] = (byte) ((track >> 8) & 0xFF);
        data[11] = (byte) (track & 0xFF);
        data[12] = (byte) ((total >> 8) & 0xFF);
        data[13] = (byte) (total & 0xFF);
        return atom("trkn", atom("data", data));
    }

    /** 封面 atom：JPEG 用 data type 13、PNG 用 14。 */
    private static byte[] coverAtom(byte[] image) throws IOException {
        boolean png = image.length > 4 && (image[0] & 0xFF) == 0x89
                && image[1] == 'P' && image[2] == 'N' && image[3] == 'G';
        byte[] data = new byte[8 + image.length];
        be32(data, 0, png ? 14 : 13);
        System.arraycopy(image, 0, data, 8, image.length);
        return atom("covr", atom("data", data));
    }

    /** iTunes 惯用的 meta/hdlr。 */
    private static byte[] defaultHdlr() throws IOException {
        byte[] p = new byte[25];
        p[8] = 'm';
        p[9] = 'd';
        p[10] = 'i';
        p[11] = 'r';
        p[12] = 'a';
        p[13] = 'p';
        p[14] = 'p';
        p[15] = 'l';
        return atom("hdlr", p);
    }

    // ---- 内部：atom 工具 ----

    private static String typeOf(byte[] atomBytes) {
        if (atomBytes == null || atomBytes.length < 8) {
            return "";
        }
        return new String(atomBytes, 4, 4, java.nio.charset.StandardCharsets.ISO_8859_1);
    }

    private static byte[] atom(String type, byte[] payload) throws IOException {
        long size = 8L + payload.length;
        if (size > 0xFFFFFFFFL) {
            throw new IOException("块过大：" + type);
        }
        byte[] out = new byte[(int) size];
        be32(out, 0, size);
        byte[] t = type.getBytes(java.nio.charset.StandardCharsets.ISO_8859_1);
        System.arraycopy(t, 0, out, 4, 4);
        System.arraycopy(payload, 0, out, 8, payload.length);
        return out;
    }

    /** 按 atom 边界切分 [start,end) 区间的子块。 */
    private static List<byte[]> split(byte[] buf, int start, int end) {
        List<byte[]> out = new ArrayList<byte[]>();
        int pos = start;
        while (pos + 8 <= end) {
            long size = be32(buf, pos);
            if (size < 8 || pos + size > end) {
                break;
            }
            byte[] child = new byte[(int) size];
            System.arraycopy(buf, pos, child, 0, (int) size);
            out.add(child);
            pos += (int) size;
        }
        return out;
    }

    private static byte[] findChild(List<byte[]> children, String type) {
        for (byte[] child : children) {
            if (type.equals(typeOf(child))) {
                return child;
            }
        }
        return null;
    }

    /** 从父 atom（含 8 字节头）里找直接子块。 */
    private static byte[] findChild(byte[] parent, int start, int end, String type) {
        for (byte[] child : split(parent, start, end)) {
            if (type.equals(typeOf(child))) {
                return child;
            }
        }
        return null;
    }

    private static List<byte[]> childrenWithout(List<byte[]> children, String type) {
        List<byte[]> out = new ArrayList<byte[]>();
        for (byte[] child : children) {
            if (!type.equals(typeOf(child))) {
                out.add(child);
            }
        }
        return out;
    }

    /** 从父 atom 里去掉指定类型的直接子块，返回「头 + 剩余子块」。 */
    private static byte[] withoutChild(byte[] parent, String type) throws IOException {
        List<byte[]> keep = childrenWithout(split(parent, 8, parent.length), type);
        byte[] header = new byte[8];
        System.arraycopy(parent, 0, header, 0, 8);
        return atom(typeOf(parent), keep.isEmpty() ? new byte[0] : join(keep));
    }

    private static byte[] join(List<byte[]> parts) {
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

    private static byte[] concat(byte[]... parts) {
        int total = 0;
        for (byte[] p : parts) {
            if (p != null) {
                total += p.length;
            }
        }
        byte[] out = new byte[total];
        int off = 0;
        for (byte[] p : parts) {
            if (p != null) {
                System.arraycopy(p, 0, out, off, p.length);
                off += p.length;
            }
        }
        return out;
    }

    /** 把 offset >= threshold 的 chunk offset 全部加上 delta（原地修改 newMoov 字节）。 */
    private static void patchChunkOffsets(byte[] moov, long threshold, long delta) {
        List<long[]> boxes = new ArrayList<long[]>();
        collectBoxes(moov, 0, moov.length, "stco", boxes);
        collectBoxes(moov, 0, moov.length, "co64", boxes);
        for (long[] box : boxes) {
            boolean is64 = box[2] == 1;
            int p = (int) box[0] + 8 + 4; // 跳过 头 + version/flags
            if (p + 4 > moov.length) {
                continue;
            }
            long count = be32(moov, p);
            p += 4;
            for (long i = 0; i < count; i++) {
                if (is64) {
                    if (p + 8 > moov.length) {
                        break;
                    }
                    long v = be64(moov, p);
                    if (v >= threshold) {
                        putBe64(moov, p, v + delta);
                    }
                    p += 8;
                } else {
                    if (p + 4 > moov.length) {
                        break;
                    }
                    long v = be32(moov, p);
                    if (v >= threshold) {
                        putBe32(moov, p, v + delta);
                    }
                    p += 4;
                }
            }
        }
    }

    /** 递归找指定类型的 box，记下 {start, size, is64}。 */
    private static void collectBoxes(byte[] buf, int start, int end, String type,
                                     List<long[]> out) {
        int pos = start;
        while (pos + 8 <= end) {
            long size = be32(buf, pos);
            String t = new String(buf, pos + 4, 4,
                    java.nio.charset.StandardCharsets.ISO_8859_1);
            if (size < 8 || pos + size > end) {
                return;
            }
            if (t.equals(type)) {
                out.add(new long[]{pos, size, "co64".equals(type) ? 1 : 0});
            } else if (isContainer(t)) {
                int inside = pos + 8;
                if (t.equals("meta")) {
                    inside += 4;
                }
                collectBoxes(buf, inside, (int) (pos + size), type, out);
            }
            pos += (int) size;
        }
    }

    private static void collectChunkOffsets(byte[] buf, int start, int end, List<long[]> out) {
        int pos = start;
        while (pos + 8 <= end) {
            long size = be32(buf, pos);
            String t = new String(buf, pos + 4, 4,
                    java.nio.charset.StandardCharsets.ISO_8859_1);
            if (size < 8 || pos + size > end) {
                return;
            }
            if ("stco".equals(t) || "co64".equals(t)) {
                boolean is64 = "co64".equals(t);
                int p = pos + 8 + 4;
                long count = be32(buf, p);
                p += 4;
                long[] offsets = new long[(int) Math.max(0, Math.min(count, 10000))];
                for (int i = 0; i < offsets.length; i++) {
                    if (is64) {
                        offsets[i] = be64(buf, p);
                        p += 8;
                    } else {
                        offsets[i] = be32(buf, p);
                        p += 4;
                    }
                }
                out.add(offsets);
            } else if (isContainer(t)) {
                int inside = pos + 8;
                if ("meta".equals(t)) {
                    inside += 4;
                }
                collectChunkOffsets(buf, inside, (int) (pos + size), out);
            }
            pos += (int) size;
        }
    }

    private static boolean isContainer(String type) {
        return "moov".equals(type) || "trak".equals(type) || "mdia".equals(type)
                || "minf".equals(type) || "stbl".equals(type) || "udta".equals(type)
                || "meta".equals(type) || "ilst".equals(type) || "edts".equals(type);
    }

    private static byte[] readAtomOrNull(File file, String type) {
        RandomAccessFile raf = null;
        try {
            raf = new RandomAccessFile(file, "r");
            long len = file.length();
            byte[] head = new byte[8];
            long pos = 0;
            while (pos + 8 <= len) {
                raf.seek(pos);
                if (raf.read(head) != 8) {
                    return null;
                }
                long size = be32(head, 0);
                String t = new String(head, 4, 4, "ISO-8859-1");
                if (size == 1) {
                    byte[] ext = new byte[8];
                    raf.readFully(ext);
                    size = be64(ext, 0);
                } else if (size == 0) {
                    size = len - pos;
                }
                if (size < 8 || pos + size > len) {
                    return null;
                }
                if (t.equals(type)) {
                    byte[] data = new byte[(int) size];
                    raf.seek(pos);
                    raf.readFully(data);
                    return data;
                }
                pos += size;
            }
        } catch (Exception ignored) {
        } finally {
            close(raf);
        }
        return null;
    }

    /** 从 moov 里找到 ilst 的整块字节。 */
    private static byte[] findIlst(byte[] moov) {
        if (moov == null) {
            return null;
        }
        List<byte[]> moovChildren = split(moov, 8, moov.length);
        byte[] udta = findChild(moovChildren, "udta");
        if (udta == null) {
            return null;
        }
        byte[] meta = findChild(split(udta, 8, udta.length), "meta");
        if (meta == null || meta.length < 12) {
            return null;
        }
        return findChild(split(meta, 12, meta.length), "ilst");
    }

    private static long be32(byte[] b, int off) {
        return ((b[off] & 0xFFL) << 24) | ((b[off + 1] & 0xFFL) << 16)
                | ((b[off + 2] & 0xFFL) << 8) | (b[off + 3] & 0xFFL);
    }

    private static long be64(byte[] b, int off) {
        return (be32(b, off) << 32) | be32(b, off + 4);
    }

    private static void be32(byte[] b, int off, long v) {
        b[off] = (byte) ((v >> 24) & 0xFF);
        b[off + 1] = (byte) ((v >> 16) & 0xFF);
        b[off + 2] = (byte) ((v >> 8) & 0xFF);
        b[off + 3] = (byte) (v & 0xFF);
    }

    private static void putBe32(byte[] b, int off, long v) {
        be32(b, off, v);
    }

    private static void putBe64(byte[] b, int off, long v) {
        be32(b, off, v >> 32);
        be32(b, off + 4, v & 0xFFFFFFFFL);
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
