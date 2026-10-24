package com.dsh.musicorganizer.core;

import java.io.File;
import java.io.IOException;
import java.io.RandomAccessFile;
import java.util.HashMap;
import java.util.Map;

/**
 * 标签读写调度（对应 Python 版 read_tags / write_tags 的事务外壳）。
 *
 * 事务流程与 Python 版一致：
 *   读取 before 快照 → 复制到本地缓存副本 → 在副本上写 → 读回校验
 *   → 校验通过后写回 SAF 原文件 → 任意一步失败则原文件不动。
 */
public final class TagIO {

    private TagIO() {
    }

    /** 需要写入的字段名集合（值为空字符串表示清除该字段）。 */
    public static Map<String, String> writableCopy(Map<String, String> values) {
        Map<String, String> out = new HashMap<String, String>();
        for (String k : Tags.KEYS) {
            if (k.equals("comment")) {
                continue;
            }
            String v = values.get(k);
            if (v != null) {
                out.put(k, v.trim());
            }
        }
        return out;
    }

    /**
     * 头部副本里是否已包含完整标签 —— 用来判断「只读文件头」是否够用。
     *
     * <p>MP3 看 ID3 头声明的标签长度是否落在副本内；FLAC 看 Vorbis Comment 块
     * 是否在副本内结束（或元数据块链在前部就已结束）。M4A/MP4 的 moov 可能在文件尾，
     * 一律返回 false，让调用方回退到整文件复制。
     */
    public static boolean tagFitsCopy(File copy, String ext) {
        String e = (ext == null || ext.isEmpty()) ? extOf(copy.getName())
                : ext.toLowerCase(java.util.Locale.US);
        if (!(e.equals(".mp3") || e.equals(".flac"))) {
            return false;
        }
        long len = copy.length();
        RandomAccessFile raf = null;
        try {
            raf = new RandomAccessFile(copy, "r");
            if (e.equals(".mp3")) {
                if (len < 10) {
                    return true;
                }
                byte[] head = new byte[10];
                raf.readFully(head);
                if (head[0] != 'I' || head[1] != 'D' || head[2] != '3') {
                    return true; // 没有 ID3 标签，头部已够
                }
                long size = syncsafe(head, 6);
                long tagEnd = 10 + size + ((head[5] & 0x10) != 0 ? 10 : 0);
                return tagEnd <= len;
            }
            // FLAC：遍历元数据块，看 Vorbis Comment 是否完整落在副本里
            byte[] magic = new byte[4];
            if (len < 4) {
                return true;
            }
            raf.readFully(magic);
            if (!(magic[0] == 'f' && magic[1] == 'L' && magic[2] == 'a' && magic[3] == 'C')) {
                return true;
            }
            long pos = 4;
            while (pos + 4 <= len) {
                raf.seek(pos);
                int b = raf.read();
                if (b < 0) {
                    return true;
                }
                boolean last = (b & 0x80) != 0;
                int type = b & 0x7F;
                int b0 = raf.read();
                int b1 = raf.read();
                int b2 = raf.read();
                if (b1 < 0 || b2 < 0) {
                    return true;
                }
                long blockLen = (b0 & 0xFF) << 16 | (b1 & 0xFF) << 8 | (b2 & 0xFF);
                long end = pos + 4 + blockLen;
                if (type == 4) { // VORBIS_COMMENT
                    return end <= len;
                }
                if (last) {
                    return true; // 没有 Vorbis Comment，元数据区已读完
                }
                pos = end;
            }
            return false;
        } catch (Exception ex) {
            return false;
        } finally {
            if (raf != null) {
                try {
                    raf.close();
                } catch (Exception ignored) {
                }
            }
        }
    }

    private static long syncsafe(byte[] b, int off) {
        return ((long) (b[off] & 0x7F) << 21)
                | ((long) (b[off + 1] & 0x7F) << 14)
                | ((long) (b[off + 2] & 0x7F) << 7)
                | (b[off + 3] & 0x7F);
    }

