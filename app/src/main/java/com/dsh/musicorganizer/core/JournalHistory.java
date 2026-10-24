package com.dsh.musicorganizer.core;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * 写入历史的「批次视图」。
 *
 * <p>{@link Journal} 是**逐条**流水（一次写入一行），而用户想撤销的单位是**一批**
 * （批量打标签 100 首共用同一个 batchId）。本类只做纯计算：把扁平记录折叠成批次，
 * 并算出一个批次里**还能撤销**的条目，便于「撤销历史」列表直接展示。
 *
 * <p>刻意不依赖 Android：数据通过 {@link Row} 传入，测试在纯 JVM 里跑。
 */
public final class JournalHistory {

    private JournalHistory() {
    }

    /** 一条写入记录（Journal.Entry 的投影）。 */
    public static class Row {
        public String id = "";
        public String timestamp = "";
        public String uri = "";
        public String batchId = "";
        public String status = "applied";
        public String targetId = "";
        public String name = "";

        public Row() {
        }

        public Row(String id, String timestamp, String batchId, String name, String status) {
            this.id = id;
            this.timestamp = timestamp;
            this.batchId = batchId;
            this.name = name;
            this.status = status;
        }
    }

    /** 一批可撤销的写入。 */
    public static class Batch {
        /** 批次键：有 batchId 用它，单条写入用 "one:" + id。 */
        public String key = "";
        /** 该批最后一次写入的时间（列表按它倒序）。 */
        public String time = "";
        /** 还能撤销的条数。 */
        public int count;
        /** 该批总条数（含已撤销的），用于说明「已撤销 x/n」。 */
        public int total;
        /** 文件名样例，最多 3 个。 */
        public final List<String> samples = new ArrayList<String>();
        /** 是否为「非批量」的单条写入。 */
        public boolean single;

        /** 列表主标题，如「10-23 01:12 · 23 首」。 */
        public String title() {
            String t = time;
            if (t.length() >= 16) {
                t = t.substring(5, 16);
            }
            return t + " · " + count + (single ? " 条" : " 首");
        }

        /** 副标题：文件名样例 + 已撤销情况。 */
        public String summary() {
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < samples.size(); i++) {
                if (i > 0) {
                    sb.append("、");
                }
                sb.append(samples.get(i));
            }
            if (count > samples.size()) {
                sb.append(" 等 ").append(count).append(" 个文件");
            }
            if (total > count) {
                sb.append(" · 其中 ").append(total - count).append(" 已撤销");
            }
            return sb.toString();
        }
    }

    /** 批次键（单条写入自成一批）。 */
    public static String keyOf(Row r) {
        if (r == null) {
            return "";
        }
        if (r.batchId != null && !r.batchId.isEmpty()) {
            return r.batchId;
        }
        return "one:" + r.id;
    }

    /** 已被撤销的记录 id 集合（reverted 记录的 targetId 指向原记录）。 */
    public static Set<String> revertedIds(List<Row> rows) {
        Set<String> out = new HashSet<String>();
        if (rows == null) {
            return out;
        }
        for (Row r : rows) {
            if (r != null && "reverted".equals(r.status) && r.targetId != null
                    && !r.targetId.isEmpty()) {
                out.add(r.targetId);
            }
        }
        return out;
    }

    /**
     * 折叠成批次列表，**按最后写入时间倒序**，最多 {@code limit} 个。
     * 只返回仍有可撤销条目的批次（全撤销完的不占位）。
     */
    public static List<Batch> build(List<Row> rows, int limit) {
        List<Batch> out = new ArrayList<Batch>();
        if (rows == null || rows.isEmpty()) {
            return out;
        }
        Set<String> reverted = revertedIds(rows);
        Map<String, Batch> map = new LinkedHashMap<String, Batch>();
        Map<String, Map<String, Integer>> seenPerBatch = new HashMap<String, Map<String, Integer>>();
        for (int i = 0; i < rows.size(); i++) {
            Row r = rows.get(i);
            if (r == null || !"applied".equals(r.status)) {
                continue;
            }
            String key = keyOf(r);
            Batch b = map.get(key);
            if (b == null) {
                b = new Batch();
                b.key = key;
                b.single = (r.batchId == null || r.batchId.isEmpty());
                b.time = r.timestamp == null ? "" : r.timestamp;
                map.put(key, b);
                seenPerBatch.put(key, new HashMap<String, Integer>());
            }
            b.total++;
            if (r.timestamp != null && r.timestamp.compareTo(b.time) > 0) {
                b.time = r.timestamp;
            }
            if (reverted.contains(r.id)) {
                continue;
            }
            b.count++;
            Map<String, Integer> seen = seenPerBatch.get(key);
            String name = r.name == null ? "" : r.name;
            if (name.isEmpty()) {
                name = nameFromUri(r.uri);
            }
            if (!name.isEmpty() && !seen.containsKey(name)) {
                seen.put(name, Integer.valueOf(seen.size()));
                if (b.samples.size() < 3) {
                    b.samples.add(name);
                }
            }
        }
        for (Batch b : map.values()) {
            if (b.count > 0) {
                out.add(b);
            }
        }
        // 时间倒序（时间串是 yyyy-MM-dd HH:mm:ss，可直接比较）；时间为空沉底
        java.util.Collections.sort(out, new java.util.Comparator<Batch>() {
            @Override
            public int compare(Batch a, Batch b) {
                return b.time.compareTo(a.time);
            }
        });
        if (limit > 0 && out.size() > limit) {
            return new ArrayList<Batch>(out.subList(0, limit));
        }
        return out;
    }

    /** 某批次里还能撤销的记录（保持写入顺序，撤销时由调用方逆序处理）。 */
    public static List<Row> targetsOf(List<Row> rows, String key) {
        List<Row> out = new ArrayList<Row>();
        if (rows == null || key == null || key.isEmpty()) {
            return out;
        }
        Set<String> reverted = revertedIds(rows);
        for (Row r : rows) {
            if (r == null || !"applied".equals(r.status)) {
                continue;
            }
            if (!key.equals(keyOf(r))) {
                continue;
            }
            if (reverted.contains(r.id)) {
                continue;
            }
            out.add(r);
        }
        return out;
    }

    /** 从 document uri 里取文件名（解码 %xx，去掉 query）。 */
    public static String nameFromUri(String uri) {
        if (uri == null || uri.isEmpty()) {
            return "";
        }
        String s = uri;
        int q = s.indexOf('?');
        if (q >= 0) {
            s = s.substring(0, q);
        }
        int slash = s.lastIndexOf('/');
        if (slash >= 0 && slash < s.length() - 1) {
            s = s.substring(slash + 1);
        }
        try {
            s = java.net.URLDecoder.decode(s, "UTF-8");
        } catch (Exception ignored) {
        }
        return s;
    }
}
