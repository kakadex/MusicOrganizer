package com.dsh.musicorganizer.core;

import java.util.List;

/**
 * 整理后的目录结构。
 *
 * <p>以前只有一种结构：`根目录/艺人/`。想按专辑分、想整个摊平都做不到（v0.1.32 之前）。
 * 这里给出几种常见结构，纯字符串计算（不碰文件系统），便于回归测试：
 *
 * <pre>
 *   ARTIST            周杰伦/                     （默认，和以前一致）
 *   ARTIST_ALBUM      周杰伦/叶惠美/
 *   ARTIST_ALBUM_JOIN 周杰伦 - 叶惠美/
 *   FLAT              （根目录，不建任何子目录）
 * </pre>
 *
 * <p>专辑为空时（单曲、标签没写专辑）退回「艺人」这一层，不造「未知专辑」目录 ——
 * 那会把一堆不相关的歌硬塞在一起。
 */
public final class Layout {

    public static final int ARTIST = 0;
    public static final int ARTIST_ALBUM = 1;
    public static final int ARTIST_ALBUM_JOIN = 2;
    public static final int FLAT = 3;

    public static final String[] LABELS = new String[]{
            "艺人", "艺人 / 专辑", "艺人 - 专辑（单层）", "全部放根目录"
    };

    public static final String[] HINTS = new String[]{
            "周杰伦/晴天.mp3",
            "周杰伦/叶惠美/晴天.mp3",
            "周杰伦 - 叶惠美/晴天.mp3",
            "晴天.mp3（不建子目录）"
    };

    /** 单段目录名长度上限（太长的专辑名在文件管理器里看不到结尾）。 */
    private static final int MAX_SEGMENT = 60;

    private Layout() {
    }

    public static String label(int layout) {
        return LABELS[clamp(layout)];
    }

    public static int clamp(int layout) {
        if (layout < 0 || layout >= LABELS.length) {
            return ARTIST;
        }
        return layout;
    }

    /**
     * 目标目录（相对根目录，多层用 "/" 分隔；返回空串表示直接放根目录）。
     *
     * @param artist 已归一化的艺人目录名（可空）
     * @param album  专辑名（可空）
     */
    public static String path(int layout, String artist, String album) {
        String a = sanitizeSegment(artist);
        String b = sanitizeSegment(album);
        switch (clamp(layout)) {
            case FLAT:
                return "";
            case ARTIST_ALBUM:
                if (a.isEmpty()) {
                    return b.isEmpty() ? "" : b;
                }
                return b.isEmpty() ? a : a + "/" + b;
            case ARTIST_ALBUM_JOIN:
                if (a.isEmpty()) {
                    return b;
                }
                return b.isEmpty() ? a : a + " - " + b;
            case ARTIST:
            default:
                return a;
        }
    }

    /** 把路径拆成逐级目录名（忽略空段）。 */
    public static List<String> segments(String path) {
        java.util.List<String> out = new java.util.ArrayList<String>();
        if (path == null) {
            return out;
        }
        String[] parts = path.split("/");
        for (String p : parts) {
            String s = p.trim();
            if (!s.isEmpty()) {
                out.add(s);
            }
        }
        return out;
    }

    /** 目录名清理：非法字符换空格、去首尾点与空格、过长截断；「.」「..」这类危险名直接丢弃。 */
    public static String sanitizeSegment(String raw) {
        if (raw == null) {
            return "";
        }
        StringBuilder sb = new StringBuilder(raw.length());
        String s = raw.trim();
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c < 0x20 || "\\/:*?\"<>|".indexOf(c) >= 0) {
                sb.append(' ');
            } else {
                sb.append(c);
            }
        }
        String out = sb.toString().replaceAll("\\s{2,}", " ").trim();
        out = out.replaceAll("^[. ]+", "").replaceAll("[. ]+$", "");
        if (out.equals(".") || out.equals("..")) {
            return "";
        }
        if (out.length() > MAX_SEGMENT) {
            out = out.substring(0, MAX_SEGMENT).trim();
        }
        return out;
    }
}