    /** 本地文件标签读取（自动分发格式）。 */
    public static Tags readLocal(File file) {
        Tags tags = new Tags();
        String ext = extOf(file.getName());
        try {
            if (ext.equals(".mp3")) {
                tags = Id3.read(file);
            } else if (ext.equals(".flac")) {
                tags = Flac.isFlac(file) ? Flac.read(file) : new Tags();
            } else if (ext.equals(".m4a") || ext.equals(".mp4")) {
                tags = Mp4.isMp4(file) ? Mp4.read(file) : new Tags();
            } else if (ext.equals(".wav")) {
                tags = Wav.read(file);
            } else if (ext.equals(".ogg") || ext.equals(".opus")) {
                tags = Ogg.read(file);
            } else if (ext.equals(".ape")) {
                tags = Ape.read(file);
            } else if (ext.equals(".wma")) {
                // WMA 只读：ASF 头层层嵌套长度，改标签要重排整段头部，写坏整个文件的风险太高
                tags = Wma.read(file);
            }
        } catch (Exception ignored) {
            tags = new Tags();
        }
        if (tags.get("year").length() > 4) {
            tags.put("year", tags.get("year").substring(0, 4));
        }
        return tags;
    }

    /**
     * 本地文件标签写入（直接改写 file，调用方保证 file 是可丢弃的副本）。
     * 返回 "" 表示成功，否则为错误信息。
     */
    public static String writeLocal(File file, Map<String, String> values) {
        return writeLocal(file, values, null);
    }

    /**
     * 写入字段 + 封面。
     *
     * @param cover null = 不动封面；长度为 0 = 删除封面；否则替换为这张图
     */
    public static String writeLocal(File file, Map<String, String> values, byte[] cover) {
        String ext = extOf(file.getName());
        try {
            if (ext.equals(".mp3")) {
                Id3.rewrite(file, values, cover);
            } else if (ext.equals(".flac")) {
                if (!Flac.isFlac(file)) {
                    return "文件不是有效的 FLAC";
                }
                Flac.rewrite(file, values, cover);
            } else if (ext.equals(".m4a") || ext.equals(".mp4")) {
                if (!Mp4.isMp4(file)) {
                    return "文件不是有效的 M4A/MP4";
                }
                Mp4.write(file, values, cover);
            } else if (ext.equals(".wav")) {
                if (!Wav.isWav(file)) {
                    return "文件不是有效的 WAV";
                }
                Wav.rewrite(file, values, cover);
            } else if (ext.equals(".ogg") || ext.equals(".opus")) {
                if (!Ogg.isOgg(file)) {
                    return "文件不是有效的 OGG/Opus";
                }
                Ogg.rewrite(file, values, cover);
            } else if (ext.equals(".ape") || ext.equals(".wv") || ext.equals(".mpc")) {
                if (!Ape.isApe(file)) {
                    return "文件不是有效的 APE / WavPack / Musepack";
                }
                Ape.rewrite(file, values, cover);
            } else if (ext.equals(".aac")) {
                return "纯 ADTS AAC 不支持 ID3 标签，建议先转码为 M4A 或 MP3 再写入";
            } else if (ext.equals(".wma")) {
                return "WMA 标签写入支持有限，建议转码为 FLAC 或 MP3";
            } else {
                return "该格式不支持写标签：" + ext;
            }
        } catch (IOException e) {
            return TextUtil.shortError(e);
        } catch (Exception e) {
            return TextUtil.shortError(e);
        }
        return "";
    }

    public static boolean canWrite(String ext) {
        return ext.equals(".mp3") || ext.equals(".flac")
                || ext.equals(".m4a") || ext.equals(".mp4")
                || ext.equals(".wav")
                || ext.equals(".ogg") || ext.equals(".opus")
                || ext.equals(".ape") || ext.equals(".wv") || ext.equals(".mpc");
    }

    /** 这个文件里有没有内嵌封面（MP3 APIC / FLAC PICTURE / MP4 covr）。 */
    public static boolean hasCoverLocal(File file) {
        String ext = extOf(file.getName());
        try {
            if (ext.equals(".mp3")) {
                return Id3.hasCover(file);
            }
            if (ext.equals(".flac")) {
                return Flac.isFlac(file) && Flac.hasPicture(file);
            }
            if (ext.equals(".m4a") || ext.equals(".mp4")) {
                return Mp4.isMp4(file) && Mp4.hasCover(file);
            }
            if (ext.equals(".ogg") || ext.equals(".opus")) {
                return Ogg.hasCover(file);
            }
            if (ext.equals(".ape")) {
                return Ape.hasCover(file);
            }
        } catch (Exception ignored) {
        }
        return false;
    }

    public static String extOf(String name) {
        int dot = name.lastIndexOf('.');
        if (dot < 0) {
            return "";
        }
        return name.substring(dot).toLowerCase();
    }
}
