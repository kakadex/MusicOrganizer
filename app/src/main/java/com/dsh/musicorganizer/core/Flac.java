package com.dsh.musicorganizer.core;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.RandomAccessFile;
import java.nio.charset.Charset;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * FLAC Vorbis Comment 读写（纯手写，零依赖）。
 *
 * 元数据块结构：4 字节 magic + [1 字节(最后块标志<<7|类型) + 3 字节长度]。
 * 类型 4 = VORBIS_COMMENT（vendor 长度 + vendor + 条目数 + "KEY=value" 列表，
 * 全部小端）。重写时只替换该块，PICTURE 等其余块原样保留。
 */
public final class Flac {

    private Flac() {
    }

    private static final Charset UTF8 = Charset.forName("UTF-8");
    private static final int TYPE_VORBIS_COMMENT = 4;
    /** PICTURE 块（封面）：类型 6 */
    private static final int TYPE_PICTURE = 6;

    private static final Map<String, String> READ_KEYS = new java.util.HashMap<String, String>();

    static {
        READ_KEYS.put("TITLE", "title");
        READ_KEYS.put("ARTIST", "artist");
        READ_KEYS.put("ALBUM", "album");
        READ_KEYS.put("DATE", "year");
        READ_KEYS.put("TRACKNUMBER", "track");
        READ_KEYS.put("GENRE", "genre");
        READ_KEYS.put("DESCRIPTION", "comment");
        READ_KEYS.put("COMMENT", "comment");
        READ_KEYS.put("LYRICS", "lyrics");
        READ_KEYS.put("UNSYNCEDLYRICS", "lyrics");
    }

    private static final Map<String, String> WRITE_KEYS = new java.util.HashMap<String, String>();

    static {
        WRITE_KEYS.put("title", "TITLE");
        WRITE_KEYS.put("artist", "ARTIST");
        WRITE_KEYS.put("album", "ALBUM");
        WRITE_KEYS.put("year", "DATE");
        WRITE_KEYS.put("track", "TRACKNUMBER");
        WRITE_KEYS.put("genre", "GENRE");
        WRITE_KEYS.put("comment", "DESCRIPTION");
        WRITE_KEYS.put("lyrics", "LYRICS");
    }

    public static boolean isFlac(File file) {
        FileInputStream in = null;
        try {
            in = new FileInputStream(file);
            byte[] magic = new byte[4];
            if (in.read(magic) != 4) {
                return false;
            }
            return magic[0] == 'f' && magic[1] == 'L' && magic[2] == 'a' && magic[3] == 'C';
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
            byte[] magic = new byte[4];
            raf.readFully(magic);
            long pos = 4;
            while (true) {
                raf.seek(pos);
                int b = raf.read();
                if (b < 0) {
                    break;
                }
                boolean last = (b & 0x80) != 0;
                int type = b & 0x7F;
                int len = (raf.read() & 0xFF) << 16 | (raf.read() & 0xFF) << 8 | (raf.read() & 0xFF);
                long blockStart = pos + 4;
                if (type == TYPE_VORBIS_COMMENT) {
                    byte[] data = new byte[len];
                    raf.seek(blockStart);
                    raf.readFully(data);
                    parseComments(tags, data);
                    return tags;
                }
                pos = blockStart + len;
                if (last) {
                    break;
                }
            }
        } catch (Exception ignored) {
        } finally {
            close(raf);
        }
        return tags;
    }

    private static void parseComments(Tags tags, byte[] data) {
        int p = 0;
        long vendorLen = le32(data, p);
        p += 4 + (int) vendorLen;
        if (p + 4 > data.length) {
            return;
        }
        long count = le32(data, p);
        p += 4;
        for (long i = 0; i < count && p + 4 <= data.length; i++) {
            int len = (int) le32(data, p);
            p += 4;
            if (len < 0 || p + len > data.length) {
                break;
            }
            String entry = TagText.decodeUtf8(java.util.Arrays.copyOfRange(data, p, p + len));
            p += len;
            int eq = entry.indexOf('=');
            if (eq <= 0) {
                continue;
            }
            String key = entry.substring(0, eq).toUpperCase(java.util.Locale.US);
            String value = entry.substring(eq + 1).trim();
            String field = READ_KEYS.get(key);
            if (field != null && !value.isEmpty()) {
                if (field.equals("artist") && !tags.get("artist").isEmpty()) {
                    tags.put("artist", tags.get("artist") + "," + value);
                } else {
                    tags.put(field, value);
                }
            }
        }
    }

    public static void rewrite(File file, Map<String, String> values) throws IOException {
        rewrite(file, values, null);
    }

