package com.dsh.musicorganizer.core;

import java.io.ByteArrayOutputStream;
import java.io.EOFException;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.RandomAccessFile;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.Charset;
import java.nio.charset.CharsetDecoder;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * ID3v2.3 / v2.4 标签读写（纯手写，零依赖）。
 *
 * 读取：解析文本帧 TIT2/TPE1/TPE2/TALB/TYER/TDRC/TRCK/TCON/COMM/USLT。
 * 写入：保留不认识的帧（含封面 APIC），重写目标字段后生成新标签头部，
 *       音频数据保持不动 —— 与 Python 版事务层的「副本写入」一致，
 *       调用方（TagIO）负责先复制到本地缓存文件再改写。
 */
public final class Id3 {

    private Id3() {
    }

    private static final Map<String, String> READ_FIELDS = new HashMap<String, String>();

    static {
        READ_FIELDS.put("TIT2", "title");
        READ_FIELDS.put("TPE1", "artist");
        READ_FIELDS.put("TPE2", "artist");
        READ_FIELDS.put("TALB", "album");
        READ_FIELDS.put("TYER", "year");
        READ_FIELDS.put("TDRC", "year");
        READ_FIELDS.put("TRCK", "track");
        READ_FIELDS.put("TCON", "genre");
        READ_FIELDS.put("COMM", "comment");
        READ_FIELDS.put("USLT", "lyrics");
    }

    /**
     * 字段 → 帧 ID 的映射（写入用）。
     * 注意：写入采用「合并语义」——只有在 values 里出现的字段才会被替换/清除，
     * 未出现的字段其原帧会原样保留。因此更新/撤销/歌词嵌入这类只传部分字段的
     * 调用不会误伤其它标签。
     */
    private static final Map<String, String[]> FIELD_FRAMES = new HashMap<String, String[]>();

    static {
        FIELD_FRAMES.put("title", new String[]{"TIT2"});
        FIELD_FRAMES.put("artist", new String[]{"TPE1"});
        FIELD_FRAMES.put("album", new String[]{"TALB"});
        // v2.3 用 TYER，v2.4 用 TDRC；两个都清掉，避免读到旧年份
        FIELD_FRAMES.put("year", new String[]{"TYER", "TDRC"});
        FIELD_FRAMES.put("track", new String[]{"TRCK"});
        FIELD_FRAMES.put("genre", new String[]{"TCON"});
        FIELD_FRAMES.put("comment", new String[]{"COMM"});
        FIELD_FRAMES.put("lyrics", new String[]{"USLT"});
    }

    // ------------------------------------------------------------------
    // 读取
    // ------------------------------------------------------------------

    public static Tags read(File file) {
        Tags tags = new Tags();
        RandomAccessFile raf = null;
        try {
            raf = new RandomAccessFile(file, "r");
            byte[] head = new byte[10];
            raf.readFully(head);
            if (head[0] != 'I' || head[1] != 'D' || head[2] != '3') {
                return tags;
            }
            int version = head[3] & 0xFF;
            int flags = head[5] & 0xFF;
            long size = syncsafe(head, 6);
            long tagEnd = 10 + size + ((flags & 0x10) != 0 ? 10 : 0);
            long pos = 10;
            if ((flags & 0x40) != 0) { // extended header
                byte[] sizeBuf = new byte[4];
                raf.readFully(sizeBuf);
                long extSize = (version >= 4) ? syncsafe(sizeBuf, 0) : be32(sizeBuf, 0);
                pos = 10 + 4 + extSize;
                raf.seek(pos);
            }
            if ((flags & 0x80) != 0) {
                // 全局反同步（v2.3 常见）：读出整段再还原
                return readWithUnsynchronization(raf, pos, tagEnd, version);
            }
            while (pos + 10 <= tagEnd) {
                raf.seek(pos);
                byte[] header = new byte[10];
                try {
                    raf.readFully(header);
                } catch (EOFException e) {
                    break;
                }
                if (header[0] == 0) {
                    break;
                }
                String id = ascii(header, 0, 4);
                long frameSize = (version >= 4) ? syncsafe(header, 4) : be32(header, 4);
                if (frameSize <= 0 || pos + 10 + frameSize > tagEnd) {
                    // 兼容个别按普通 BE 写 v2.4 的编码器
                    if (version >= 4) {
                        long alt = be32(header, 4);
                        if (alt > 0 && pos + 10 + alt <= tagEnd) {
                            frameSize = alt;
                        } else {
                            break;
                        }
                    } else {
                        break;
                    }
                }
                byte[] data = new byte[(int) frameSize];
                raf.readFully(data);
                applyFrame(tags, id, data);
                pos += 10 + frameSize;
            }
        } catch (Exception ignored) {
        } finally {
            close(raf);
        }
        return tags;
    }

