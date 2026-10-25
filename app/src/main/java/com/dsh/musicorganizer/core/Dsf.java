package com.dsh.musicorganizer.core;

import java.io.File;
import java.io.IOException;
import java.io.RandomAccessFile;
import java.util.Map;

/**
 * DSF（DSD Stream File）标签读写（v0.1.100）。
 *
 * <p>布局：DSD chunk（28B：'DSD ' + size8 + totalSize8 + metadataPointer8）
 * → fmt chunk（52B，含 sampleCount / samplingFrequency，可算时长）
 * → data chunk（DSD 音频数据）→ metadata（**裸 ID3v2 块**，无 'ID3 ' 包装，
 * 位置由 DSD chunk 的 metadataPointer 绝对偏移指定）。
 *
 * <p>读写都复用 {@link Id3} 的 ID3v2 实现：读走 {@link Id3#readAt}，
 * 写用 {@link Id3#buildTag} 生成完整 tag 字节后重排文件。
 * DSD 音频数据不动，只重排头部三个 chunk 与尾部 metadata。
 */
public final class Dsf {

    private Dsf() {
    }

    public static boolean isDsf(File f) {
        RandomAccessFile raf = null;
        try {
            raf = new RandomAccessFile(f, "r");
            byte[] head = new byte[4];
            raf.readFully(head);
            return head[0] == 'D' && head[1] == 'S' && head[2] == 'D' && head[3] == ' ';
        } catch (Exception ignored) {
            return false;
        } finally {
            close(raf);
        }
    }

    /** 读标签。metadataPointer 为 0 或指向的位置没有 ID3v2（如只复制了头 2MB 的切片）时返回空。 */
    public static Tags read(File f) {
        Tags tags = new Tags();
        RandomAccessFile raf = null;
        try {
            raf = new RandomAccessFile(f, "r");
            long pointer = readPointer(raf);
            if (pointer <= 0 || pointer + 10 > f.length()) {
                return tags;
            }
            return Id3.readAt(f, pointer);
        } catch (Exception ignored) {
            return new Tags();
        } finally {
            close(raf);
        }
    }

    /** 时长（秒）：sampleCount / samplingFrequency。读不出返回 0。 */
    public static double durationSeconds(File f) {
        RandomAccessFile raf = null;
        try {
            raf = new RandomAccessFile(f, "r");
            byte[] head = new byte[80];
            raf.readFully(head);
            if (!(head[0] == 'D' && head[1] == 'S' && head[2] == 'D' && head[3] == ' ')) {
                return 0;
            }
            // fmt chunk 从偏移 28 开始：'fmt '(4) + size8 → 数据从 40 起
            if (!(head[28] == 'f' && head[29] == 'm' && head[30] == 't' && head[31] == ' ')) {
                return 0;
            }
            // fmt 数据：ver4 formatID4 chanType4 chanNum4 freq4 bits4 sampleCount8 ...
            long sampleCount = le64(head, 40 + 24);
            long freq = le32(head, 40 + 16);
            if (sampleCount <= 0 || freq <= 0) {
                return 0;
            }
            return (double) sampleCount / (double) freq;
        } catch (Exception ignored) {
            return 0;
        } finally {
            close(raf);
        }
    }

