package com.dsh.musicorganizer.core;

import java.util.ArrayList;
import java.util.List;

/**
 * 曲库清单导出（CSV）。
 *
 * <p>用户把曲库搬到电脑上整理、做表、发给别人时，需要一个能被 Excel / Numbers 直接打开的表。
 * 这里只做**格式与转义**，不读文件：调用方把标签读好填进 {@link Row}。
 *
 * <p>转义按 RFC 4180：含逗号 / 引号 / 换行的字段整体加双引号，内部引号写两遍。
 * 另外带 UTF-8 BOM，否则 Windows 版 Excel 打开中文会乱码（这条踩过太多次）。
 */
public final class CsvExport {

    public static final String[] HEADER = {
            "文件名", "标题", "歌手", "专辑", "年份", "音轨", "流派", "大小(字节)",
            "有无封面", "有无歌词", "所在目录"
    };

    private CsvExport() {
    }

    /** 一行清单数据。 */
    public static class Row {
        public String name = "";
        public String title = "";
        public String artist = "";
        public String album = "";
        public String year = "";
        public String track = "";
        public String genre = "";
        public long size;
        public boolean cover;
        public boolean lyrics;
        public String dir = "";
    }

    /** 生成整份 CSV 文本（带 BOM，CRLF 换行）。 */
    public static String build(List<Row> rows) {
        StringBuilder sb = new StringBuilder(rows == null ? 256 : rows.size() * 100 + 256);
        sb.append('\uFEFF');
        for (int i = 0; i < HEADER.length; i++) {
            if (i > 0) {
                sb.append(',');
            }
            sb.append(esc(HEADER[i]));
        }
        sb.append("\r\n");
        if (rows == null) {
            return sb.toString();
        }
        for (Row r : rows) {
            if (r == null) {
                continue;
            }
            appendCell(sb, r.name, 0);
            appendCell(sb, r.title, 1);
            appendCell(sb, r.artist, 2);
            appendCell(sb, r.album, 3);
            appendCell(sb, r.year, 4);
            appendCell(sb, r.track, 5);
            appendCell(sb, r.genre, 6);
            appendCell(sb, String.valueOf(r.size), 7);
            appendCell(sb, r.cover ? "有" : "", 8);
            appendCell(sb, r.lyrics ? "有" : "", 9);
            appendCell(sb, r.dir, 10);
            sb.append("\r\n");
        }
        return sb.toString();
    }

    private static void appendCell(StringBuilder sb, String value, int index) {
        if (index > 0) {
            sb.append(',');
        }
        sb.append(esc(value));
    }

    /** 单字段转义：含逗号 / 引号 / 换行才加引号，内部引号翻倍。 */
    public static String esc(String value) {
        if (value == null || value.isEmpty()) {
            return "";
        }
        boolean need = false;
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            if (c == ',' || c == '"' || c == '\n' || c == '\r') {
                need = true;
                break;
            }
        }
        if (!need) {
            return value;
        }
        StringBuilder sb = new StringBuilder(value.length() + 8);
        sb.append('"');
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            if (c == '"') {
                sb.append('"');
            }
            sb.append(c);
        }
        sb.append('"');
        return sb.toString();
    }

    /** 数据行数（不含表头），便于日志里报「导出 N 行」。 */
    public static int rowCount(String csv) {
        if (csv == null || csv.isEmpty()) {
            return 0;
        }
        int n = 0;
        boolean inQuote = false;
        for (int i = 0; i < csv.length(); i++) {
            char c = csv.charAt(i);
            if (c == '"') {
                inQuote = !inQuote;
            } else if (c == '\n' && !inQuote) {
                n++;
            }
        }
        // 末行没有换行时补一行；表头那行不算
        if (csv.length() > 0 && csv.charAt(csv.length() - 1) != '\n') {
            n++;
        }
        return Math.max(0, n - 1);
    }

    /** 默认文件名：音乐整理-曲库清单-yyyyMMdd-HHmm.csv */
    public static String defaultFileName(java.util.Date now) {
        java.text.SimpleDateFormat f = new java.text.SimpleDateFormat(
                "yyyyMMdd-HHmm", java.util.Locale.US);
        return "音乐整理-曲库清单-" + f.format(now) + ".csv";
    }

    /** 便捷构造：把标签与探测结果拼成一行。 */
    public static Row make(VFile file, Tags tags, boolean cover, boolean lyrics) {
        Row r = new Row();
        r.name = file == null ? "" : file.name;
        r.size = file == null ? 0 : file.size;
        r.cover = cover;
        r.lyrics = lyrics;
        if (tags != null) {
            r.title = tags.get("title").trim();
            r.artist = tags.get("artist").trim();
            r.album = tags.get("album").trim();
            r.year = tags.get("year").trim();
            r.track = tags.get("track").trim();
            r.genre = tags.get("genre").trim();
        }
        return r;
    }

    /** 只保留音频行（导出前过滤用）。 */
    public static List<VFile> audioOnly(List<VFile> files) {
        List<VFile> out = new ArrayList<VFile>();
        if (files == null) {
            return out;
        }
        for (VFile f : files) {
            if (f != null && f.audio()) {
                out.add(f);
            }
        }
        return out;
    }
}