    private static Tags readWithUnsynchronization(RandomAccessFile raf, long pos,
                                                  long tagEnd, int version) throws IOException {
        Tags tags = new Tags();
        byte[] whole = new byte[(int) (tagEnd - pos)];
        raf.seek(pos);
        raf.readFully(whole);
        ByteArrayOutputStream out = new ByteArrayOutputStream(whole.length);
        for (int i = 0; i < whole.length; i++) {
            out.write(whole[i]);
            if ((whole[i] & 0xFF) == 0xFF && i + 1 < whole.length && whole[i + 1] == 0) {
                i++;
            }
        }
        byte[] data = out.toByteArray();
        int p = 0;
        while (p + 10 <= data.length) {
            if (data[p] == 0) {
                break;
            }
            String id = ascii(data, p, 4);
            long frameSize = (version >= 4) ? syncsafe(data, p + 4) : be32(data, p + 4);
            if (frameSize <= 0 || p + 10 + frameSize > data.length) {
                break;
            }
            byte[] frame = new byte[(int) frameSize];
            System.arraycopy(data, p + 10, frame, 0, (int) frameSize);
            applyFrame(tags, id, frame);
            p += 10 + (int) frameSize;
        }
        return tags;
    }

    private static void applyFrame(Tags tags, String id, byte[] data) {
        // SYLT 是「同步歌词」帧（带时间戳），播放器能显示、但 USLT 为空时旧实现读不到，
        // 于是「播放器有歌词、本应用说没有」。这里转成 LRC 文本补进 lyrics 字段。
        if ("SYLT".equals(id)) {
            if (tags.get("lyrics").isEmpty()) {
                String sylt = decodeSylt(data);
                if (!sylt.isEmpty()) {
                    tags.put("lyrics", sylt);
                }
            }
            return;
        }
        // 有些写词工具把歌词塞进 TXXX（描述里带 LYRICS），USLT 是空的 —— 播放器能读，
        // 旧实现读不到。这里补一条：描述含 LYRIC 就当成歌词正文。
        if ("TXXX".equals(id)) {
            if (tags.get("lyrics").isEmpty() && data.length > 1) {
                int enc = data[0] & 0xFF;
                int[] pos = new int[]{1};
                String desc = readTerminated(data, pos, enc);
                if (desc != null && desc.toUpperCase(java.util.Locale.ROOT).contains("LYRIC")) {
                    int start = Math.min(pos[0], data.length);
                    byte[] payload = new byte[data.length - start];
                    System.arraycopy(data, start, payload, 0, payload.length);
                    String value = stripNul(decodePayload(payload, enc)).trim();
                    if (!value.isEmpty()) {
                        tags.put("lyrics", value);
                    }
                }
            }
            return;
        }
        String field = READ_FIELDS.get(id);
        if (field == null) {
            return;
        }
        if (id.equals("COMM") || id.equals("USLT")) {
            tags.put(field, decodeComm(data));
        } else if (id.equals("TPE2")) {
            if (tags.get("artist").isEmpty()) {
                tags.put("artist", decodeText(data));
            }
        } else {
            String v = decodeText(data);
            if (!v.isEmpty()) {
                tags.put(field, v);
            }
        }
    }

