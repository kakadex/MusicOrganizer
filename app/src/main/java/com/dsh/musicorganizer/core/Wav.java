package com.dsh.musicorganizer.core;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.RandomAccessFile;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * WAV（RIFF/WAVE）标签读写。
 *
 * <p>WAV 没有原生标签区，业界有两种挂法：
 * <ul>
 *   <li><b>RIFF LIST/INFO</b>：{@code INAM} 标题、{@code IART} 歌手、{@code IPRD} 专辑…… 字段少、字符集混乱；</li>
 *   <li><b>文件尾的 {@code id3 } 块</b>：内容是一段完整 ID3v2 标签（Kid3、foobar2000、Mp3tag 都这么写）。</li>
 * </ul>
 *
 * <p>读取时优先 ID3（字段全、支持封面与歌词），没有才退回 INFO；
 * 写入时统一写 ID3 块，并顺手清掉旧的 INFO 块 —— 两份标签并存会让不同播放器显示不同的值。
 *
 * <p>所有 chunk 都是小端长度；奇数长度要补 1 字节对齐，漏掉会让后面的 chunk 全部错位。
 */
public final class Wav {

    private Wav() {
    }

    public static boolean isWav(File file) {
        if (file == null || !file.isFile() || file.length() < 12) {
            return false;
        }
        RandomAccessFile raf = null;
        try {
            raf = new RandomAccessFile(file, "r");
            byte[] head = new byte[12];
            raf.readFully(head);
            return head[0] == 'R' && head[1] == 'I' && head[2] == 'F' && head[3] == 'F'
                    && head[8] == 'W' && head[9] == 'A' && head[10] == 'V' && head[11] == 'E';
        } catch (Exception e) {
            return false;
        } finally {
            close(raf);
        }
    }

    /** 读标签：优先文件里的 ID3 块，否则解 LIST/INFO。 */
    public static Tags read(File file) {
        Tags tags = new Tags();
        if (!isWav(file)) {
            return tags;
        }
        List<Chunk> chunks = chunks(file);
        Chunk id3 = null;
        Chunk info = null;
        for (Chunk c : chunks) {
            if (c.isId3()) {
                id3 = c;
            } else if (c.isInfoList()) {
                info = c;
            }
        }
        if (id3 != null) {
            File tmp = null;
            try {
                byte[] data = readBytes(file, id3.dataOffset, (int) id3.size);
                tmp = File.createTempFile("mo_wav_", ".id3");
                FileOutputStream out = new FileOutputStream(tmp);
                try {
                    out.write(data);
                } finally {
                    close(out);
                }
                Tags fromId3 = Id3.read(tmp);
                if (fromId3.anyValue()) {
                    return fromId3;
                }
            } catch (Exception ignored) {
            } finally {
                if (tmp != null) {
                    //noinspection ResultOfMethodCallIgnored
                    tmp.delete();
                }
            }
        }
        if (info != null) {
            readInfo(file, info, tags);
        }
        return tags;
    }

    /**
     * 写标签：清掉旧 ID3 / INFO 块，在文件尾重新挂一个 ID3v2.3 块。
     *
     * @param cover null = 不写封面；长度 0 = 不写（WAV 里删封面等于不写 APIC）；否则写入
     */
    public static void rewrite(File file, Map<String, String> values, byte[] cover)
            throws IOException {
        if (!isWav(file)) {
            throw new IOException("不是有效的 WAV 文件");
        }
        byte[] tag = Id3.buildTag(values, cover == null || cover.length == 0 ? null : cover);
        List<Chunk> chunks = chunks(file);
        File tmp = new File(file.getParentFile(), file.getName() + ".mo_wav.tmp");
        RandomAccessFile in = null;
        RandomAccessFile out = null;
        try {
            in = new RandomAccessFile(file, "r");
            out = new RandomAccessFile(tmp, "rw");
            out.setLength(0);
            out.write(new byte[]{'R', 'I', 'F', 'F'});
            out.write(le32(0)); // 长度最后回填
            out.write(new byte[]{'W', 'A', 'V', 'E'});
            byte[] buf = new byte[65536];
            for (Chunk c : chunks) {
                // 旧标签一律丢掉：留着会和新的 ID3 打架（不同播放器显示不同值）
                if (c.isId3() || c.isInfoList()) {
                    continue;
                }
                long end = c.headerOffset + 8 + c.size + (c.size & 1);
                in.seek(c.headerOffset);
                long left = end - c.headerOffset; // 长度，不是结束位置（写成 end 会多拷 headerOffset 个字节）
                while (left > 0) {
                    int n = in.read(buf, 0, (int) Math.min(buf.length, left));
                    if (n <= 0) {
                        break;
                    }
                    out.write(buf, 0, n);
                    left -= n;
                }
            }
            out.write(new byte[]{'i', 'd', '3', ' '});
            out.write(le32(tag.length));
            out.write(tag);
            if ((tag.length & 1) == 1) {
                out.write(0); // chunk 对齐
            }
            long total = out.length();
            out.seek(4);
            out.write(le32(total - 8));
            out.seek(total);
        } finally {
            close(in);
            close(out);
        }
        // 覆盖回原文件（原文件是调用方给的可丢弃副本）
        FileInputStream src = null;
        FileOutputStream dst = null;
        try {
            src = new FileInputStream(tmp);
            dst = new FileOutputStream(file);
            byte[] buf = new byte[65536];
            int n;
            while ((n = src.read(buf)) > 0) {
                dst.write(buf, 0, n);
            }
            dst.getFD().sync();
        } finally {
            close(src);
            close(dst);
            //noinspection ResultOfMethodCallIgnored
            tmp.delete();
        }
    }

