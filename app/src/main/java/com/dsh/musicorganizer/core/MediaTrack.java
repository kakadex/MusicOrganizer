package com.dsh.musicorganizer.core;

import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;

/**
 * 系统媒体库里的一条音频（v0.1.42）—— MediaStore 扫描的纯数据部分。
 *
 * <p>为什么要 MediaStore：SAF 授权拿不到「下载」这类根目录（Android 11+ 限制），
 * 而系统媒体库有特权，能把这些歌列出来。但它**不提供文档 URI**，写入标签走不通，
 * 所以本类的用途是「列出 + 筛选 + 一键导入到已授权的目录」，导入后就能用全套功能。
 *
 * <p>纯 Java（不依赖 android.provider），扫描结果由 Android 层填 {@link MediaTrack}，
 * 筛选与排序在这里做，方便回归。
 */
public final class MediaTrack {

    /** MediaStore 的 \_id，导入时用它拼 content uri。 */
    public long id;
    public String title = "";
    public String artist = "";
    public String album = "";
    public long durationMs;
    public long size;
    public String mime = "";
    /** 绝对路径（MediaStore 的 DATA 列；Android 10+ 可能为空，只用于显示）。 */
    public String path = "";
    /** 所在目录（从 path 里去掉文件名，纯显示用）。 */
    public String folder = "";
    /** 是否已加入当前授权目录（导入后置 true，避免重复导入）。 */
    public boolean imported;

    public MediaTrack() {
    }

    public MediaTrack(long id, String title, String artist, String album, long durationMs,
                      long size, String mime, String path) {
        this.id = id;
        this.title = title == null ? "" : title.trim();
        this.artist = artist == null ? "" : artist.trim();
        this.album = album == null ? "" : album.trim();
        this.durationMs = durationMs;
        this.size = size;
        this.mime = mime == null ? "" : mime;
        this.path = path == null ? "" : path;
        this.folder = folderOf(this.path);
    }

    /** 列表标题：有标题用「艺人 - 标题」，没有就用文件名。 */
    public String display() {
        String name = fileName();
        if (title.isEmpty()) {
            return name;
        }
        return artist.isEmpty() ? title : artist + " - " + title;
    }

    /** 文件名（从 path 取最后一段；path 空时按 mime 猜个扩展名）。 */
    public String fileName() {
        String p = path;
        if (!p.isEmpty()) {
            int slash = p.lastIndexOf('/');
            if (slash >= 0 && slash < p.length() - 1) {
                return p.substring(slash + 1);
            }
        }
        String base = title.isEmpty() ? ("track-" + id) : title;
        String ext = extFromMime();
        return base + ext;
    }

    /** 大小 + 时长，列表第二行用。 */
    public String detail() {
        StringBuilder sb = new StringBuilder();
        sb.append(HealthCheck.size(size));
        if (durationMs > 0) {
            long sec = durationMs / 1000;
            sb.append(" · ").append(sec / 60).append(':')
                    .append(String.format(Locale.US, "%02d", sec % 60));
        }
        if (!album.isEmpty()) {
            sb.append(" · ").append(album);
        }
        if (!folder.isEmpty()) {
            sb.append(" · ").append(folder);
        }
        return sb.toString();
    }

    /** 估算时长（秒），给歌词匹配用（当前导入流程不用，留作扩展）。 */
    public Double durationSeconds() {
        return durationMs > 0 ? Double.valueOf(durationMs / 1000.0) : null;
    }

    private String extFromMime() {
        if (mime.contains("mpeg")) {
            return ".mp3";
        }
        if (mime.contains("flac")) {
            return ".flac";
        }
        if (mime.contains("mp4") || mime.contains("m4a")) {
            return ".m4a";
        }
        if (mime.contains("wav")) {
            return ".wav";
        }
        if (mime.contains("ogg")) {
            return ".ogg";
        }
        return ".mp3";
    }