    /**
     * 解析 SYLT（同步歌词）：enc(1) + lang(3) + timeFormat(1) + contentType(1) + 描述 + 重复的
     * 「文本 + 4 字节毫秒时间戳」。转成 `[mm:ss.xx]文本` 的 LRC 形式，和其它来源保持同一种表示。
     */
    static String decodeSylt(byte[] data) {
        if (data == null || data.length < 6) {
            return "";
        }
        int enc = data[0] & 0xFF;
        int[] pos = new int[]{6};
        readTerminated(data, pos, enc);          // 描述字段，丢弃
        int p = pos[0];
        StringBuilder out = new StringBuilder();
        while (p + 4 <= data.length) {
            pos[0] = p;
            String text = readTerminated(data, pos, enc);
            p = pos[0];
            if (p + 4 > data.length) {
                break;
            }
            long ms = ((long) (data[p] & 0xFF) << 24) | ((long) (data[p + 1] & 0xFF) << 16)
                    | ((long) (data[p + 2] & 0xFF) << 8) | (data[p + 3] & 0xFF);
            p += 4;
            if (text == null || text.trim().isEmpty()) {
                continue;
            }
            long totalSeconds = ms / 1000;
            if (out.length() > 0) {
                out.append('\n');
            }
            out.append(String.format(java.util.Locale.US, "[%02d:%02d.%02d]%s",
                    totalSeconds / 60, totalSeconds % 60, (ms % 1000) / 10, text.trim()));
        }
        return out.toString();
    }

    /** 按编码读一个以 NUL 结尾的字符串，pos[0] 前进到结尾之后。 */
    private static String readTerminated(byte[] data, int[] pos, int enc) {
        int start = pos[0];
        int p = start;
        if (enc == 1 || enc == 2) {
            while (p + 1 < data.length) {
                if (data[p] == 0 && data[p + 1] == 0) {
                    break;
                }
                p += 2;
            }
            int end = Math.min(p, data.length);
            byte[] payload = new byte[Math.max(0, end - start)];
            System.arraycopy(data, start, payload, 0, payload.length);
            pos[0] = Math.min(data.length, end + 2);
            return stripNul(decodePayload(payload, enc));
        }
        while (p < data.length && data[p] != 0) {
            p++;
        }
        byte[] payload = new byte[Math.max(0, p - start)];
        System.arraycopy(data, start, payload, 0, payload.length);
        pos[0] = Math.min(data.length, p + 1);
        return stripNul(decodePayload(payload, enc));
    }

    static String decodeText(byte[] data) {
        if (data == null || data.length < 1) {
            return "";
        }
        int enc = data[0] & 0xFF;
        byte[] payload = new byte[data.length - 1];
        System.arraycopy(data, 1, payload, 0, payload.length);
        return stripNul(decodePayload(payload, enc)).trim();
    }

    private static String decodeComm(byte[] data) {
        if (data == null || data.length < 4) {
            return "";
        }
        int enc = data[0] & 0xFF;
        int p = 4; // 1(enc) + 3(lang)
        // 找描述字段结束位置（按编码对齐的 null）
        while (p < data.length) {
            if (enc == 1 || enc == 2) {
                if (p + 1 < data.length && data[p] == 0 && data[p + 1] == 0) {
                    p += 2;
                    break;
                }
                p += 2;
            } else {
                if (data[p] == 0) {
                    p += 1;
                    break;
                }
                p += 1;
            }
        }
        if (p >= data.length) {
            return "";
        }
        byte[] payload = new byte[data.length - p];
        System.arraycopy(data, p, payload, 0, payload.length);
        return stripNul(decodePayload(payload, enc)).trim();
    }

