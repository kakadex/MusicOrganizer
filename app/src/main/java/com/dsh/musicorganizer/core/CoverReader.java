package com.dsh.musicorganizer.core;

import java.io.File;
import java.io.IOException;
import java.io.RandomAccessFile;

/**
 * 读内嵌封面（MP3 APIC / FLAC PICTURE / MP4 covr）。只读，纯字节，不碰 Bitmap。
 *
 * <p>和写入路径（{@link Id3} / {@link Flac} / {@link Mp4}）分开放：读只需要顺着结构找，
 * 不必重建任何块，失败了也只是「没有封面」，绝不能影响写入逻辑。
 */
public final class CoverReader {

    /** 单张封面最多读这么多字节，超过就放弃（防止一张怪图把内存吃光）。 */
    public static final int MAX_BYTES = 12 * 1024 * 1024;

    private CoverReader() {
    }

    /** 只要「有没有」，不真正读图片字节（列表徽标用，省内存）。 */
    public static boolean has(File file) {
        return read(file, true) != null;
    }

    /** 读出图片字节；没有封面或解析失败返回 null。 */
    public static byte[] read(File file) {
        return read(file, false);
    }

    private static byte[] read(File file, boolean probeOnly) {
        if (file == null || !file.exists() || file.length() < 16) {
            return null;
        }
        String ext = TagIO.extOf(file.getName());
        RandomAccessFile raf = null;
        try {
            raf = new RandomAccessFile(file, "r");
            if (ext.equals(".mp3")) {
                return readId3(raf, probeOnly);
            }
            if (ext.equals(".flac")) {
                return readFlac(raf, probeOnly);
            }
            if (ext.equals(".m4a") || ext.equals(".mp4")) {
                return readMp4(raf, probeOnly);
            }
        } catch (Exception ignored) {
            // 封面读失败不影响任何业务，当作没有
        } finally {
            close(raf);
        }
        return null;
    }

    // ------------------------------------------------------------------
    // MP3 / ID3v2
    // ------------------------------------------------------------------

    private static byte[] readId3(RandomAccessFile raf, boolean probeOnly) throws IOException {
        byte[] head = new byte[10];
        raf.seek(0);
        if (raf.read(head) != 10) {
            return null;
        }
        if (head[0] != 'I' || head[1] != 'D' || head[2] != '3') {
            return null;
        }
        int version = head[3] & 0xFF;
        int flags = head[5] & 0xFF;
        long size = syncsafe(head, 6);
        long pos = 10;
        long tagEnd = 10 + size;
        if ((flags & 0x40) != 0) {
            // 扩展头：v2.3 是 4 字节长度，v2.4 是 syncsafe
            byte[] ext = new byte[4];
            raf.seek(pos);
            if (raf.read(ext) != 4) {
                return null;
            }
            long extSize = version >= 4 ? syncsafe(ext, 0) : be32(ext, 0);
            pos += 4 + extSize;
        }
        while (pos + 10 <= tagEnd) {
            raf.seek(pos);
            byte[] header = new byte[10];
            if (raf.read(header) != 10) {
                return null;
            }
            if (header[0] == 0) {
                break;
            }
            String id = new String(header, 0, 4, "ISO-8859-1");
            long frameSize = version >= 4 ? syncsafe(header, 4) : be32(header, 4);
            if (frameSize <= 0 || pos + 10 + frameSize > tagEnd
                    || frameSize > MAX_BYTES + 1024) {
                return null;
            }
            if ("APIC".equals(id)) {
                if (probeOnly) {
                    return new byte[0];
                }
                byte[] frame = new byte[(int) frameSize];
                raf.readFully(frame);
                return parseApic(frame);
            }
            pos += 10 + frameSize;
        }
        return null;
    }

    /** APIC：编码(1) + MIME(0 结尾) + 图片类型(1) + 描述(0 结尾，UTF-16 时双字节) + 图片数据。 */
    static byte[] parseApic(byte[] frame) {
        if (frame == null || frame.length < 4) {
            return null;
        }
        int enc = frame[0] & 0xFF;
        int p = 1;
        // MIME
        while (p < frame.length && frame[p] != 0) {
            p++;
        }
        if (p >= frame.length) {
            return null;
        }
        p++; // 跳过 MIME 结尾的 0
        if (p >= frame.length) {
            return null;
        }
        p++; // 图片类型
        // 描述
        if (enc == 1 || enc == 2) {
            while (p + 1 < frame.length && !(frame[p] == 0 && frame[p + 1] == 0)) {
                p += 2;
            }
            p += 2;
        } else {
            while (p < frame.length && frame[p] != 0) {
                p++;
            }
            p++;
        }
        if (p < 0 || p >= frame.length) {
            return null;
        }
        int len = Math.min(frame.length - p, MAX_BYTES);
        byte[] out = new byte[len];
        System.arraycopy(frame, p, out, 0, len);
        return out;
    }

    // ------------------------------------------------------------------
    // FLAC
    // ------------------------------------------------------------------

    private static byte[] readFlac(RandomAccessFile raf, boolean probeOnly) throws IOException {
        byte[] magic = new byte[4];
        raf.seek(0);
        if (raf.read(magic) != 4 || magic[0] != 'f' || magic[1] != 'L'
                || magic[2] != 'a' || magic[3] != 'C') {
            return null;
        }
        long pos = 4;
        long len = raf.length();
        while (pos + 4 <= len) {
            raf.seek(pos);
            int b = raf.read();
            if (b < 0) {
                return null;
            }
            boolean last = (b & 0x80) != 0;
            int type = b & 0x7F;
            byte[] sizeBuf = new byte[3];
            if (raf.read(sizeBuf) != 3) {
                return null;
            }
            long blockLen = be24(sizeBuf, 0);
            if (type == 6) { // PICTURE
                if (probeOnly) {
                    return new byte[0];
                }
                if (blockLen > MAX_BYTES + 4096) {
                    return null;
                }
                byte[] block = new byte[(int) blockLen];
                raf.readFully(block);
                return parseFlacPicture(block);
            }
            if (last) {
                return null;
            }
            pos += 4 + blockLen;
        }
        return null;
    }

