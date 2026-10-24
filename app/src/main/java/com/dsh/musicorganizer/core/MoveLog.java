package com.dsh.musicorganizer.core;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 整理移动日志的数据与纯计算（v0.1.39）。
 *
 * <p>刻意不依赖 Android：序列化、解析、按批次折叠、逆序全部在这里，
 * 落盘与「搬回原处」放在 {@link MoveJournal}。这样格式与分组逻辑能在纯 JVM 里回归。
 *
 * <p>一行 TSV：{@code 批次号 \t 时间 \t 原目录 \t 原文件名 \t 目标目录 \t 目标文件名}
 */
public final class MoveLog {

    private MoveLog() {
    }

    /** 一次移动。 */
    public static class Record {
        public String batchId = "";
        public String time = "";
        public String fromDir = "";
        public String fromName = "";
        public String toDir = "";
        public String toName = "";

        public Record() {
        }

        public Record(String batchId, String time, String fromDir, String fromName,
                      String toDir, String toName) {
            this.batchId = batchId;
            this.time = time;
            this.fromDir = fromDir == null ? "" : fromDir;
            this.fromName = fromName == null ? "" : fromName;
            this.toDir = toDir == null ? "" : toDir;
            this.toName = toName == null ? "" : toName;
        }
    }

    /** 一个批次（一次整理）。 */
    public static class Batch {
        public String batchId = "";
        public String time = "";
        public int count;

        public String title() {
            String t = time.length() >= 16 ? time.substring(5, 16) : time;
            return t + " · " + count + " 个文件";
        }
    }

    // ------------------------------------------------------------------
    // 序列化（纯函数，回归测试覆盖）
    // ------------------------------------------------------------------

    /** 一行 TSV；字段内的制表符/换行替换成空格。 */
    public static String serialize(Record r) {
        if (r == null) {
            return "";
        }
        return clean(r.batchId) + '\t' + clean(r.time) + '\t' + clean(r.fromDir) + '\t'
                + clean(r.fromName) + '\t' + clean(r.toDir) + '\t' + clean(r.toName);
    }

    /** 解析一行；字段不足或为空批次号返回 null（坏行直接跳过，不影响其它记录）。 */
    public static Record parse(String line) {
        if (line == null) {
            return null;
        }
        String[] parts = line.split("\t", -1);
        if (parts.length < 6) {
            return null;
        }
        Record r = new Record(parts[0], parts[1], parts[2], parts[3], parts[4], parts[5]);
        if (r.batchId.trim().isEmpty() || r.toDir.trim().isEmpty()) {
            return null;
        }
        return r;
    }

    /** 折叠成批次（按时间倒序）。 */
    public static List<Batch> group(List<Record> records) {
        List<Batch> out = new ArrayList<Batch>();
        if (records == null) {
            return out;
        }
        Map<String, Batch> map = new LinkedHashMap<String, Batch>();
        for (Record r : records) {
            if (r == null || r.batchId.isEmpty()) {
                continue;
            }
            Batch b = map.get(r.batchId);
            if (b == null) {
                b = new Batch();
                b.batchId = r.batchId;
                b.time = r.time;
                map.put(r.batchId, b);
            }
            b.count++;
            if (r.time != null && r.time.compareTo(b.time) > 0) {
                b.time = r.time;
            }
        }
        out.addAll(map.values());
        java.util.Collections.sort(out, new java.util.Comparator<Batch>() {
            @Override
            public int compare(Batch a, Batch b) {
                return b.time.compareTo(a.time);
            }
        });
        return out;
    }

    /** 逆序（撤销时后搬的先搬回，避免中途失败留下半搬状态）。 */
    public static List<Record> reversed(List<Record> records) {
        List<Record> out = new ArrayList<Record>();
        if (records == null) {
            return out;
        }
        for (int i = records.size() - 1; i >= 0; i--) {
            out.add(records.get(i));
        }
        return out;
    }

    /** 单条清理：字段里的制表符与换行替换成空格，保证一行一条。 */
    static String clean(String s) {
        if (s == null) {
            return "";
        }
        return s.replace('\t', ' ').replace('\n', ' ').replace('\r', ' ').trim();
    }
}