    private static String decodePayload(byte[] payload, int enc) {
        try {
            switch (enc) {
                case 0:
                    return decodeLatin1OrGbk(payload);
                case 1: {
                    if (payload.length >= 2 && payload[0] == (byte) 0xFE && payload[1] == (byte) 0xFF) {
                        return new String(payload, 2, payload.length - 2, "UTF-16BE");
                    }
                    if (payload.length >= 2 && payload[0] == (byte) 0xFF && payload[1] == (byte) 0xFE) {
                        return new String(payload, 2, payload.length - 2, "UTF-16LE");
                    }
                    return new String(payload, "UTF-16LE");
                }
                case 2:
                    return new String(payload, "UTF-16BE");
                case 3:
                    return TagText.decodeUtf8(payload);
                default:
                    return decodeLatin1OrGbk(payload);
            }
        } catch (Exception e) {
            return "";
        }
    }

    /**
     * {@code encoding=0}（ISO-8859-1）文本帧的解码。
     *
     * <p>实现全在 {@link TagText}（ID3 / Vorbis Comment / MP4 atom 共用一套容错：
     * GBK 冒充 UTF-8、双重编码、真 UTF-8 标成 Latin-1 都要兜住）。这里保留同名方法，
     * 因为 {@code tools/TagHeadTest} 直接按 Id3 的入口测。
     */
    public static String decodeLatin1OrGbk(byte[] payload) {
        return TagText.decodeLatin1OrGbk(payload);
    }

    /** NUL 截断：ID3 文本帧用 NUL 表示结束（v2.4 也用 NUL 分隔多值）。 */
    private static String stripNul(String s) {
        return TagText.stripNul(s);
    }

    // ------------------------------------------------------------------
    // 写入
    // ------------------------------------------------------------------

    /**
     * 只构造 ID3v2.3 标签字节（头 + 帧 + 512 字节填充），不碰任何音频数据。
     *
     * <p>WAV 没有原生标签区，业界做法是在文件尾挂一个 {@code id3 } 块，
     * 内容就是一段标准 ID3v2 标签 —— 这里复用的就是 MP3 那套帧编码。
     */
    public static byte[] buildTag(Map<String, String> values, byte[] cover) throws IOException {
        byte[] frameBytes = buildFrames(3, values, cover, new ArrayList<byte[]>());
        int pad = 512;
        long tagSize = frameBytes.length + pad;
        byte[] head = new byte[10];
        head[0] = 'I';
        head[1] = 'D';
        head[2] = '3';
        head[3] = 3;
        head[4] = 0;
        head[5] = 0;
        writeSyncsafe(head, 6, tagSize);
        ByteArrayOutputStream out = new ByteArrayOutputStream(10 + (int) tagSize);
        out.write(head);
        out.write(frameBytes);
        out.write(new byte[pad]);
        return out.toByteArray();
    }

    public static void rewrite(File file, Map<String, String> values) throws IOException {
        rewrite(file, values, null);
    }

    /**
     * 写入字段；{@code cover} 为 null 表示不动封面（保留原 APIC），
     * 长度为 0 表示删除封面，否则替换为这张图。
     */
    /**
     * 组装 ID3 帧数据（不含 10 字节标签头）。
     *
     * <p>{@code preserved} 是「不替换」的旧帧原样字节；WAV / AIFF 这类把 ID3 当
     * 附属块挂在别的容器里的格式没有旧帧可保留，传空表即可。
     */
    private static byte[] buildFrames(int version, Map<String, String> values,
                                      byte[] cover, List<byte[]> preserved)
            throws IOException {
        // 组装新帧：只有 values 里出现的字段才写出（空字符串 = 清除该字段）
        ByteArrayOutputStream frames = new ByteArrayOutputStream(4096);
        String yearId = (version >= 4) ? "TDRC" : "TYER";
        if (values.containsKey("title")) {
            putTextFrame(frames, version, "TIT2", orEmpty(values.get("title")));
        }
        if (values.containsKey("artist")) {
            putTextFrame(frames, version, "TPE1", orEmpty(values.get("artist")));
        }
        if (values.containsKey("album")) {
            putTextFrame(frames, version, "TALB", orEmpty(values.get("album")));
        }
        if (values.containsKey("year")) {
            putTextFrame(frames, version, yearId, orEmpty(values.get("year")));
        }
        if (values.containsKey("track")) {
            putTextFrame(frames, version, "TRCK", orEmpty(values.get("track")));
        }
        if (values.containsKey("genre")) {
            putTextFrame(frames, version, "TCON", orEmpty(values.get("genre")));
        }
        if (values.containsKey("comment")) {
            putCommFrame(frames, version, orEmpty(values.get("comment")));
        }
        if (values.containsKey("lyrics")) {
            putUsltFrame(frames, version, orEmpty(values.get("lyrics")));
        }
        if (cover != null && cover.length > 0) {
            putApicFrame(frames, version, cover);
        }
        for (byte[] raw : preserved) {
            frames.write(raw);
        }
        return frames.toByteArray();
    }