    // ------------------------------------------------------------------

    private static void readInfo(File file, Chunk list, Tags tags) {
        // LIST 的数据区以 "INFO" 开头，后面才是子块
        long end = list.dataOffset + list.size;
        long pos = list.dataOffset + 4;
        try {
            RandomAccessFile raf = new RandomAccessFile(file, "r");
            try {
                while (pos + 8 <= end) {
                    raf.seek(pos);
                    byte[] head = new byte[8];
                    raf.readFully(head);
                    String id = new String(head, 0, 4, "US-ASCII");
                    long size = u32(head, 4);
                    long dataPos = pos + 8;
                    if (size < 0 || dataPos + size > end) {
                        break;
                    }
                    String value = decodeText(readBytes(raf, dataPos, (int) size));
                    if (!value.isEmpty()) {
                        String key = infoKey(id);
                        if (key != null && tags.get(key).isEmpty()) {
                            tags.put(key, value);
                        }
                    }
                    pos = dataPos + size + (size & 1);
                }
            } finally {
                close(raf);
            }
        } catch (Exception ignored) {
        }
    }

    private static String infoKey(String id) {
        if ("INAM".equals(id)) {
            return "title";
        }
        if ("IART".equals(id)) {
            return "artist";
        }
        if ("IPRD".equals(id)) {
            return "album";
        }
        if ("ICRD".equals(id)) {
            return "year";
        }
        if ("IGNR".equals(id)) {
            return "genre";
        }
        if ("ITRK".equals(id) || "IPRT".equals(id)) {
            return "track";
        }
        if ("ICMT".equals(id)) {
            return "comment";
        }
        return null;
    }

    /** INFO 的字符串没有统一编码：先按 UTF-8，解出替换字符再退回 GBK。 */
    private static String decodeText(byte[] raw) {
        if (raw == null || raw.length == 0) {
            return "";
        }
        int len = raw.length;
        while (len > 0 && raw[len - 1] == 0) {
            len--;
        }
        if (len == 0) {
            return "";
        }
        // 统一走 TagText：INFO 块里的文本同样会遇到「UTF-8 / GBK 混写」，
        // 而且还有「GBK 被当 Latin-1 再存 UTF-8」的双重编码，自己一套判断迟早会不一致
        return TagText.decodeUtf8(java.util.Arrays.copyOfRange(raw, 0, len)).trim();
    }

    private static final class Chunk {
        String id;
        long headerOffset;
        long dataOffset;
        long size;

        boolean isId3() {
            return id.equalsIgnoreCase("id3 ");
        }

        boolean isInfoList() {
            return id.equals("LIST") && infoMarker;
        }

        boolean infoMarker;
    }

    private static List<Chunk> chunks(File file) {
        List<Chunk> out = new ArrayList<Chunk>();
        RandomAccessFile raf = null;
        try {
            long len = file.length();
            raf = new RandomAccessFile(file, "r");
            long pos = 12;
            while (pos + 8 <= len) {
                raf.seek(pos);
                byte[] head = new byte[8];
                raf.readFully(head);
                Chunk c = new Chunk();
                c.id = new String(head, 0, 4, "US-ASCII");
                c.size = u32(head, 4);
                c.headerOffset = pos;
                c.dataOffset = pos + 8;
                if (c.size < 0 || c.dataOffset + c.size > len) {
                    break; // 长度越界（文件被截断），到此为止
                }
                if ("LIST".equals(c.id) && c.size >= 4) {
                    byte[] marker = readBytes(raf, c.dataOffset, 4);
                    c.infoMarker = marker[0] == 'I' && marker[1] == 'N'
                            && marker[2] == 'F' && marker[3] == 'O';
                }
                out.add(c);
                pos = c.dataOffset + c.size + (c.size & 1);
            }
        } catch (Exception ignored) {
        } finally {
            close(raf);
        }
        return out;
    }

    private static byte[] readBytes(File file, long offset, int size) throws IOException {
        RandomAccessFile raf = new RandomAccessFile(file, "r");
        try {
            return readBytes(raf, offset, size);
        } finally {
            close(raf);
        }
    }

    private static byte[] readBytes(RandomAccessFile raf, long offset, int size)
            throws IOException {
        byte[] out = new byte[size];
        raf.seek(offset);
        raf.readFully(out);
        return out;
    }

    private static long u32(byte[] b, int off) {
        return ((long) (b[off] & 0xFF))
                | ((long) (b[off + 1] & 0xFF) << 8)
                | ((long) (b[off + 2] & 0xFF) << 16)
                | ((long) (b[off + 3] & 0xFF) << 24);
    }

    private static byte[] le32(long v) {
        return new byte[]{(byte) (v & 0xFF), (byte) ((v >> 8) & 0xFF),
                (byte) ((v >> 16) & 0xFF), (byte) ((v >> 24) & 0xFF)};
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
