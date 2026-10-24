package com.dsh.musicorganizer.core;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.RandomAccessFile;
import java.nio.charset.Charset;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * WMA（ASF 容器）标签**只读**解析。
 *
 * <p>WMA 用 ASF 容器，标签放在两处：
 * <ul>
 *   <li><b>Content Description Object</b>：标题 / 作者 / 版权 / 描述 / 评级（5 个长度 + UTF-16LE 字符串）；</li>
 *   <li><b>Extended Content Description Object</b>：键值对列表，{@code WM/AlbumTitle}、
 *       {@code WM/Genre}、{@code WM/Year}、{@code WM/TrackNumber} 这些都在这里。</li>
 * </ul>
 *
 * <p>只读不写：ASF 头对象的大小字段与内部对象长度层层嵌套，改标签要重排整段头部；
 * 一旦算错，Windows 媒体播放器会直接拒绝打开。写标签的成本远高于「转成 FLAC/MP3」，
 * 所以这里只做读取（显示、预览、导出清单都能用），写入仍提示转码。
 */
public final class Wma {

    private Wma() {
    }

    /** ASF Header Object 的 GUID（小端存储的实际字节序）。 */
    private static final byte[] GUID_HEADER = {
            0x30, 0x26, (byte) 0xB2, 0x75, (byte) 0x8E, 0x66, (byte) 0xCF, 0x11,
            (byte) 0xA6, (byte) 0xD9, 0x00, (byte) 0xAA, 0x00, 0x62, (byte) 0xCE, 0x6C
    };
    private static final byte[] GUID_CONTENT = {
            0x33, 0x26, (byte) 0xB2, 0x75, (byte) 0x8E, 0x66, (byte) 0xCF, 0x11,
            (byte) 0xA6, (byte) 0xD9, 0x00, (byte) 0xAA, 0x00, 0x62, (byte) 0xCE, 0x6C
    };
    private static final byte[] GUID_EXT_CONTENT = {
            0x40, (byte) 0xA4, (byte) 0xD0, (byte) 0xD2, 0x07, (byte) 0xE3, (byte) 0xD2, 0x11,
            (byte) 0x97, (byte) 0xF0, 0x00, (byte) 0xA0, (byte) 0xC9, 0x5E, (byte) 0xA8, 0x50
    };
    private static final byte[] GUID_FILE_PROPERTIES = {
            0x64, 0x66, (byte) 0xA1, (byte) 0xA5, (byte) 0xE1, 0x76, (byte) 0xE4, 0x4D,
            (byte) 0x8B, (byte) 0xCA, 0x0B, 0x0B, (byte) 0xF1, (byte) 0x8B, 0x5A, (byte) 0xE8
    };

    public static boolean isWma(File file) {
        return hasPrefix(file, GUID_HEADER);
    }

    /** 读标签（只读；写不了，返回的 Tags 仅供显示与预览）。 */
    public static Tags read(File file) {
        Tags tags = new Tags();
        if (!isWma(file)) {
            return tags;
        }
        Map<String, String> map = new LinkedHashMap<String, String>();
        try {
            byte[] head = readHeader(file);
            if (head == null || head.length < 30) {
                return tags;
            }
            long headerSize = le64(head, 16);
            int count = (int) le32(head, 24);
            int pos = 30;
            long limit = Math.min(head.length, headerSize);
            for (int i = 0; i < count && pos + 24 <= limit; i++) {
                long objSize = le64(head, pos + 16);
                if (objSize < 24 || pos + objSize > limit) {
                    break;
                }
                int dataStart = pos + 24;
                int dataLen = (int) objSize - 24;
                if (startsWith(head, pos, GUID_CONTENT)) {
                    readContentDescription(head, dataStart, dataLen, map);
                } else if (startsWith(head, pos, GUID_EXT_CONTENT)) {
                    readExtendedContent(head, dataStart, dataLen, map);
                } else if (startsWith(head, pos, GUID_FILE_PROPERTIES)) {
                    // 时长一般由播放器/系统算，这里不需要
                }
                pos += (int) objSize;
            }
        } catch (Exception ignored) {
        }
        put(tags, map, "title", "title");
        put(tags, map, "artist", "author");
        put(tags, map, "album", "wm/albumtitle");
        put(tags, map, "year", "wm/year");
        put(tags, map, "track", "wm/tracknumber");
        put(tags, map, "genre", "wm/genre");
        put(tags, map, "comment", "description");
        put(tags, map, "lyrics", "wm/lyrics");
        return tags;
    }

    private static void put(Tags tags, Map<String, String> map, String field, String key) {
        String v = map.get(key);
        if (v != null && !v.trim().isEmpty()) {
            tags.put(field, v.trim());
        }
    }