    /** FLAC PICTURE：type(4) mimeLen(4) mime descLen(4) desc w(4) h(4) depth(4) colors(4) dataLen(4) data。 */
    static byte[] parseFlacPicture(byte[] block) {
        if (block == null || block.length < 32) {
            return null;
        }
        int p = 4; // 图片类型
        long mimeLen = be32(block, p);
        p += 4;
        if (mimeLen < 0 || p + mimeLen > block.length) {
            return null;
        }
        p += (int) mimeLen;
        if (p + 4 > block.length) {
            return null;
        }
        long descLen = be32(block, p);
        p += 4;
        if (descLen < 0 || p + descLen > block.length) {
            return null;
        }
        p += (int) descLen;
        p += 16; // 宽 高 色深 索引色数
        if (p + 4 > block.length) {
            return null;
        }
        long dataLen = be32(block, p);
        p += 4;
        if (dataLen <= 0 || p + dataLen > block.length) {
            return null;
        }
        int len = (int) Math.min(dataLen, MAX_BYTES);
        byte[] out = new byte[len];
        System.arraycopy(block, p, out, 0, len);
        return out;
    }

    // ------------------------------------------------------------------
    // MP4 / M4A
    // ------------------------------------------------------------------

    private static byte[] readMp4(RandomAccessFile raf, boolean probeOnly) throws IOException {
        long[] moov = findTopAtom(raf, "moov");
        if (moov == null) {
            return null;
        }
        long start = moov[0] + 8;
        long end = moov[0] + moov[1];
        long[] udta = findChild(raf, start, end, "udta");
        if (udta == null) {
            return null;
        }
        long[] meta = findChild(raf, udta[0] + 8, udta[0] + udta[1], "meta");
        if (meta == null) {
            return null;
        }
        // meta 头之后有 4 字节 version/flags
        long[] ilst = findChild(raf, meta[0] + 12, meta[0] + meta[1], "ilst");
        if (ilst == null) {
            return null;
        }
        long[] covr = findChild(raf, ilst[0] + 8, ilst[0] + ilst[1], "covr");
        if (covr == null) {
            return null;
        }
        long[] data = findChild(raf, covr[0] + 8, covr[0] + covr[1], "data");
        if (data == null) {
            if (probeOnly) {
                return new byte[0];
            }
            return null;
        }
        if (probeOnly) {
            return new byte[0];
        }
        long payloadLen = data[1] - 16; // 8 头 + 4 类型 + 4 locale
        if (payloadLen <= 0) {
            return null;
        }
        int len = (int) Math.min(payloadLen, MAX_BYTES);
        byte[] out = new byte[len];
        raf.seek(data[0] + 16);
        raf.readFully(out);
        return out;
    }

    /** 顶层 atom：返回 {起点, 长度}。 */
    private static long[] findTopAtom(RandomAccessFile raf, String type) throws IOException {
        long len = raf.length();
        long pos = 0;
        byte[] head = new byte[8];
        while (pos + 8 <= len) {
            raf.seek(pos);
            if (raf.read(head) != 8) {
                return null;
            }
            long size = be32(head, 0);
            String t = new String(head, 4, 4, "ISO-8859-1");
            int headerLen = 8;
            if (size == 1) {
                byte[] ext = new byte[8];
                if (raf.read(ext) != 8) {
                    return null;
                }
                size = be64(ext, 0);
                headerLen = 16;
            } else if (size == 0) {
                size = len - pos;
            }
            if (size < headerLen || pos + size > len) {
                return null;
            }
            if (t.equals(type)) {
                return new long[]{pos, size};
            }
            pos += size;
        }
        return null;
    }

    /** 在 [start,end) 里找直接子 atom。 */
    private static long[] findChild(RandomAccessFile raf, long start, long end, String type)
            throws IOException {
        long pos = start;
        byte[] head = new byte[8];
        while (pos + 8 <= end) {
            raf.seek(pos);
            if (raf.read(head) != 8) {
                return null;
            }
            long size = be32(head, 0);
            String t = new String(head, 4, 4, "ISO-8859-1");
            if (size < 8 || pos + size > end) {
                return null;
            }
            if (t.equals(type)) {
                return new long[]{pos, size};
            }
            pos += size;
        }
        return null;
    }

    // ------------------------------------------------------------------

    private static long syncsafe(byte[] b, int off) {
        return ((long) (b[off] & 0x7F) << 21)
                | ((long) (b[off + 1] & 0x7F) << 14)
                | ((long) (b[off + 2] & 0x7F) << 7)
                | (b[off + 3] & 0x7F);
    }

    private static long be32(byte[] b, int off) {
        return ((b[off] & 0xFFL) << 24) | ((b[off + 1] & 0xFFL) << 16)
                | ((b[off + 2] & 0xFFL) << 8) | (b[off + 3] & 0xFFL);
    }

    private static long be24(byte[] b, int off) {
        return ((b[off] & 0xFFL) << 16) | ((b[off + 1] & 0xFFL) << 8) | (b[off + 2] & 0xFFL);
    }

    private static long be64(byte[] b, int off) {
        return (be32(b, off) << 32) | be32(b, off + 4);
    }

    private static void close(RandomAccessFile raf) {
        if (raf != null) {
            try {
                raf.close();
            } catch (Exception ignored) {
            }
        }
    }
}