    public static void rewrite(File file, Map<String, String> values, byte[] cover)
            throws IOException {
        int version = 3;
        long audioStart = 0;
        List<byte[]> preserved = new ArrayList<byte[]>();
        RandomAccessFile raf = null;
        // 只替换 values 里出现过的字段对应的帧；其余帧原样保留（合并语义，避免误清标签）
        java.util.Set<String> replaceIds = new java.util.HashSet<String>();
        for (String key : values.keySet()) {
            String[] ids = FIELD_FRAMES.get(key);
            if (ids != null) {
                for (String id : ids) {
                    replaceIds.add(id);
                }
            }
        }
        if (cover != null) {
            replaceIds.add("APIC"); // 要写 / 要清封面，都得先把旧的全部剪掉
        }
        try {
            raf = new RandomAccessFile(file, "r");
            byte[] head = new byte[10];
            raf.readFully(head);
            if (head[0] == 'I' && head[1] == 'D' && head[2] == '3') {
                version = head[3] & 0xFF;
                if (version < 3 || version > 4) {
                    version = 3;
                }
                int flags = head[5] & 0xFF;
                long size = syncsafe(head, 6);
                long tagEnd = 10 + size + ((flags & 0x10) != 0 ? 10 : 0);
                audioStart = tagEnd;
                long pos = 10;
                if ((flags & 0x40) != 0) {
                    byte[] sizeBuf = new byte[4];
                    raf.readFully(sizeBuf);
                    long extSize = (version >= 4) ? syncsafe(sizeBuf, 0) : be32(sizeBuf, 0);
                    pos = 10 + 4 + extSize;
                }
                while (pos + 10 <= tagEnd) {
                    raf.seek(pos);
                    byte[] header = new byte[10];
                    raf.readFully(header);
                    if (header[0] == 0) {
                        break;
                    }
                    String id = ascii(header, 0, 4);
                    long frameSize = (version >= 4) ? syncsafe(header, 4) : be32(header, 4);
                    if (frameSize <= 0 || pos + 10 + frameSize > tagEnd) {
                        if (version >= 4) {
                            long alt = be32(header, 4);
                            if (alt > 0 && pos + 10 + alt <= tagEnd) {
                                frameSize = alt;
                            } else {
                                break;
                            }
                        } else {
                            break;
                        }
                    }
                    if (!replaceIds.contains(id)) {
                        byte[] frame = new byte[10 + (int) frameSize];
                        System.arraycopy(header, 0, frame, 0, 10);
                        byte[] data = new byte[(int) frameSize];
                        raf.seek(pos + 10);
                        raf.readFully(data);
                        System.arraycopy(data, 0, frame, 10, (int) frameSize);
                        preserved.add(frame);
                    }
                    pos += 10 + frameSize;
                }
            }
        } finally {
            close(raf);
        }

        byte[] frameBytes = buildFrames(version, values, cover, preserved);

        File tmp = new File(file.getParentFile(), file.getName() + ".mo_id3.tmp");
        RandomAccessFile out = null;
        try {
            out = new RandomAccessFile(tmp, "rw");
            out.setLength(0);
            int pad = 512;
            long tagSize = frameBytes.length + pad;
            byte[] head = new byte[10];
            head[0] = 'I';
            head[1] = 'D';
            head[2] = '3';
            head[3] = (byte) version;
            head[4] = 0;
            head[5] = 0;
            writeSyncsafe(head, 6, tagSize);
            out.write(head);
            out.write(frameBytes);
            out.write(new byte[pad]);
            // 复制音频数据
            if (audioStart > 0) {
                FileInputStream in = null;
                try {
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
                    close(in);
                }
            } else {
                FileInputStream in = null;
                try {
                    in = new FileInputStream(file);
                    byte[] buf = new byte[65536];
                    int n;
                    while ((n = in.read(buf)) > 0) {
                        out.write(buf, 0, n);
                    }
                } finally {
                    close(in);
                }
            }
        } finally {
            close(out);
        }
        if (!tmp.renameTo(file)) {
            // 某些平台 renameTo 不覆盖已存在文件
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

    private static String orEmpty(String s) {
        return s == null ? "" : s.trim();
    }

    private static void putTextFrame(ByteArrayOutputStream out, int version,
                                     String id, String value) {
        try {
            byte[] text;
            byte enc;
            if (version >= 4) {
                enc = 3;
                text = value.getBytes("UTF-8");
            } else {
                enc = 1;
                byte[] body = value.getBytes("UTF-16LE");
                text = new byte[body.length + 2];
                text[0] = (byte) 0xFF;
                text[1] = (byte) 0xFE;
                System.arraycopy(body, 0, text, 2, body.length);
            }
            byte[] data = new byte[1 + text.length];
            data[0] = enc;
            System.arraycopy(text, 0, data, 1, text.length);
            writeFrame(out, version, id, data);
        } catch (Exception ignored) {
        }
    }

    private static void putCommFrame(ByteArrayOutputStream out, int version, String value) {
        try {
            byte enc = (version >= 4) ? (byte) 3 : (byte) 1;
            ByteArrayOutputStream data = new ByteArrayOutputStream();
            data.write(enc);
            data.write('e');
            data.write('n');
            data.write('g');
            if (version >= 4) {
                data.write(0);
                data.write(value.getBytes("UTF-8"));
            } else {
                data.write(0);
                data.write(0); // 空描述的 UTF-16 终止符
                byte[] body = value.getBytes("UTF-16LE");
                data.write((byte) 0xFF);
                data.write((byte) 0xFE);
                data.write(body);
            }
            writeFrame(out, version, "COMM", data.toByteArray());
        } catch (Exception ignored) {
        }
    }

    /** USLT（非同步歌词）：编码 + 语言(3) + 空描述终止符 + 歌词正文。 */
    private static void putUsltFrame(ByteArrayOutputStream out, int version, String value) {
        if (value == null || value.trim().isEmpty()) {
            return; // 空值 = 清除歌词帧
        }
        try {
            ByteArrayOutputStream data = new ByteArrayOutputStream();
            if (version >= 4) {
                data.write(3); // UTF-8
                data.write('c');
                data.write('h');
                data.write('i');
                data.write(0); // 空描述
                data.write(value.getBytes("UTF-8"));
            } else {
                data.write(1); // UTF-16 with BOM
                data.write('c');
                data.write('h');
                data.write('i');
                data.write(0); // 空描述（UTF-16 双字节终止符）
                data.write(0);
                data.write((byte) 0xFF);
                data.write((byte) 0xFE);
                data.write(value.getBytes("UTF-16LE"));
            }
            writeFrame(out, version, "USLT", data.toByteArray());
        } catch (Exception ignored) {
        }
    }

    /** APIC（前置封面）：编码 0(ISO-8859-1) + MIME + \0 + 图片类型 3 + 空描述 + 图片字节。 */
    private static void putApicFrame(ByteArrayOutputStream out, int version, byte[] image) {
        try {
            String mime = CoverArt.mimeOf(image);
            if (mime.isEmpty()) {
                return;
            }
            ByteArrayOutputStream data = new ByteArrayOutputStream(image.length + 32);
            data.write(0); // 编码：ISO-8859-1（MIME 与描述都是 ASCII）
            data.write(mime.getBytes("ISO-8859-1"));
            data.write(0);
            data.write(3); // 图片类型：front cover
            data.write(0); // 空描述
            data.write(image);
            writeFrame(out, version, "APIC", data.toByteArray());
        } catch (Exception ignored) {
        }
    }

    /** 这个 MP3 里有没有封面（APIC 帧）。 */
    public static boolean hasCover(File file) {
        RandomAccessFile raf = null;
        try {
            raf = new RandomAccessFile(file, "r");
            byte[] head = new byte[10];
            raf.readFully(head);
            if (head[0] != 'I' || head[1] != 'D' || head[2] != '3') {
                return false;
            }
            int version = head[3] & 0xFF;
            int flags = head[5] & 0xFF;
            long size = syncsafe(head, 6);
            long tagEnd = 10 + size + ((flags & 0x10) != 0 ? 10 : 0);
            long pos = 10;
            if ((flags & 0x40) != 0) {
                byte[] sizeBuf = new byte[4];
                raf.readFully(sizeBuf);
                long extSize = (version >= 4) ? syncsafe(sizeBuf, 0) : be32(sizeBuf, 0);
                pos = 10 + 4 + extSize;
            }
            while (pos + 10 <= tagEnd) {
                raf.seek(pos);
                byte[] header = new byte[10];
                raf.readFully(header);
                if (header[0] == 0) {
                    break;
                }
                String id = ascii(header, 0, 4);
                long frameSize = (version >= 4) ? syncsafe(header, 4) : be32(header, 4);
                if (frameSize <= 0 || pos + 10 + frameSize > tagEnd) {
                    break;
                }
                if ("APIC".equals(id)) {
                    return true;
                }
                pos += 10 + frameSize;
            }
        } catch (Exception ignored) {
        } finally {
            close(raf);
        }
        return false;
    }

    private static void writeFrame(ByteArrayOutputStream out, int version,
                                   String id, byte[] data) throws IOException {
        if (data.length <= 0) {
            return;
        }
        out.write(asciiBytes(id));
        byte[] size = new byte[4];
        if (version >= 4) {
            writeSyncsafe(size, 0, data.length);
        } else {
            writeBe32(size, 0, data.length);
        }
        out.write(size);
        out.write(new byte[2]);
        out.write(data);
    }

    // ------------------------------------------------------------------
    // 位工具
    // ------------------------------------------------------------------

    private static long syncsafe(byte[] b, int off) {
        return ((b[off] & 0x7FL) << 21) | ((b[off + 1] & 0x7FL) << 14)
                | ((b[off + 2] & 0x7FL) << 7) | (b[off + 3] & 0x7FL);
    }

    private static long be32(byte[] b, int off) {
        return ((b[off] & 0xFFL) << 24) | ((b[off + 1] & 0xFFL) << 16)
                | ((b[off + 2] & 0xFFL) << 8) | (b[off + 3] & 0xFFL);
    }

    private static void writeSyncsafe(byte[] b, int off, long value) {
        b[off] = (byte) ((value >> 21) & 0x7F);
        b[off + 1] = (byte) ((value >> 14) & 0x7F);
        b[off + 2] = (byte) ((value >> 7) & 0x7F);
        b[off + 3] = (byte) (value & 0x7F);
    }

    private static void writeBe32(byte[] b, int off, long value) {
        b[off] = (byte) ((value >> 24) & 0xFF);
        b[off + 1] = (byte) ((value >> 16) & 0xFF);
        b[off + 2] = (byte) ((value >> 8) & 0xFF);
        b[off + 3] = (byte) (value & 0xFF);
    }

    private static String ascii(byte[] b, int off, int len) {
        StringBuilder sb = new StringBuilder(len);
        for (int i = 0; i < len; i++) {
            char c = (char) (b[off + i] & 0xFF);
            if (c < 32 || c > 126) {
                return sb.length() >= 2 ? sb.toString() : "";
            }
            sb.append(c);
        }
        return sb.toString();
    }

    private static byte[] asciiBytes(String s) {
        byte[] out = new byte[s.length()];
        for (int i = 0; i < s.length(); i++) {
            out[i] = (byte) s.charAt(i);
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