    /** Content Description：5 个 WORD 长度在前，随后是 UTF-16LE 字符串。 */
    private static void readContentDescription(byte[] buf, int start, int len,
                                               Map<String, String> out) {
        if (len < 10) {
            return;
        }
        int[] sizes = new int[5];
        for (int i = 0; i < 5; i++) {
            sizes[i] = (buf[start + i * 2] & 0xFF) | ((buf[start + i * 2 + 1] & 0xFF) << 8);
        }
        int pos = start + 10;
        String[] keys = {"title", "author", "copyright", "description", "rating"};
        for (int i = 0; i < 5; i++) {
            int n = sizes[i];
            if (n <= 0 || pos + n > start + len) {
                continue;
            }
            String v = utf16(buf, pos, n);
            pos += n;
            if (!v.isEmpty() && !out.containsKey(keys[i])) {
                out.put(keys[i], v);
            }
        }
    }

    /** Extended Content：WORD 计数 + 每项（名字长度 + 名字 + 类型 + 值长度 + 值）。 */
    private static void readExtendedContent(byte[] buf, int start, int len,
                                            Map<String, String> out) {
        if (len < 2) {
            return;
        }
        int count = (buf[start] & 0xFF) | ((buf[start + 1] & 0xFF) << 8);
        int pos = start + 2;
        int end = start + len;
        for (int i = 0; i < count && pos + 2 <= end; i++) {
            int nameLen = (buf[pos] & 0xFF) | ((buf[pos + 1] & 0xFF) << 8);
            pos += 2;
            if (nameLen <= 0 || pos + nameLen + 4 > end) {
                break;
            }
            String name = utf16(buf, pos, nameLen).toLowerCase(java.util.Locale.US);
            pos += nameLen;
            int type = (buf[pos] & 0xFF) | ((buf[pos + 1] & 0xFF) << 8);
            int valueLen = (buf[pos + 2] & 0xFF) | ((buf[pos + 3] & 0xFF) << 8);
            pos += 4;
            if (valueLen < 0 || pos + valueLen > end) {
                break;
            }
            String value;
            if (type == 0) {
                value = utf16(buf, pos, valueLen); // 字符串
            } else if (type == 3 && valueLen >= 4) {
                value = String.valueOf(le32(buf, pos)); // DWORD
            } else if (type == 5 && valueLen >= 2) {
                value = String.valueOf((buf[pos] & 0xFF) | ((buf[pos + 1] & 0xFF) << 8)); // WORD/Bool
            } else if (type == 4 && valueLen >= 8) {
                value = String.valueOf(le64(buf, pos)); // QWORD
            } else {
                value = "";
            }
            pos += valueLen;
            if (!value.isEmpty() && !out.containsKey(name)) {
                out.put(name, value);
            }
        }
    }

    private static String utf16(byte[] buf, int off, int len) {
        try {
            String v = new String(buf, off, len, Charset.forName("UTF-16LE"));
            int nul = v.indexOf('\u0000');
            if (nul >= 0) {
                v = v.substring(0, nul);
            }
            return v;
        } catch (Exception e) {
            return "";
        }
    }

    private static byte[] readHeader(File file) throws Exception {
        RandomAccessFile raf = new RandomAccessFile(file, "r");
        try {
            long len = file.length();
            byte[] head = new byte[30];
            raf.readFully(head);
            long headerSize = le64(head, 16);
            if (headerSize <= 0 || headerSize > len || headerSize > 4L * 1024 * 1024) {
                return null;
            }
            byte[] out = new byte[(int) headerSize];
            System.arraycopy(head, 0, out, 0, 30);
            raf.readFully(out, 30, (int) headerSize - 30);
            return out;
        } finally {
            try {
                raf.close();
            } catch (Exception ignored) {
            }
        }
    }

    private static boolean hasPrefix(File file, byte[] prefix) {
        if (file == null || !file.isFile() || file.length() < prefix.length) {
            return false;
        }
        RandomAccessFile raf = null;
        try {
            raf = new RandomAccessFile(file, "r");
            byte[] got = new byte[prefix.length];
            raf.readFully(got);
            return startsWith(got, 0, prefix);
        } catch (Exception e) {
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

    private static boolean startsWith(byte[] buf, int off, byte[] prefix) {
        if (buf == null || off + prefix.length > buf.length) {
            return false;
        }
        for (int i = 0; i < prefix.length; i++) {
            if (buf[off + i] != prefix[i]) {
                return false;
            }
        }
        return true;
    }

    private static long le32(byte[] b, int off) {
        return ((long) (b[off] & 0xFF)) | ((long) (b[off + 1] & 0xFF) << 8)
                | ((long) (b[off + 2] & 0xFF) << 16) | ((long) (b[off + 3] & 0xFF) << 24);
    }

    private static long le64(byte[] b, int off) {
        long v = 0;
        for (int i = 7; i >= 0; i--) {
            v = (v << 8) | (b[off + i] & 0xFFL);
        }
        return v;
    }

    /** UTF-16LE 编码（长度补齐为偶数）；回归测试造样本也要用同一编码。 */
    public static byte[] utf16Bytes(String s) {
        try {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            out.write(s.getBytes("UTF-16LE"));
            if ((out.size() & 1) == 1) {
                out.write(0);
            }
            return out.toByteArray();
        } catch (Exception e) {
            return new byte[0];
        }
    }
}
