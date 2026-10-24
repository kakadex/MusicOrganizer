package com.dsh.musicorganizer.core;

import android.content.Context;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * 标签事务日志 —— 对应 Python 版 tag_journal.jsonl（简化：不做轮转，保留近 2000 条）。
 */
public final class Journal {

    private Journal() {
    }

    public static class Entry {
        public String id = "";
        public String timestamp = "";
        public String uri = "";
        public String batchId = "";
        public Map<String, String> before = new HashMap<String, String>();
        public Map<String, String> after = new HashMap<String, String>();
        public String status = "applied";
        public String targetId = "";
        /** 文件名（仅用于撤销历史列表展示；旧记录为空时从 uri 推导）。 */
        public String name = "";
    }

    private static File file(Context ctx) {
        return new File(ctx.getFilesDir(), "tag_journal.jsonl");
    }

    public static synchronized boolean append(Context ctx, Entry entry) {
        try {
            List<Entry> all = readAll(ctx);
            all.add(entry);
            while (all.size() > 2000) {
                all.remove(0);
            }
            StringBuilder sb = new StringBuilder();
            for (Entry e : all) {
                sb.append(toJson(e).toString()).append('\n');
            }
            OutputStreamWriter w = new OutputStreamWriter(
                    new java.io.FileOutputStream(file(ctx), false), StandardCharsets.UTF_8);
            w.write(sb.toString());
            w.close();
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    public static synchronized List<Entry> readAll(Context ctx) {
        List<Entry> out = new ArrayList<Entry>();
        File f = file(ctx);
        if (!f.exists()) {
            return out;
        }
        BufferedReader r = null;
        try {
            r = new BufferedReader(new InputStreamReader(
                    new FileInputStream(f), StandardCharsets.UTF_8));
            String line;
            while ((line = r.readLine()) != null) {
                line = line.trim();
                if (line.isEmpty()) {
                    continue;
                }
                try {
                    out.add(fromJson(new JSONObject(line)));
                } catch (Exception ignored) {
                }
            }
        } catch (Exception ignored) {
        } finally {
            if (r != null) {
                try {
                    r.close();
                } catch (Exception ignored) {
                }
            }
        }
        return out;
    }

    /** 最近一个可撤销的 applied 记录。 */
    public static Entry findLastApplied(Context ctx) {
        List<Entry> all = readAll(ctx);
        Set<String> reverted = new HashSet<String>();
        for (Entry e : all) {
            if ("reverted".equals(e.status) && !e.targetId.isEmpty()) {
                reverted.add(e.targetId);
            }
        }
        for (int i = all.size() - 1; i >= 0; i--) {
            Entry e = all.get(i);
            if ("applied".equals(e.status) && !reverted.contains(e.id)) {
                return e;
            }
        }
        return null;
    }

    /** 扁平记录 → 批次视图用的行（纯数据，不碰 Android）。 */
    public static List<JournalHistory.Row> rows(Context ctx) {
        List<JournalHistory.Row> out = new ArrayList<JournalHistory.Row>();
        for (Entry e : readAll(ctx)) {
            out.add(row(e));
        }
        return out;
    }

    /** 可撤销的批次（按时间倒序，最多 limit 个）。 */
    public static List<JournalHistory.Batch> batches(Context ctx, int limit) {
        return JournalHistory.build(rows(ctx), limit);
    }

    /** 某批次（{@link JournalHistory#keyOf} 的键）里还能撤销的记录，保持写入顺序。 */
    public static List<Entry> targets(Context ctx, String key) {
        List<Entry> out = new ArrayList<Entry>();
        if (key == null || key.isEmpty()) {
            return out;
        }
        List<Entry> all = readAll(ctx);
        Set<String> reverted = new HashSet<String>();
        for (Entry e : all) {
            if ("reverted".equals(e.status) && !e.targetId.isEmpty()) {
                reverted.add(e.targetId);
            }
        }
        for (Entry e : all) {
            if (!"applied".equals(e.status) || reverted.contains(e.id)) {
                continue;
            }
            if (key.equals(JournalHistory.keyOf(row(e)))) {
                out.add(e);
            }
        }
        return out;
    }

    private static JournalHistory.Row row(Entry e) {
        JournalHistory.Row r = new JournalHistory.Row();
        r.id = e.id;
        r.timestamp = e.timestamp;
        r.uri = e.uri;
        r.batchId = e.batchId;
        r.status = e.status;
        r.targetId = e.targetId;
        r.name = e.name;
        return r;
    }

    private static JSONObject toJson(Entry e) {
        try {
            JSONObject o = new JSONObject();
            o.put("id", e.id);
            o.put("timestamp", e.timestamp);
            o.put("uri", e.uri);
            o.put("batchId", e.batchId);
            o.put("before", new JSONObject(e.before));
            o.put("after", new JSONObject(e.after));
            o.put("status", e.status);
            o.put("targetId", e.targetId);
            o.put("name", e.name);
            return o;
        } catch (Exception ex) {
            return new JSONObject();
        }
    }

    private static Entry fromJson(JSONObject o) {
        Entry e = new Entry();
        e.id = o.optString("id", "");
        e.timestamp = o.optString("timestamp", "");
        e.uri = o.optString("uri", "");
        e.batchId = o.optString("batchId", "");
        e.status = o.optString("status", "applied");
        e.targetId = o.optString("targetId", "");
        e.name = o.optString("name", "");
        if (e.name.isEmpty()) {
            e.name = JournalHistory.nameFromUri(e.uri);
        }
        JSONObject before = o.optJSONObject("before");
        if (before != null) {
            for (String k : Tags.KEYS) {
                e.before.put(k, before.optString(k, ""));
            }
        }
        JSONObject after = o.optJSONObject("after");
        if (after != null) {
            for (String k : Tags.KEYS) {
                e.after.put(k, after.optString(k, ""));
            }
        }
        return e;
    }
}
