package com.dsh.musicorganizer.core;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * 垃圾文件识别（v0.1.38）。
 *
 * <p>曲库整理久了会攒下一堆东西：创建失败的 0 字节文件、`晴天.lrc.bak`（歌词偏移自己留的备份）、
 * 浏览器没下完的 `.crdownload`、Windows 拷过来的 `Thumbs.db`、以及从别处带来的 `.tmp`。
 * 这些留着既占地方，又会让「扫描到 N 个文件」的数字虚高。
 *
 * <p>只做**识别**，不删：把候选列出来让用户勾，删不删由人决定。
 * 刻意保守 —— 目录、隐藏的未知文件、正常的音频/歌词一律不进清单。
 */
public final class Junk {

    /** 明确的临时/系统文件名（小写比较）。 */
    private static final String[] SYSTEM_NAMES = {
            ".ds_store", "thumbs.db", "desktop.ini", ".directory",
    };

    /** 临时文件扩展名。 */
    private static final String[] TEMP_EXTS = {
            ".tmp", ".temp", ".part", ".download", ".crdownload", ".partial",
    };

    /** 小于这个体积的音频文件基本是「创建失败」的产物。 */
    public static final long TINY_AUDIO_BYTES = 1024;

    private Junk() {
    }

    /** 一条待清理项。 */
    public static class Item {
        public final VFile file;
        /** 为什么判定为垃圾（界面直接显示）。 */
        public final String reason;

        public Item(VFile file, String reason) {
            this.file = file;
            this.reason = reason;
        }

        public long size() {
            return file == null ? 0 : file.size;
        }

        public String sizeText() {
            return HealthCheck.size(size());
        }
    }

    /**
     * 从扫描结果里挑出垃圾候选（保持输入顺序）。
     *
     * @param files 扫描得到的文件列表（可含目录）
     */
    public static List<Item> plan(List<VFile> files) {
        List<Item> out = new ArrayList<Item>();
        if (files == null) {
            return out;
        }
        for (VFile f : files) {
            String reason = reasonOf(f);
            if (reason != null) {
                out.add(new Item(f, reason));
            }
        }
        return out;
    }

    /** 单个文件的判定；不是垃圾返回 null。 */
    public static String reasonOf(VFile f) {
        if (f == null || f.dir) {
            return null;
        }
        String name = f.name == null ? "" : f.name.trim();
        if (name.isEmpty()) {
            return "无文件名的空条目";
        }
        String lower = name.toLowerCase(Locale.US);
        for (String sys : SYSTEM_NAMES) {
            if (lower.equals(sys)) {
                return "系统垃圾文件";
            }
        }
        if (lower.endsWith(".lrc.bak") || lower.endsWith(".lrc.bak.txt")
                || lower.endsWith(".bak") || lower.endsWith(".bak.txt")) {
            return "歌词备份（.lrc.bak）";
        }
        String ext = f.ext();
        for (String t : TEMP_EXTS) {
            if (ext.equals(t)) {
                return "未完成的临时文件";
            }
        }
        if (f.size <= 0 && (f.audio() || f.lyric())) {
            return "0 字节（创建失败）";
        }
        if (f.audio() && f.size < TINY_AUDIO_BYTES) {
            return "音频不足 1KB（疑似损坏）";
        }
        return null;
    }

    /** 按原因归类：原因 → 数量（界面分组用，顺序按出现先后）。 */
    public static Map<String, Integer> byReason(List<Item> items) {
        Map<String, Integer> map = new LinkedHashMap<String, Integer>();
        if (items == null) {
            return map;
        }
        for (Item it : items) {
            Integer n = map.get(it.reason);
            map.put(it.reason, Integer.valueOf(n == null ? 1 : n.intValue() + 1));
        }
        return map;
    }

    /** 可释放的总字节。 */
    public static long totalSize(List<Item> items) {
        long sum = 0;
        if (items == null) {
            return 0;
        }
        for (Item it : items) {
            sum += it.size();
        }
        return sum;
    }

    /** 「删掉能省 1.2 MB」这种摘要。 */
    public static String summary(List<Item> items) {
        if (items == null || items.isEmpty()) {
            return "没有发现垃圾文件";
        }
        return items.size() + " 个文件 · 可释放 " + HealthCheck.size(totalSize(items));
    }
}
