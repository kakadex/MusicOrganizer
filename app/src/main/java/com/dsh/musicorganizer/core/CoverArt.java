package com.dsh.musicorganizer.core;

/**
 * 封面图片的小工具：认格式、读尺寸、算摘要。
 *
 * <p>纯字节处理，不依赖 Android 的 Bitmap —— 这样封面逻辑能在桌面 JVM 里跑测试，
 * 也不用担心大图解码把内存顶爆（这里只读文件头里那几个字节）。
 */
public final class CoverArt {

    private CoverArt() {
    }

    /** 单张封面的大小上限：超过就不下（4MB 的封面已经远超「看得清」的需要）。 */
    public static final int MAX_BYTES = 4 * 1024 * 1024;

    /** 是不是 JPEG（FFD8FF）。 */
    public static boolean isJpeg(byte[] b) {
        return b != null && b.length > 3 && (b[0] & 0xFF) == 0xFF
                && (b[1] & 0xFF) == 0xD8 && (b[2] & 0xFF) == 0xFF;
    }

    /** 是不是 PNG（89 50 4E 47）。 */
    public static boolean isPng(byte[] b) {
        return b != null && b.length > 8 && (b[0] & 0xFF) == 0x89
                && b[1] == 'P' && b[2] == 'N' && b[3] == 'G';
    }

    /** MIME；不认识的图片返回空串。 */
    public static String mimeOf(byte[] b) {
        if (isJpeg(b)) {
            return "image/jpeg";
        }
        if (isPng(b)) {
            return "image/png";
        }
        return "";
    }

    /** {宽, 高}；解析不出返回 {0, 0}（仍可写入，只是显示不了尺寸）。 */
    public static int[] dimensions(byte[] b) {
        if (isPng(b)) {
            return pngSize(b);
        }
        if (isJpeg(b)) {
            return jpegSize(b);
        }
        return new int[]{0, 0};
    }

    private static int[] pngSize(byte[] b) {
        if (b.length < 24) {
            return new int[]{0, 0};
        }
        int w = ((b[16] & 0xFF) << 24) | ((b[17] & 0xFF) << 16)
                | ((b[18] & 0xFF) << 8) | (b[19] & 0xFF);
        int h = ((b[20] & 0xFF) << 24) | ((b[21] & 0xFF) << 16)
                | ((b[22] & 0xFF) << 8) | (b[23] & 0xFF);
        return new int[]{w, h};
    }

    private static int[] jpegSize(byte[] b) {
        int pos = 2;
        while (pos + 3 < b.length) {
            if ((b[pos] & 0xFF) != 0xFF) {
                pos++;
                continue;
            }
            int marker = b[pos + 1] & 0xFF;
            // 无长度的标记
            if (marker == 0xD8 || marker == 0xD9 || (marker >= 0xD0 && marker <= 0xD7)
                    || marker == 0x01) {
                pos += 2;
                continue;
            }
            int len = ((b[pos + 2] & 0xFF) << 8) | (b[pos + 3] & 0xFF);
            boolean sof = marker >= 0xC0 && marker <= 0xCF
                    && marker != 0xC4 && marker != 0xC8 && marker != 0xCC;
            if (sof && pos + 9 < b.length) {
                int h = ((b[pos + 5] & 0xFF) << 8) | (b[pos + 6] & 0xFF);
                int w = ((b[pos + 7] & 0xFF) << 8) | (b[pos + 8] & 0xFF);
                return new int[]{w, h};
            }
            if (len <= 0) {
                break;
            }
            pos += 2 + len;
        }
        return new int[]{0, 0};
    }

    /** 字节数转「120 KB」这种可读写法（刻意不依赖 AppLog，方便单测）。 */
    public static String sizeText(long bytes) {
        if (bytes < 1024) {
            return bytes + " B";
        }
        if (bytes < 1024 * 1024) {
            return (bytes / 1024) + " KB";
        }
        return String.format(java.util.Locale.US, "%.1f MB", bytes / 1024.0 / 1024.0);
    }

    /** 「JPEG 800×800 · 120 KB」，预览与日志里用。 */
    public static String describe(byte[] b) {
        if (b == null || b.length == 0) {
            return "无图片";
        }
        String mime = mimeOf(b);
        String kind = mime.equals("image/png") ? "PNG" : (mime.isEmpty() ? "未知格式" : "JPEG");
        int[] size = dimensions(b);
        StringBuilder sb = new StringBuilder(kind);
        if (size[0] > 0 && size[1] > 0) {
            sb.append(' ').append(size[0]).append('×').append(size[1]);
        }
        sb.append(" · ").append(sizeText(b.length));
        return sb.toString();
    }
}
