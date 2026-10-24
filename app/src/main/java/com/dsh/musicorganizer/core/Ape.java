package com.dsh.musicorganizer.core;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.RandomAccessFile;
import java.io.UnsupportedEncodingException;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * APEv2 标签读写（Monkey's Audio / WavPack / Musepack 等用同一套标签）。
 *
 * <p>结构：一串「键值项」+ 32 字节 footer（可选 32 字节 header）。footer 固定在文件尾
 * （ID3v1 之前），所以**加标签不需要搬动音频数据** —— 截到音频末尾再追加即可，
 * 这比 MP3 的「前置 ID3 要整体后移」安全得多。
 *
 * <p>键名不区分大小写；值可以是文本（UTF-8）或二进制。封面走二进制项
 * {@code Cover Art (Front)}，值的前若干字节是文件名（以 0 结尾），其后是图片本身。
 *
 * <p>写入时保留文件末尾的 ID3v1（如果有）：播放器/车载设备常读它，删掉会丢信息。
 */
public final class Ape {

    private Ape() {
    }

    private static final String MAGIC = "APETAGEX";
    private static final int FOOTER_SIZE = 32;
    private static final int FLAG_HAS_HEADER = 1 << 31;
    private static final int FLAG_IS_HEADER = 1 << 29;
    private static final int VERSION = 2000;

    /** 字段 → APE 键名（写入用；读取时按小写匹配，兼容各家写法）。 */
    private static final Map<String, String> KEYS = new LinkedHashMap<String, String>();

    static {
        KEYS.put("title", "Title");
        KEYS.put("artist", "Artist");
        KEYS.put("album", "Album");
        KEYS.put("year", "Year");
        KEYS.put("track", "Track");
        KEYS.put("genre", "Genre");
        KEYS.put("comment", "Comment");
        KEYS.put("lyrics", "Lyrics");
    }