    /**
     * 写入字段；{@code cover} 为 null 表示不动封面块，
     * 长度为 0 表示删除 PICTURE 块，否则替换为这张图。
     */
    public static void rewrite(File file, Map<String, String> values, byte[] cover)
            throws IOException {
        // 读取所有块
        List<int[]> heads = new ArrayList<int[]>(); // {type, length, offset}
        List<byte[]> blocks = new ArrayList<byte[]>();
        List<Integer> pictureIndexes = new ArrayList<Integer>();
        int vcIndex = -1;
        RandomAccessFile raf = null;
        long audioStart;
        try {
            raf = new RandomAccessFile(file, "r");
            byte[] magic = new byte[4];
            raf.readFully(magic);
            long pos = 4;
            while (true) {
                raf.seek(pos);
                int b = raf.read();
                if (b < 0) {
                    throw new IOException("FLAC 块解析失败");
                }
                boolean last = (b & 0x80) != 0;
                int type = b & 0x7F;
                int len = (raf.read() & 0xFF) << 16 | (raf.read() & 0xFF) << 8 | (raf.read() & 0xFF);
                byte[] data = new byte[len];
                raf.seek(pos + 4);
                raf.readFully(data);
                if (type == TYPE_VORBIS_COMMENT) {
                    vcIndex = heads.size();
                }
                if (type == TYPE_PICTURE) {
                    pictureIndexes.add(Integer.valueOf(heads.size()));
                }
                heads.add(new int[]{type, len, 0});
                blocks.add(data);
                pos += 4 + len;
                if (last) {
                    break;
                }
            }
            audioStart = pos;
        } finally {
            close(raf);
        }

        // 没有既有 VORBIS_COMMENT 块时，在 STREAMINFO 后插入一个
        if (vcIndex < 0) {
            int insertAt = Math.min(1, heads.size());
            heads.add(insertAt, new int[]{TYPE_VORBIS_COMMENT, 0, 0});
            blocks.add(insertAt, new byte[0]);
            vcIndex = insertAt;
        }

        byte[] vendor = new byte[0];
        if (vcIndex >= 0) {
            byte[] old = blocks.get(vcIndex);
            // 新建的块长度为 0：不能直接 arraycopy（srcPos 越界会抛异常）
            long vendorLen = old.length >= 4 ? le32(old, 0) : 0;
            if (vendorLen > 0 && 4 + vendorLen <= old.length) {
                vendor = new byte[(int) vendorLen];
                System.arraycopy(old, 4, vendor, 0, (int) vendorLen);
            }
        }

        // 组装新的 VORBIS_COMMENT：新值覆盖 + 其余旧条目保留
        List<String> entries = new ArrayList<String>();
        if (vcIndex >= 0) {
            byte[] old = blocks.get(vcIndex);
            int p = 4 + (int) le32(old, 0);
            if (p + 4 <= old.length) {
                int count = (int) le32(old, p);
                p += 4;
                for (int i = 0; i < count && p + 4 <= old.length; i++) {
                    int len = (int) le32(old, p);
                    p += 4;
                    if (p + len > old.length) {
                        break;
                    }
                    String entry = TagText.decodeUtf8(java.util.Arrays.copyOfRange(old, p, p + len));
                    p += len;
                    int eq = entry.indexOf('=');
                    String key = eq > 0 ? entry.substring(0, eq).toUpperCase(java.util.Locale.US) : "";
                    boolean replaced = false;
                    for (Map.Entry<String, String> e : values.entrySet()) {
                        String wk = WRITE_KEYS.get(e.getKey());
                        if (wk != null && wk.equals(key)) {
                            replaced = true;
                            break;
                        }
                        // 歌词有两个常见键名，写 LYRICS 时把旧的 UNSYNCEDLYRICS 一并替换掉
                        if ("lyrics".equals(e.getKey())
                                && "UNSYNCEDLYRICS".equals(key)) {
                            replaced = true;
                            break;
                        }
                    }
                    if (!replaced && !entry.trim().isEmpty()) {
                        entries.add(entry);
                    }
                }
            }
        }
        for (Map.Entry<String, String> e : values.entrySet()) {
            String key = WRITE_KEYS.get(e.getKey());
            String value = e.getValue() == null ? "" : e.getValue().trim();
            if (key == null || value.isEmpty()) {
                continue;
            }
            entries.add(key + "=" + value);
        }
        byte[] newBlock = buildVorbisComment(vendor, entries);

        // 封面：要写就替换所有旧 PICTURE 块，要清就整块删掉
        if (cover != null) {
            for (int i = pictureIndexes.size() - 1; i >= 0; i--) {
                int idx = pictureIndexes.get(i).intValue();
                blocks.remove(idx);
                heads.remove(idx);
                if (idx < vcIndex) {
                    vcIndex--;
                }
            }
            if (cover.length > 0) {
                heads.add(new int[]{TYPE_PICTURE, 0, 0});
                blocks.add(buildPicture(cover));
            }
        }

        // 写新文件
        File tmp = new File(file.getParentFile(), file.getName() + ".mo_flac.tmp");
        FileOutputStream out = null;
        FileInputStream in = null;
        try {
            out = new FileOutputStream(tmp);
            out.write(new byte[]{'f', 'L', 'a', 'C'});
            for (int i = 0; i < heads.size(); i++) {
                boolean last = i == heads.size() - 1;
                byte[] data = i == vcIndex ? newBlock : blocks.get(i);
                int type = heads.get(i)[0];
                out.write((last ? 0x80 : 0) | type);
                out.write((data.length >> 16) & 0xFF);
                out.write((data.length >> 8) & 0xFF);
                out.write(data.length & 0xFF);
                out.write(data);
            }
            // 复制音频帧
            in = new FileInputStream(file);
            long skipped = 0;
            byte[] buf = new byte[65536];
            while (skipped < audioStart) {
                long n = in.skip(audioStart - skipped);
                if (n <= 0) {
                    break;
                }
                skipped += n;
            }
            int n;
            while ((n = in.read(buf)) > 0) {
                out.write(buf, 0, n);
            }
        } finally {
            if (out != null) {
                try {
                    out.close();
                } catch (Exception ignored) {
                }
            }
            if (in != null) {
                try {
                    in.close();
                } catch (Exception ignored) {
                }
            }
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

    /** PICTURE 块：类型 3（前置封面）+ MIME + 空描述 + 宽高深色数 + 图片字节。 */
    private static byte[] buildPicture(byte[] image) {
        int[] dim = CoverArt.dimensions(image);
        String mime = CoverArt.mimeOf(image);
        if (mime.isEmpty()) {
            mime = "image/jpeg";
        }
        ByteArrayOutputStream out = new ByteArrayOutputStream(image.length + 64);
        try {
            out.write(be32Bytes(3));
            byte[] m = mime.getBytes("US-ASCII");
            out.write(be32Bytes(m.length));
            out.write(m);
            out.write(be32Bytes(0)); // 空描述
            out.write(be32Bytes(dim[0]));
            out.write(be32Bytes(dim[1]));
            out.write(be32Bytes(24)); // 色深
            out.write(be32Bytes(0));  // 索引色数
            out.write(be32Bytes(image.length));
            out.write(image);
        } catch (IOException ignored) {
        }
        return out.toByteArray();
    }

    /** 这个 FLAC 里有没有封面（PICTURE 块）。 */
    public static boolean hasPicture(File file) {
        RandomAccessFile raf = null;
        try {
            raf = new RandomAccessFile(file, "r");
            byte[] magic = new byte[4];
            raf.readFully(magic);
            if (!(magic[0] == 'f' && magic[1] == 'L' && magic[2] == 'a' && magic[3] == 'C')) {
                return false;
            }
            long pos = 4;
            long len = file.length();
            while (pos + 4 <= len) {
                raf.seek(pos);
                int b = raf.read();
                if (b < 0) {
                    return false;
                }
                boolean last = (b & 0x80) != 0;
                int type = b & 0x7F;
                int b0 = raf.read();
                int b1 = raf.read();
                int b2 = raf.read();
                if (b1 < 0 || b2 < 0) {
                    return false;
                }
                long blockLen = (b0 & 0xFF) << 16 | (b1 & 0xFF) << 8 | (b2 & 0xFF);
                if (type == TYPE_PICTURE) {
                    return true;
                }
                if (last) {
                    return false;
                }
                pos += 4 + blockLen;
            }
        } catch (Exception ignored) {
        } finally {
            close(raf);
        }
        return false;
    }

    private static byte[] be32Bytes(long v) {
        return new byte[]{
                (byte) ((v >> 24) & 0xFF),
                (byte) ((v >> 16) & 0xFF),
                (byte) ((v >> 8) & 0xFF),
                (byte) (v & 0xFF),
        };
    }

    private static byte[] buildVorbisComment(byte[] vendor, List<String> entries) {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        try {
            out.write(le32Bytes(vendor.length));
            out.write(vendor);
            out.write(le32Bytes(entries.size()));
            for (String entry : entries) {
                byte[] b = entry.getBytes(UTF8);
                out.write(le32Bytes(b.length));
                out.write(b);
            }
        } catch (IOException ignored) {
        }
        return out.toByteArray();
    }

    private static long le32(byte[] b, int off) {
        if (off + 4 > b.length) {
            return 0;
        }
        return (b[off] & 0xFFL) | ((b[off + 1] & 0xFFL) << 8)
                | ((b[off + 2] & 0xFFL) << 16) | ((b[off + 3] & 0xFFL) << 24);
    }

    private static byte[] le32Bytes(long v) {
        return new byte[]{
                (byte) (v & 0xFF),
                (byte) ((v >> 8) & 0xFF),
                (byte) ((v >> 16) & 0xFF),
                (byte) ((v >> 24) & 0xFF),
        };
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