    /**
     * 重写标签（调用方保证 file 是可丢弃的副本）。音频数据原样保留。
     *
     * @param cover null = 不动封面；长度 0 = 删除封面；否则写入这张图
     */
    public static void rewrite(File file, Map<String, String> values, byte[] cover)
            throws IOException {
        RandomAccessFile raf = null;
        long dataSize;
        byte[] fmtChunk;
        try {
            raf = new RandomAccessFile(file, "r");
            byte[] dsd = new byte[28];
            raf.readFully(dsd);
            if (!(dsd[0] == 'D' && dsd[1] == 'S' && dsd[2] == 'D' && dsd[3] == ' ')) {
                throw new IOException("文件不是有效的 DSF");
            }
            byte[] fmtHead = new byte[12];
            raf.readFully(fmtHead);
            if (!(fmtHead[0] == 'f' && fmtHead[1] == 'm' && fmtHead[2] == 't' && fmtHead[3] == ' ')) {
                throw new IOException("DSF fmt chunk 缺失");
            }
            long fmtSize = le64(fmtHead, 4);
            if (fmtSize < 52) {
                throw new IOException("DSF fmt chunk 大小异常");
            }
            fmtChunk = new byte[(int) fmtSize];
            System.arraycopy(fmtHead, 0, fmtChunk, 0, 12);
            raf.readFully(fmtChunk, 12, (int) (fmtSize - 12));
            byte[] dataHead = new byte[12];
            raf.readFully(dataHead);
            if (!(dataHead[0] == 'd' && dataHead[1] == 'a' && dataHead[2] == 't'
                    && dataHead[3] == 'a')) {
                throw new IOException("DSF data chunk 缺失");
            }
            dataSize = le64(dataHead, 4) - 12;
            if (dataSize < 0) {
                throw new IOException("DSF data chunk 大小异常");
            }
        } finally {
            close(raf);
        }

        byte[] newTag = Id3.buildTag(values, cover);
        File out = new File(file.getParentFile(), file.getName() + ".__dsf__");
        java.io.InputStream in = null;
        java.io.OutputStream os = null;
        try {
            // 头部（DSD + fmt + data 头）→ 音频数据 → 新 metadata
            long metadataOffset = 28 + fmtChunk.length + 12 + dataSize;
            long total = metadataOffset + newTag.length;
            in = new java.io.FileInputStream(file);
            // 跳过旧头部：DSD chunk(28) + fmt chunk + data chunk 头(12)，
            // 从音频数据第一字节开始复制（少跳 12 字节会把 'data'+size 当音频搬走）
            in.skip(28 + fmtChunk.length + 12);
            os = new java.io.FileOutputStream(out);
            byte[] dsdHead = new byte[28];
            dsdHead[0] = 'D';
            dsdHead[1] = 'S';
            dsdHead[2] = 'D';
            dsdHead[3] = ' ';
            writeLe64(dsdHead, 4, 28);
            writeLe64(dsdHead, 12, total);
            writeLe64(dsdHead, 20, metadataOffset);
            os.write(dsdHead);
            os.write(fmtChunk);
            byte[] dataHead = new byte[12];
            dataHead[0] = 'd';
            dataHead[1] = 'a';
            dataHead[2] = 't';
            dataHead[3] = 'a';
            writeLe64(dataHead, 4, 12 + dataSize);
            os.write(dataHead);
            byte[] buf = new byte[1 << 20];
            long remaining = dataSize;
            while (remaining > 0) {
                int n = in.read(buf, 0, (int) Math.min(buf.length, remaining));
                if (n < 0) {
                    throw new IOException("DSF 音频数据不完整");
                }
                os.write(buf, 0, n);
                remaining -= n;
            }
            os.write(newTag);
            os.flush();
        } finally {
            if (in != null) {
                try {
                    in.close();
                } catch (Exception ignored) {
                }
            }
            if (os != null) {
                try {
                    os.close();
                } catch (Exception ignored) {
                }
            }
        }
        try {
            // renameTo 不覆盖已存在目标，必须用 Files.move(REPLACE_EXISTING)
            java.nio.file.Files.move(out.toPath(), file.toPath(),
                    java.nio.file.StandardCopyOption.REPLACE_EXISTING);
        } catch (IOException e) {
            if (!out.delete() && out.exists()) {
                throw new IOException("临时 DSF 文件删除失败");
            }
            throw new IOException("DSF 临时文件替换失败：" + TextUtil.shortError(e));
        }
    }

    /** 有没有内嵌封面：metadata 里有 APIC 帧。 */
    public static boolean hasCover(File f) {
        RandomAccessFile raf = null;
        try {
            raf = new RandomAccessFile(f, "r");
            long pointer = readPointer(raf);
            if (pointer <= 0 || pointer + 10 > f.length()) {
                return false;
            }
            long len = f.length();
            byte[] head = new byte[10];
            raf.seek(pointer);
            raf.readFully(head);
            if (!(head[0] == 'I' && head[1] == 'D' && head[2] == '3')) {
                return false;
            }
            long size = syncsafe(head, 6);
            long tagEnd = Math.min(pointer + 10 + size, len);
            long pos = pointer + 10;
            while (pos + 10 <= tagEnd) {
                raf.seek(pos);
                byte[] h = new byte[10];
                raf.readFully(h);
                if (h[0] == 0) {
                    break;
                }
                if (h[0] == 'A' && h[1] == 'P' && h[2] == 'I' && h[3] == 'C') {
                    return true;
                }
                long frameSize = syncsafe(h, 4);
                if (frameSize <= 0 || pos + 10 + frameSize > tagEnd) {
                    break;
                }
                pos += 10 + frameSize;
            }
            return false;
        } catch (Exception ignored) {
            return false;
        } finally {
            close(raf);
        }
    }

    // ------------------------------------------------------------------

    private static long readPointer(RandomAccessFile raf) throws IOException {
        byte[] head = new byte[28];
        raf.seek(0);
        raf.readFully(head);
        if (!(head[0] == 'D' && head[1] == 'S' && head[2] == 'D' && head[3] == ' ')) {
            return -1;
        }
        return le64(head, 20);
    }

    private static long le64(byte[] b, int off) {
        return ((long) (b[off] & 0xFF)) | ((long) (b[off + 1] & 0xFF) << 8)
                | ((long) (b[off + 2] & 0xFF) << 16) | ((long) (b[off + 3] & 0xFF) << 24)
                | ((long) (b[off + 4] & 0xFF) << 32) | ((long) (b[off + 5] & 0xFF) << 40)
                | ((long) (b[off + 6] & 0xFF) << 48) | ((long) (b[off + 7] & 0xFF) << 56);
    }

    private static long le32(byte[] b, int off) {
        return ((long) (b[off] & 0xFF)) | ((long) (b[off + 1] & 0xFF) << 8)
                | ((long) (b[off + 2] & 0xFF) << 16) | ((long) (b[off + 3] & 0xFF) << 24);
    }

    private static void writeLe64(byte[] b, int off, long value) {
        for (int i = 0; i < 8; i++) {
            b[off + i] = (byte) ((value >>> (i * 8)) & 0xFF);
        }
    }

    private static long syncsafe(byte[] b, int off) {
        return ((long) (b[off] & 0x7F) << 21) | ((long) (b[off + 1] & 0x7F) << 14)
                | ((long) (b[off + 2] & 0x7F) << 7) | (b[off + 3] & 0x7F);
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
