package com.dsh.musicorganizer.core;

import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * 重复文件的分组逻辑（纯 Java，v0.1.58）。
 *
 * <p>为什么要按内容找，而不是按文件名：整理 / 多次导入之后，同一首歌常变成
 * 「歌.mp3」「歌 (1).mp3」「歌_2.mp3」散在不同目录，文件名相似度可能不到阈值，
 * 但**内容完全一样**。这里先用大小分桶（几乎不花 IO），只对同大小的文件算哈希，
 * 1024 首的量级通常只有几十个候选，成本可以忽略。
 *
 * <p>哈希只取文件头 64KB：一首歌的头部（含标签、封面、第一帧音频）足以区分不同版本，
 * 又不必把几 MB 的文件整个读一遍。两个文件如果「头 64KB 相同但整体不同」，
 * 那基本是同一首歌的不同片段 —— 这种情况宁可漏判，也不要误删。
 */
public final class DupFiles {

    /** 参与比较的头部字节数。 */
    public static final int HEAD_BYTES = 64 * 1024;

    private DupFiles() {
    }

    /** 一个候选文件。 */
    public static final class Item {
        public final String docId;
        /** 相对音乐根的路径（显示用）。 */
        public final String path;
        public final String name;
        public final long size;
        /** 头部哈希；空串表示还没算。 */
        public String hash = "";

        public Item(String docId, String path, String name, long size) {
            this.docId = docId;
            this.path = path == null ? "" : path;
            this.name = name == null ? "" : name;
            this.size = size;
        }

        /** 目录层级越浅越可能是「原本那份」。 */
        public int depth() {
            int n = 0;
            for (int i = 0; i < path.length(); i++) {
                if (path.charAt(i) == '/') {
                    n++;
                }
            }
            return n;
        }
    }

    /** 一组内容相同的文件（至少 2 个）。 */
    public static final class Group {
        public final List<Item> items;

        Group(List<Item> items) {
            this.items = items;
        }

        public long size() {
            return items.isEmpty() ? 0L : items.get(0).size;
        }

        /** 删掉多余副本能省下的字节。 */
        public long wasted() {
            return size() * Math.max(0, items.size() - 1);
        }

        /**
         * 建议保留哪一个：目录层级最浅（最像原始位置）、其次路径最短、最后按名字排序。
         *
         * <p>不建议按「大小」或「修改时间」判断 —— 复制会刷新时间，时间早的反而可能是副本。
         */
        public Item suggestKeep() {
            Item best = null;
            for (Item it : items) {
                if (best == null) {
                    best = it;
                    continue;
                }
                if (it.depth() != best.depth()) {
                    if (it.depth() < best.depth()) {
                        best = it;
                    }
                    continue;
                }
                if (it.path.length() != best.path.length()) {
                    if (it.path.length() < best.path.length()) {
                        best = it;
                    }
                    continue;
                }
                if (it.path.compareTo(best.path) < 0) {
                    best = it;
                }
            }
            return best;
        }
    }

    /** 按大小分桶：只返回「可能重复」的桶（大小相同且至少 2 个，且不是 0 字节）。 */
    public static List<List<Item>> bySize(List<Item> items) {
        Map<Long, List<Item>> buckets = new LinkedHashMap<Long, List<Item>>();
        if (items == null) {
            return new ArrayList<List<Item>>();
        }
        for (Item it : items) {
            if (it == null || it.size <= 0) {
                continue;
            }
            List<Item> list = buckets.get(it.size);
            if (list == null) {
                list = new ArrayList<Item>();
                buckets.put(it.size, list);
            }
            list.add(it);
        }
        List<List<Item>> out = new ArrayList<List<Item>>();
        for (List<Item> list : buckets.values()) {
            if (list.size() > 1) {
                out.add(list);
            }
        }
        return out;
    }

    /** 在已填好 hash 的候选里分组（同大小 + 同 hash 才算重复）。 */
    public static List<Group> groups(List<Item> candidates) {
        Map<String, List<Item>> byKey = new HashMap<String, List<Item>>();
        if (candidates != null) {
            for (Item it : candidates) {
                if (it == null || it.hash == null || it.hash.isEmpty()) {
                    continue;
                }
                String key = it.size + "|" + it.hash;
                List<Item> list = byKey.get(key);
                if (list == null) {
                    list = new ArrayList<Item>();
                    byKey.put(key, list);
                }
                list.add(it);
            }
        }
        List<Group> out = new ArrayList<Group>();
        for (List<Item> list : byKey.values()) {
            if (list.size() > 1) {
                out.add(new Group(list));
            }
        }
        // 浪费空间大的排前面，用户先看到最值得清的
        java.util.Collections.sort(out, new java.util.Comparator<Group>() {
            @Override
            public int compare(Group a, Group b) {
                long d = b.wasted() - a.wasted();
                return d > 0 ? 1 : (d < 0 ? -1 : 0);
            }
        });
        return out;
    }

    /** 头部字节的 SHA-256（十六进制小写）；数据为空返回空串。 */
    public static String hash(byte[] head) {
        if (head == null || head.length == 0) {
            return "";
        }
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] d = md.digest(head);
            StringBuilder sb = new StringBuilder(d.length * 2);
            for (byte b : d) {
                sb.append(Character.forDigit((b >> 4) & 0xF, 16));
                sb.append(Character.forDigit(b & 0xF, 16));
            }
            return sb.toString();
        } catch (Exception e) {
            return "";
        }
    }

    /** 一句话汇总：「3 组 · 7 个多余副本 · 可省 82.3 MB」。 */
    public static String summary(List<Group> groups) {
        if (groups == null || groups.isEmpty()) {
            return "没有发现内容相同的文件";
        }
        int extra = 0;
        long bytes = 0;
        for (Group g : groups) {
            extra += Math.max(0, g.items.size() - 1);
            bytes += g.wasted();
        }
        return groups.size() + " 组 · " + extra + " 个多余副本 · 可省 "
                + HealthCheck.size(bytes);
    }

    /** 扩展名（小写，含点）；没有返回空串。 */
    static String extOf(String name) {
        if (name == null) {
            return "";
        }
        int dot = name.lastIndexOf('.');
        return dot >= 0 ? name.substring(dot).toLowerCase(Locale.ROOT) : "";
    }
}
