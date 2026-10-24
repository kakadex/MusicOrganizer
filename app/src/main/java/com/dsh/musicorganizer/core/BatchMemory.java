package com.dsh.musicorganizer.core;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStreamWriter;
import java.io.Writer;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * 批量任务的「记忆」：记住每首歌上次查到什么，下一批直接跳过没戏的、已写完的。
 *
 * <p>解决两个真实痛点：
 * <ol>
 *   <li><b>重复获取</b>：库里根本没有的歌，上一批查了 4 家源全是空，下一批还要再查 4 家 ——
 *       一批 500 首里这种歌能占三成，白烧时间和配额。</li>
 *   <li><b>中断后从头来</b>：任务被系统杀掉、或用户点停止，下一批全部重新匹配。
 *       有了记忆，已写完的和已确认查不到的都跳过，只补剩下的。</li>
 * </ol>
 *
 * <p>判定键是 {@code docId}，并附带 {@code size + mtime} 指纹 —— 文件被替换/重新编码后
 * 指纹变了，旧结论自动失效，不会因为「上次没查到」就永远不给它查。
 *
 * <p>落盘格式是一份 JSON（{@code filesDir/batches/<kind>.json"}），不引 SQLite / Room：
 * 条目只是「键 + 三个数字 + 一个状态」，几千条也就几百 KB，一次读写足够快。
 */
public final class BatchMemory {

    /** 所有源都没有结果（下次不必再查）。 */
    public static final String NO_HIT = "nohit";
    /** 有结果但被质量校验/防配错拦下（下次也不必再查）。 */
    public static final String REJECTED = "reject";
    /** 已成功写入（下次直接跳过）。 */
    public static final String DONE = "done";

    /** 单份记忆最多保留的条目数，超出按时间淘汰最旧。 */
    private static final int MAX_ENTRIES = 20000;
    /** 每记录这么多条就落盘一次：进程被杀时最多丢几十条结论。 */
    private static final int SAVE_EVERY = 40;

    private final File file;
    private final String kind;
    private final Object lock = new Object();
    private final Map<String, Entry> entries = new LinkedHashMap<String, Entry>();
    private int unsaved = 0;
    private int savedSkips = 0;

    /** 「忽略已有记忆，这一轮全部重新联网查询」（设置页开关，见 setIgnoreExisting）。 */
    private boolean ignoreExisting = false;

    /** 一条记忆。 */
    public static final class Entry {
        public long size;
        public long mtime;
        public String status = NO_HIT;
        public long ts;

        public boolean sameFile(long size, long mtime) {
            // mtime 为 0 表示取不到（个别 SAF provider），此时只比大小
            return this.size == size && (this.mtime == 0 || mtime == 0 || this.mtime == mtime);
        }
    }

    private BatchMemory(File file, String kind) {
        this.file = file;
        this.kind = kind;
        load();
    }

    /** 打开（或创建）某类任务的记忆；{@code dir} 通常是 {@code filesDir/batches}。 */
    public static BatchMemory open(File dir, String kind) {
        if (dir != null && !dir.isDirectory()) {
            //noinspection ResultOfMethodCallIgnored
            dir.mkdirs();
        }
        return new BatchMemory(dir == null ? null : new File(dir, kind + ".json"), kind);
    }

    public File file() {
        return file;
    }

    public String kind() {
        return kind;
    }

    // ------------------------------------------------------------------
    // 查询 / 记录
    // ------------------------------------------------------------------

    /**
     * 忽略已有记忆：{@link #shouldSkip} 一律返回 false，但新结论照常记录。
     *
     * <p>给「前面跳过的歌，现在想重新联网查一遍」用。和 {@link #clear()} 的区别是：
     * 只影响这一轮，查完的新结论会正常写回，下一次仍然能享受增量。
     */
    public void setIgnoreExisting(boolean ignore) {
        this.ignoreExisting = ignore;
    }

    public boolean ignoreExisting() {
        return ignoreExisting;
    }

    /** 这首歌上次的结论是否还能用（文件没变、且状态是「查不到 / 被拦 / 已写入」）。 */
    public boolean shouldSkip(String key, long size, long mtime) {
        if (key == null || key.isEmpty()) {
            return false;
        }
        if (ignoreExisting) {
            return false; // 用户要求这轮全部重查
        }
        synchronized (lock) {
            Entry e = entries.get(key);
            if (e == null || !e.sameFile(size, mtime)) {
                return false;
            }
            if (savedSkips < Integer.MAX_VALUE) {
                savedSkips++;
            }
            return NO_HIT.equals(e.status) || REJECTED.equals(e.status) || DONE.equals(e.status);
        }
    }

    public String statusOf(String key, long size, long mtime) {
        synchronized (lock) {
            Entry e = entries.get(key);
            return e != null && e.sameFile(size, mtime) ? e.status : "";
        }
    }

    /** 记下结论（会周期性落盘）。 */
    public void record(String key, long size, long mtime, String status) {
        if (key == null || key.isEmpty() || status == null) {
            return;
        }
        boolean due;
        synchronized (lock) {
            Entry e = entries.get(key);
            if (e == null) {
                e = new Entry();
                entries.put(key, e);
            }
            e.size = size;
            e.mtime = mtime;
            e.status = status;
            e.ts = System.currentTimeMillis();
            trimLocked();
            due = ++unsaved >= SAVE_EVERY;
            if (due) {
                unsaved = 0;
            }
        }
        if (due) {
            save();
        }
    }

    /** 这首歌已经写好了（下次整批跳过）。 */
    public void markDone(String key, long size, long mtime) {
        record(key, size, mtime, DONE);
    }

    /** 本次运行里「靠记忆省下来的查询次数」。 */
    public int skipCount() {
        synchronized (lock) {
            return savedSkips;
        }
    }

    public int size() {
        synchronized (lock) {
            return entries.size();
        }
    }

    public int countOf(String status) {
        synchronized (lock) {
            int n = 0;
            for (Entry e : entries.values()) {
                if (status.equals(e.status)) {
                    n++;
                }
            }
            return n;
        }
    }

    /** 「记忆 1200 首（无结果 800 / 被拦 100 / 已写入 300）」——界面上显示用。 */
    public String summary() {
        int total = size();
        if (total == 0) {
            return "还没有匹配记忆";
        }
        return "记忆 " + total + " 首（无结果 " + countOf(NO_HIT)
                + " / 被拦 " + countOf(REJECTED)
                + " / 已写入 " + countOf(DONE) + "）";
    }

    public void clear() {
        synchronized (lock) {
            entries.clear();
            unsaved = 0;
        }
        save();
    }

    /**
     * 忘掉一首歌的结论 —— 用户选择「重新联网查询」时逐首调用。
     *
     * <p>只删这一首，其它歌的记忆不受影响：不必为了重查几首把整份记忆清空
     * （那会让下一次批量又把几万首重新查一遍）。
     *
     * @return 原来有没有这条记忆
     */
    public boolean forget(String key) {
        if (key == null || key.isEmpty()) {
            return false;
        }
        boolean removed;
        synchronized (lock) {
            removed = entries.remove(key) != null;
            if (removed) {
                unsaved = 0;
            }
        }
        if (removed) {
            save();
        }
        return removed;
    }

    /** 批量忘掉（「重新查询这 N 首」）；返回实际删掉的条数。 */
    public int forgetAll(List<String> keys) {
        if (keys == null || keys.isEmpty()) {
            return 0;
        }
        int removed = 0;
        synchronized (lock) {
            for (String key : keys) {
                if (key != null && !key.isEmpty() && entries.remove(key) != null) {
                    removed++;
                }
            }
            if (removed > 0) {
                unsaved = 0;
            }
        }
        if (removed > 0) {
            save();
        }
        return removed;
    }

    /** 删掉所有条目并把文件本身删掉（界面「清除记忆」用）。 */
    public void delete() {
        synchronized (lock) {
            entries.clear();
            unsaved = 0;
        }
        if (file != null) {
            //noinspection ResultOfMethodCallIgnored
            file.delete();
        }
    }

    private void trimLocked() {
        if (entries.size() <= MAX_ENTRIES) {
            return;
        }
        // 按时间从旧到新淘汰（LinkedHashMap 的迭代顺序够用，不必精确排序）
        Iterator<Map.Entry<String, Entry>> it = entries.entrySet().iterator();
        int drop = entries.size() - MAX_ENTRIES;
        while (it.hasNext() && drop > 0) {
            it.next();
            it.remove();
            drop--;
        }
    }

    // ------------------------------------------------------------------
    // 落盘 / 读取
    // ------------------------------------------------------------------

    /** 立即落盘（任务结束、或记录满 SAVE_EVERY 条时调用）。 */
    public boolean save() {
        if (file == null) {
            return false;
        }
        String text;
        synchronized (lock) {
            StringBuilder sb = new StringBuilder(256 + entries.size() * 96);
            sb.append("{\n  \"version\": 1,\n  \"kind\": ").append(Json.quote(kind))
                    .append(",\n  \"updatedAt\": ")
                    .append(Json.quote(new SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US)
                            .format(new Date())))
                    .append(",\n  \"entries\": {");
            boolean first = true;
            for (Map.Entry<String, Entry> e : entries.entrySet()) {
                Entry v = e.getValue();
                sb.append(first ? "\n" : ",\n");
                first = false;
                sb.append("    ").append(Json.quote(e.getKey())).append(": {\"s\": ")
                        .append(v.size).append(", \"m\": ").append(v.mtime)
                        .append(", \"st\": ").append(Json.quote(v.status))
                        .append(", \"t\": ").append(v.ts).append('}');
            }
            sb.append(first ? "}\n}\n" : "\n  }\n}\n");
            text = sb.toString();
        }
        return writeAtomic(file, text);
    }

    /** 原子写：先写 .tmp 再改名，避免写一半被杀留下半个 JSON。 */
    static boolean writeAtomic(File target, String text) {
        File tmp = new File(target.getParentFile(), target.getName() + ".tmp");
        Writer w = null;
        try {
            w = new OutputStreamWriter(new FileOutputStream(tmp), "UTF-8");
            w.write(text);
            w.flush();
            w.close();
            w = null;
            // 先直接改名（多数情况下可覆盖）；不行再删掉旧文件重试
            if (tmp.renameTo(target)) {
                return true;
            }
            //noinspection ResultOfMethodCallIgnored
            target.delete();
            return tmp.renameTo(target);
        } catch (IOException e) {
            return false;
        } finally {
            if (w != null) {
                try {
                    w.close();
                } catch (IOException ignored) {
                }
            }
            if (tmp.exists()) {
                //noinspection ResultOfMethodCallIgnored
                tmp.delete();
            }
        }
    }

    @SuppressWarnings("unchecked")
    private void load() {
        if (file == null || !file.isFile() || file.length() == 0) {
            return;
        }
        String text;
        try {
            byte[] buf = new byte[(int) Math.min(file.length(), 8L * 1024 * 1024)];
            java.io.FileInputStream in = new java.io.FileInputStream(file);
            try {
                int off = 0;
                while (off < buf.length) {
                    int n = in.read(buf, off, buf.length - off);
                    if (n < 0) {
                        break;
                    }
                    off += n;
                }
                text = new String(buf, 0, off, "UTF-8");
            } finally {
                in.close();
            }
        } catch (IOException e) {
            return;
        }
        Object root = Json.parseOrNull(text);
        if (!(root instanceof Map)) {
            return;
        }
        Object raw = ((Map<String, Object>) root).get("entries");
        if (!(raw instanceof Map)) {
            return;
        }
        synchronized (lock) {
            entries.clear();
            for (Map.Entry<String, Object> e : ((Map<String, Object>) raw).entrySet()) {
                if (!(e.getValue() instanceof Map)) {
                    continue;
                }
                Map<String, Object> node = (Map<String, Object>) e.getValue();
                Entry en = new Entry();
                en.size = asLong(node.get("s"));
                en.mtime = asLong(node.get("m"));
                Object st = node.get("st");
                en.status = st == null ? NO_HIT : String.valueOf(st);
                en.ts = asLong(node.get("t"));
                entries.put(e.getKey(), en);
            }
        }
    }

    private static long asLong(Object v) {
        if (v instanceof Number) {
            return ((Number) v).longValue();
        }
        if (v != null) {
            try {
                return (long) Double.parseDouble(String.valueOf(v));
            } catch (NumberFormatException ignored) {
            }
        }
        return 0;
    }

    /** 供预览/日志用：把「本次跳过」的说明拼成一句。 */
    public String skipNote() {
        int n = skipCount();
        return n <= 0 ? "" : "按记忆跳过 " + n + " 首（上批已确认无结果或已写入）";
    }

    /** 导出所有键（测试与排查用）。 */
    public List<String> keys() {
        synchronized (lock) {
            return new ArrayList<String>(entries.keySet());
        }
    }
}