    public static boolean isApe(File file) {
        if (file == null || !file.isFile() || file.length() < 4) {
            return false;
        }
        RandomAccessFile raf = null;
        try {
            raf = new RandomAccessFile(file, "r");
            byte[] magic = new byte[4];
            raf.readFully(magic);
            // "MAC " = Monkey's Audio；WavPack 是 "wvpk"，Musepack 是 "MPCK"/"MP+"
            return (magic[0] == 'M' && magic[1] == 'A' && magic[2] == 'C' && magic[3] == ' ')
                    || (magic[0] == 'w' && magic[1] == 'v' && magic[2] == 'p' && magic[3] == 'k')
                    || (magic[0] == 'M' && magic[1] == 'P' && magic[2] == 'C' && magic[3] == 'K');
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
        if (!isApe(file)) {
            return tags;
        }
        try {
            Bag root = readItems(file);
            if (root == null) {
                return tags;
            }
            for (Map.Entry<String, Item> e : root.items.entrySet()) {
                String key = e.getKey();
                Item item = e.getValue();
                String field = fieldOf(key);
                if (field == null || item.binary) {
                    continue;
                }
                String value = item.text().trim();
                if (!value.isEmpty() && tags.get(field).isEmpty()) {
                    tags.put(field, value);
                }
            }
        } catch (Exception ignored) {
        }
        return tags;
    }

    /**
     * 读任意键（大小写不敏感，含自定义键）。
     *
     * <p>批量写入是「合并语义」：只替换用户改的字段，其它键原样保留。
     * 保留得对不对没法从固定字段看出来，所以开放这个入口给回归测试用。
     */
    public static String readRaw(File file, String key) {
        try {
            Bag bag = readItems(file);
            if (bag == null) {
                return "";
            }
            for (Map.Entry<String, Item> e : bag.items.entrySet()) {
                if (e.getKey().equalsIgnoreCase(key)) {
                    return e.getValue().binary ? "" : e.getValue().text();
                }
            }
        } catch (Exception ignored) {
        }
        return "";
    }

    /** 有没有内嵌封面（Cover Art (Front) 二进制项）。 */
    public static boolean hasCover(File file) {
        try {
            Bag root = readItems(file);
            if (root == null) {
                return false;
            }
            for (Map.Entry<String, Item> e : root.items.entrySet()) {
                String k = e.getKey().toLowerCase(Locale.US);
                if (k.startsWith("cover art") && e.getValue().binary) {
                    return true;
                }
            }
        } catch (Exception ignored) {
        }
        return false;
    }

    private static String fieldOf(String key) {
        String k = key.toLowerCase(Locale.US);
        for (Map.Entry<String, String> e : KEYS.entrySet()) {
            if (e.getValue().toLowerCase(Locale.US).equals(k)) {
                return e.getKey();
            }
        }
        if (k.equals("album artist")) {
            return null;
        }
        return null;
    }

    // ------------------------------------------------------------------
    // 写
    // ------------------------------------------------------------------

    public static void rewrite(File file, Map<String, String> values, byte[] cover)
            throws IOException {
        if (!isApe(file)) {
            throw new IOException("不是有效的 APE / WavPack / Musepack 文件");
        }
        Loc loc = find(file);
        long id3v1Start = loc.id3v1Start;
        long audioEnd = loc.tagStart >= 0 ? loc.tagStart : id3v1Start;

        // 旧标签里其它键原样保留（合并语义：只替换用户改的字段）
        Map<String, Item> merged = new LinkedHashMap<String, Item>();
        Bag old = readItems(file);
        if (old != null) {
            merged.putAll(old.items);
        }
        for (Map.Entry<String, String> e : values.entrySet()) {
            String apexKey = KEYS.get(e.getKey());
            if (apexKey == null) {
                continue;
            }
            removeKeyIgnoreCase(merged, apexKey);
            String value = e.getValue() == null ? "" : e.getValue();
            if (!"lyrics".equals(e.getKey())) {
                value = value.trim();
            }
            if (!value.isEmpty()) {
                merged.put(apexKey, Item.text(value));
            }
        }
        if (cover != null) {
            removeCover(merged);
            if (cover.length > 0) {
                merged.put("Cover Art (Front)", Item.binary(coverWithName(cover)));
            }
        }
        byte[] tag = buildTag(merged);

        // 保留 ID3v1（放在新标签之后，仍处于文件最末 128 字节）
        byte[] id3v1 = null;
        if (id3v1Start < file.length()) {
            id3v1 = readRange(file, id3v1Start, 128);
        }

        File tmp = new File(file.getParentFile(), file.getName() + ".mo_ape.tmp");
        RandomAccessFile in = null;
        FileOutputStream out = null;
        try {
            in = new RandomAccessFile(file, "r");
            out = new FileOutputStream(tmp);
            in.seek(0);
            byte[] buf = new byte[65536];
            long left = audioEnd;
            while (left > 0) {
                int n = in.read(buf, 0, (int) Math.min(buf.length, left));
                if (n <= 0) {
                    break;
                }
                out.write(buf, 0, n);
                left -= n;
            }
            out.write(tag);
            if (id3v1 != null && id3v1.length == 128) {
                out.write(id3v1);
            }
            out.getFD().sync();
        } finally {
            close(in);
            close(out);
        }

        // 自检：音频段必须逐字节一致，标签能读回来
        if (!audioSame(file, tmp, audioEnd)) {
            //noinspection ResultOfMethodCallIgnored
            tmp.delete();
            throw new IOException("APE 校验失败：音频段被改动，已取消写入");
        }
        copyFile(tmp, file);
        //noinspection ResultOfMethodCallIgnored
        tmp.delete();
    }

    private static byte[] coverWithName(byte[] image) {
        // APEv2 封面的值 = 文件名 + 0 + 图片字节
        byte[] name = "cover.jpg".getBytes();
        byte[] out = new byte[name.length + 1 + image.length];
        System.arraycopy(name, 0, out, 0, name.length);
        out[name.length] = 0;
        System.arraycopy(image, 0, out, name.length + 1, image.length);
        return out;
    }

    private static void removeKeyIgnoreCase(Map<String, Item> map, String key) {
        List<String> drop = new ArrayList<String>();
        for (String k : map.keySet()) {
            if (k.equalsIgnoreCase(key)) {
                drop.add(k);
            }
        }
        for (String k : drop) {
            map.remove(k);
        }
    }

    private static void removeCover(Map<String, Item> map) {
        List<String> drop = new ArrayList<String>();
        for (String k : map.keySet()) {
            if (k.toLowerCase(Locale.US).startsWith("cover art")) {
                drop.add(k);
            }
        }
        for (String k : drop) {
            map.remove(k);
        }
    }

    /** items + footer（不带 header，兼容性最好）。 */
    private static byte[] buildTag(Map<String, Item> items) throws IOException {
        java.io.ByteArrayOutputStream body = new java.io.ByteArrayOutputStream(1024);
        for (Map.Entry<String, Item> e : items.entrySet()) {
            Item it = e.getValue();
            byte[] key = e.getKey().getBytes("US-ASCII");
            int valueLen = it.value.length;
            body.write(le32(valueLen));
            body.write(le32(it.binary ? 2 : 0)); // bit1 = 二进制
            body.write(key);
            body.write(0);
            body.write(it.value);
        }
        byte[] itemsBytes = body.toByteArray();
        int tagSize = itemsBytes.length + FOOTER_SIZE;
        java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream(tagSize);
        out.write(itemsBytes);
        // 只写 footer，不写 header（flag 里不能声称有 header，否则解析时起点会多减 32 字节）
        out.write(footer(tagSize, items.size(), 0));
        return out.toByteArray();
    }

    private static byte[] footer(int tagSize, int count, int flags) throws IOException {
        byte[] f = new byte[FOOTER_SIZE];
        System.arraycopy(MAGIC.getBytes("US-ASCII"), 0, f, 0, 8);
        putLe32(f, 8, VERSION);
        putLe32(f, 12, tagSize);
        putLe32(f, 16, count);
        putLe32(f, 20, flags);
        // 24..32 保留
        return f;
    }

    // ------------------------------------------------------------------
    // 定位与解析
    // ------------------------------------------------------------------

    private static final class Loc {
        /** 标签起点（没有标签时 = -1）。 */
        long tagStart = -1;
        /** ID3v1 起点（没有则 = 文件长度）。 */
        long id3v1Start;
    }

    private static Loc find(File file) {
        Loc loc = new Loc();
        long len = file.length();
        loc.id3v1Start = len;
        loc.id3v1Start = hasId3v1(file, len) ? len - 128 : len;
        long searchEnd = loc.id3v1Start;
        if (searchEnd < FOOTER_SIZE) {
            return loc;
        }
        // footer 在末尾：读最后 32 字节判断
        byte[] tail = readRange(file, searchEnd - FOOTER_SIZE, FOOTER_SIZE);
        if (!isMagic(tail)) {
            return loc;
        }
        int tagSize = (int) u32(tail, 12);
        int flags = (int) u32(tail, 20);
        boolean hasHeader = (flags & FLAG_HAS_HEADER) != 0;
        long start = searchEnd - tagSize;
        if (start < 0) {
            return loc;
        }
        loc.tagStart = start;
        if (hasHeader && start >= FOOTER_SIZE) {
            loc.tagStart = start - FOOTER_SIZE;
        }
        return loc;
    }

    private static boolean hasId3v1(File file, long len) {
        if (len < 128) {
            return false;
        }
        byte[] tail = readRange(file, len - 128, 3);
        return tail[0] == 'T' && tail[1] == 'A' && tail[2] == 'G';
    }

    /** 一个标签项（文本或二进制）。 */
    private static final class Item {
        byte[] value = new byte[0];
        boolean binary;

        static Item text(String s) {
            Item it = new Item();
            try {
                it.value = s.getBytes("UTF-8");
            } catch (UnsupportedEncodingException e) {
                it.value = s.getBytes();
            }
            return it;
        }

        static Item binary(byte[] v) {
            Item it = new Item();
            it.value = v;
            it.binary = true;
            return it;
        }

        String text() {
            try {
                return new String(value, "UTF-8");
            } catch (UnsupportedEncodingException e) {
                return new String(value);
            }
        }
    }

    /** 标签容器：键 → 项。 */
    private static final class Bag {
        final Map<String, Item> items = new LinkedHashMap<String, Item>();
    }

    /** 读出标签里的全部项（大小写不敏感，重名只留第一个）。 */
    private static Bag readItems(File file) {
        Loc loc = find(file);
        if (loc.tagStart < 0) {
            return null;
        }
        long itemsStart = loc.tagStart;
        long itemsEnd = loc.id3v1Start;
        // items 从 header 之后或 footer 之前开始：以 footer 为准
        byte[] tail = readRange(file, itemsEnd - FOOTER_SIZE, FOOTER_SIZE);
        int tagSize = (int) u32(tail, 12);
        int count = (int) u32(tail, 16);
        int flags = (int) u32(tail, 20);
        long start = itemsEnd - tagSize;
        if ((flags & FLAG_HAS_HEADER) != 0) {
            start += FOOTER_SIZE; // 跳过 header
        }
        itemsStart = start;
        long len = itemsEnd - FOOTER_SIZE - itemsStart;
        if (len <= 0 || len > 64L * 1024 * 1024) {
            return null;
        }
        byte[] buf = readRange(file, itemsStart, (int) len);
        Bag root = new Bag();
        int pos = 0;
        for (int i = 0; i < count && pos + 8 <= buf.length; i++) {
            long valueSize = u32(buf, pos);
            int itemFlags = (int) u32(buf, pos + 4);
            pos += 8;
            int keyStart = pos;
            while (pos < buf.length && buf[pos] != 0) {
                pos++;
            }
            if (pos >= buf.length) {
                break;
            }
            String key;
            try {
                key = new String(buf, keyStart, pos - keyStart, "US-ASCII");
            } catch (UnsupportedEncodingException e) {
                break;
            }
            pos++; // 跳过 0
            if (valueSize < 0 || pos + valueSize > buf.length) {
                break;
            }
            Item it = new Item();
            it.binary = (itemFlags & 2) != 0;
            it.value = new byte[(int) valueSize];
            System.arraycopy(buf, pos, it.value, 0, (int) valueSize);
            pos += valueSize;
            if (!containsIgnoreCase(root.items, key)) {
                root.items.put(key, it);
            }
        }
        return root;
    }

    private static boolean containsIgnoreCase(Map<String, Item> map, String key) {
        for (String k : map.keySet()) {
            if (k.equalsIgnoreCase(key)) {
                return true;
            }
        }
        return false;
    }

    private static boolean audioSame(File a, File b, long audioEnd) {
        try {
            if (a.length() < audioEnd || b.length() < audioEnd) {
                return false;
            }
            RandomAccessFile ra = new RandomAccessFile(a, "r");
            RandomAccessFile rb = new RandomAccessFile(b, "r");
            try {
                byte[] ba = new byte[65536];
                byte[] bb = new byte[65536];
                long left = audioEnd;
                while (left > 0) {
                    int n = (int) Math.min(ba.length, left);
                    ra.readFully(ba, 0, n);
                    rb.readFully(bb, 0, n);
                    for (int i = 0; i < n; i++) {
                        if (ba[i] != bb[i]) {
                            return false;
                        }
                    }
                    left -= n;
                }
                return true;
            } finally {
                close(ra);
                close(rb);
            }
        } catch (Exception e) {
            return false;
        }
    }

    // ------------------------------------------------------------------
    // 工具
    // ------------------------------------------------------------------

    private static boolean isMagic(byte[] b) {
        if (b == null || b.length < 8) {
            return false;
        }
        for (int i = 0; i < 8; i++) {
            if (b[i] != MAGIC.charAt(i)) {
                return false;
            }
        }
        return true;
    }

    private static byte[] readRange(File file, long offset, int size) {
        try {
            RandomAccessFile raf = new RandomAccessFile(file, "r");
            try {
                byte[] out = new byte[size];
                raf.seek(offset);
                raf.readFully(out);
                return out;
            } finally {
                close(raf);
            }
        } catch (Exception e) {
            return new byte[0];
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

    private static long u32(byte[] b, int off) {
        return ((long) (b[off] & 0xFF)) | ((long) (b[off + 1] & 0xFF) << 8)
                | ((long) (b[off + 2] & 0xFF) << 16) | ((long) (b[off + 3] & 0xFF) << 24);
    }

    private static void putLe32(byte[] b, int off, long v) {
        b[off] = (byte) (v & 0xFF);
        b[off + 1] = (byte) ((v >> 8) & 0xFF);
        b[off + 2] = (byte) ((v >> 16) & 0xFF);
        b[off + 3] = (byte) ((v >> 24) & 0xFF);
    }

    private static byte[] le32(long v) {
        byte[] out = new byte[4];
        putLe32(out, 0, v);
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