    /** 取路径的上一层目录名（纯显示用）；根目录或空返回空串。 */
    public static String folderOf(String path) {
        if (path == null) {
            return "";
        }
        int slash = path.lastIndexOf('/');
        if (slash <= 0) {
            return "";
        }
        String dir = path.substring(0, slash);
        int prev = dir.lastIndexOf('/');
        return prev >= 0 && prev < dir.length() - 1 ? dir.substring(prev + 1) : dir;
    }

    // ------------------------------------------------------------------
    // 筛选 / 排序
    // ------------------------------------------------------------------

    /**
     * 搜索过滤：空格分词，全部命中才算（标题 / 艺人 / 专辑 / 路径都参与），
     * 大小写与全角半角不敏感（借用 {@link TextUtil#normCompare} 的思路）。
     * 空查询返回原列表（不复制）。
     */
    public static List<MediaTrack> filter(List<MediaTrack> tracks, String query) {
        if (tracks == null) {
            return new ArrayList<MediaTrack>();
        }
        String q = query == null ? "" : query.trim();
        if (q.isEmpty()) {
            return tracks;
        }
        String[] terms = q.toLowerCase(Locale.US).split("\\s+");
        List<MediaTrack> out = new ArrayList<MediaTrack>();
        for (MediaTrack t : tracks) {
            String hay = (t.title + " " + t.artist + " " + t.album + " " + t.path)
                    .toLowerCase(Locale.US);
            boolean all = true;
            for (String term : terms) {
                if (term.isEmpty()) {
                    continue;
                }
                if (hay.indexOf(term) < 0) {
                    all = false;
                    break;
                }
            }
            if (all) {
                out.add(t);
            }
        }
        return out;
    }

    /** 按标题（没有标题时按文件名）排序，中文按 Unicode 序，稳定可预期。 */
    public static void sortByTitle(List<MediaTrack> tracks) {
        if (tracks == null) {
            return;
        }
        Collections.sort(tracks, new Comparator<MediaTrack>() {
            @Override
            public int compare(MediaTrack a, MediaTrack b) {
                String x = a.title.isEmpty() ? a.fileName() : a.title;
                String y = b.title.isEmpty() ? b.fileName() : b.title;
                int c = x.compareToIgnoreCase(y);
                return c != 0 ? c : Long.compare(a.id, b.id);
            }
        });
    }

    /** 按体积倒序（找大文件用）。 */
    public static void sortBySize(List<MediaTrack> tracks) {
        if (tracks == null) {
            return;
        }
        Collections.sort(tracks, new Comparator<MediaTrack>() {
            @Override
            public int compare(MediaTrack a, MediaTrack b) {
                int c = Long.compare(b.size, a.size);
                return c != 0 ? c : Long.compare(a.id, b.id);
            }
        });
    }

    /** 总字节。 */
    public static long totalSize(List<MediaTrack> tracks) {
        long sum = 0;
        if (tracks == null) {
            return 0;
        }
        for (MediaTrack t : tracks) {
            sum += t.size;
        }
        return sum;
    }

    /** 一句话摘要：「系统媒体库 911 首 · 34.2 GB」。 */
    public static String summary(List<MediaTrack> tracks) {
        if (tracks == null || tracks.isEmpty()) {
            return "系统媒体库没有扫到音频";
        }
        return "系统媒体库 " + tracks.size() + " 首 · " + HealthCheck.size(totalSize(tracks));
    }

    /** 导入时的目标文件名：非法字符换空格、去首尾点，撞名由调用方加序号。 */
    public static String safeFileName(MediaTrack t) {
        String raw = t.fileName();
        StringBuilder sb = new StringBuilder(raw.length());
        for (int i = 0; i < raw.length(); i++) {
            char c = raw.charAt(i);
            if (c < 0x20 || "\\/:*?\"<>|".indexOf(c) >= 0) {
                sb.append(' ');
            } else {
                sb.append(c);
            }
        }
        String out = sb.toString().replaceAll("\\s{2,}", " ").trim()
                .replaceAll("^[. ]+", "").replaceAll("[. ]+$", "");
        if (out.isEmpty()) {
            out = "track-" + t.id;
        }
        if (out.length() > 90) {
            out = out.substring(0, 90);
        }
        return out;
    }
}
