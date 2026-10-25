package com.dsh.musicorganizer.core;

import java.io.File;
import java.io.FileInputStream;
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
 * 批量匹配的<b>中间态</b>落库：把每条已经匹配到、但还没写盘的结果存下来。
 *
 * <p>和 {@link BatchMemory} 的分工要分清，两者解决的不是一个问题：
 * <ul>
 *   <li>{@code BatchMemory} 记的是<b>结论</b>：「查不到 / 被拦 / 已写入」——下次整批直接跳过，省一次查询。</li>
 *   <li>{@code MatchQueue} 记的是<b>待办</b>：「这条已经匹配好了，字段是这些，还没写进文件」——
 *       进程被杀、用户切走导致后台回收、或者点了停止，重启后可以直接接着写，
 *       <b>不必重新联网查一遍</b>。</li>
 * </ul>
 *
 * <p>为什么这件事值得单独存一份：一次 500 首的批量匹配，网络好的时候也要几分钟；
 * 匹配完还没开始写，进程被系统回收就全白费 —— 而用户看到的是「跑完了但文件没变」。
 * 中间态落库后，最坏情况也只需要重新点一次「写入」。
 *
 * <p>指纹（{@code size + mtime}）与 {@code BatchMemory} 同语义：文件被替换/重新编码后
 * 旧结果自动作废，不会把过期字段写进新文件。
 *
 * <p>存储是一份 JSON（{@code filesDir/batches/queue-<kind>.json}），零依赖、原子写，
 * 进程被杀最多丢最后几十条。
 */
public final class MatchQueue {

    /** 已匹配、尚未写入。 */
    public static final String PENDING = "pending";
    /** 已写入文件。 */
    public static final String WRITTEN = "written";
    /** 用户没勾选（主动跳过）。 */
    public static final String SKIPPED = "skipped";
    /** 写入失败（下次重新匹配）。 */
    public static final String FAILED = "failed";

    /** 单份队列最多留这么多条：再多说明用户攒了好几批没写完，旧的先让位。 */
    private static final int MAX_ENTRIES = 6000;
    /** 每写这么多条落盘一次（并发 worker 共用同一份队列）。 */
    private static final int SAVE_EVERY = 30;
    /** 超过这么多天的中间态直接作废：半个月前的匹配结果，源站多半已经变了。 */
    private static final long EXPIRE_MS = 14L * 24 * 3600 * 1000;

    private final File file;
    private final String kind;
    private final Object lock = new Object();
    private final Map<String, Item> items = new LinkedHashMap<String, Item>();
    private int unsaved = 0;

    /** 一条中间态。 */
    public static final class Item {
        /** 与 {@link BatchMemory} 同键：docId（无 docId 时用文件名）。 */
        public String key = "";
        public long size;
        public long mtime;
        public String status = PENDING;
        public long ts;
        /** 匹配到的字段（标签字段 / 歌词正文 / 封面地址，按 kind 不同而不同）。 */
        public final Map<String, String> fields = new LinkedHashMap<String, String>();

        public boolean sameFile(long size, long mtime) {
            // mtime 取不到（个别 SAF provider 给 0）时只比大小
            return this.size == size && (this.mtime == 0 || mtime == 0 || this.mtime == mtime);
        }

        public String field(String name, String def) {
            String v = fields.get(name);
            return v == null ? def : v;
        }

        public boolean isPending() {
            return PENDING.equals(status);
        }
    }

    private MatchQueue(File file, String kind) {
        this.file = file;
        this.kind = kind;
        load();
    }

    /**
     * 打开某类任务的中间态队列；{@code dir} 通常是 {@code filesDir/batches}。
     *
     * <p>文件名带 {@code queue-} 前缀，避免和同目录下 {@link BatchMemory} 的
     * {@code <kind>.json} 撞名 —— 撞了就是两种语义互相覆盖。
     */
    public static MatchQueue open(File dir, String kind) {
        if (dir != null && !dir.isDirectory()) {
            //noinspection ResultOfMethodCallIgnored
            dir.mkdirs();
        }
        String safe = kind == null || kind.isEmpty() ? "misc" : kind;
        return new MatchQueue(dir == null ? null : new File(dir, "queue-" + safe + ".json"), safe);
    }

    public File file() {
        return file;
    }

    public String kind() {
        return kind;
    }

    // ------------------------------------------------------------------
    // 读写
    // ------------------------------------------------------------------

    /**
     * 取一条可续跑的中间态：指纹一致、且状态是 pending。
     *
     * <p>指纹对不上就地删掉 —— 文件已经换了，旧字段继续留着只会误导下一次批量。
     * 返回值是副本，调用方随便改，不会污染队列（要更新请走 {@link #put}）。
     */
    public Item take(String key, long size, long mtime) {
        if (key == null || key.isEmpty()) {
            return null;
        }
        synchronized (lock) {
            Item e = items.get(key);
            if (e == null) {
                return null;
            }
            if (!e.sameFile(size, mtime)) {
                items.remove(key);
                unsaved++;
                return null;
            }
            if (!e.isPending()) {
                return null;
            }
            return copy(e);
        }
    }

    /** 记下一条刚匹配好的结果（同键覆盖）。 */
    public void put(String key, long size, long mtime, Map<String, String> fields) {
        if (key == null || key.isEmpty()) {
            return;
        }
        boolean due;
        synchronized (lock) {
            Item e = new Item();
            e.key = key;
            e.size = size;
            e.mtime = mtime;
            e.status = PENDING;
            e.ts = System.currentTimeMillis();
            if (fields != null) {
                for (Map.Entry<String, String> f : fields.entrySet()) {
                    if (f.getKey() != null && f.getValue() != null) {
                        e.fields.put(f.getKey(), f.getValue());
                    }
                }
            }
            items.put(key, e);
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

    /** 改状态（写入成功 / 跳过 / 失败）。 */
    public void mark(String key, String status) {
        if (key == null || key.isEmpty() || status == null) {
            return;
        }
        synchronized (lock) {
            Item e = items.get(key);
            if (e == null) {
                return;
            }
            e.status = status;
            e.ts = System.currentTimeMillis();
        }
        save();
    }

    /** 还等着写入的条数。 */
    public int countPending() {
        return countOf(PENDING);
    }

    public int countOf(String status) {
        synchronized (lock) {
            int n = 0;
            for (Item e : items.values()) {
                if (status == null ? e.status == null : status.equals(e.status)) {
                    n++;
                }
            }
            return n;
        }
    }

    /** 清掉已收尾的条目（写入成功 / 跳过 / 失败），只留 pending。 */
    public void clearFinished() {
        synchronized (lock) {
            Iterator<Map.Entry<String, Item>> it = items.entrySet().iterator();
            while (it.hasNext()) {
                if (!it.next().getValue().isPending()) {
                    it.remove();
                }
            }
        }
        save();
    }

    public void clear() {
        synchronized (lock) {
            items.clear();
            unsaved = 0;
        }
        save();
    }

    /** 删掉文件本身（设置页「清除记忆」连中间态一起清）。 */
    public void delete() {
        synchronized (lock) {
            items.clear();
            unsaved = 0;
        }
        if (file != null) {
            //noinspection ResultOfMethodCallIgnored
            file.delete();
        }
    }

    /** 一句话摘要（设置页展示用）。 */
    public String summary() {
        int pending = countPending();
        if (pending == 0) {
            return "无待写入";
        }
        return pending + " 首待写入（可从中断处继续）";
    }

    /** 待写入的键列表（顺序即写入顺序）。 */
    public List<String> pendingKeys() {
        List<String> out = new ArrayList<String>();
        synchronized (lock) {
            for (Item e : items.values()) {
                if (e.isPending()) {
                    out.add(e.key);
                }
            }
        }
        return out;
    }

    private static Item copy(Item src) {
        Item out = new Item();
        out.key = src.key;
        out.size = src.size;
        out.mtime = src.mtime;
        out.status = src.status;
        out.ts = src.ts;
        out.fields.putAll(src.fields);
        return out;
    }

    private void trimLocked() {
        if (items.size() <= MAX_ENTRIES) {
            return;
        }
        // 先扔已收尾的，再按插入顺序扔最旧的
        Iterator<Map.Entry<String, Item>> it = items.entrySet().iterator();
        while (it.hasNext() && items.size() > MAX_ENTRIES) {
            if (!it.next().getValue().isPending()) {
                it.remove();
            }
        }
        it = items.entrySet().iterator();
        while (it.hasNext() && items.size() > MAX_ENTRIES) {
            it.next();
            it.remove();
        }
    }

    // ------------------------------------------------------------------
    // 落盘 / 读取
    // ------------------------------------------------------------------

    public boolean save() {
        if (file == null) {
            return false;
        }
        String text;
        synchronized (lock) {
            StringBuilder sb = new StringBuilder(256 + items.size() * 160);
            sb.append("{\n  \"version\": 1,\n  \"kind\": ").append(Json.quote(kind))
                    .append(",\n  \"updatedAt\": ")
                    .append(Json.quote(new SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US)
                            .format(new Date())))
                    .append(",\n  \"items\": [");
            boolean first = true;
            for (Item e : items.values()) {
                sb.append(first ? "\n" : ",\n");
                first = false;
                sb.append("    {\"k\": ").append(Json.quote(e.key))
                        .append(", \"s\": ").append(e.size)
                        .append(", \"m\": ").append(e.mtime)
                        .append(", \"st\": ").append(Json.quote(e.status))
                        .append(", \"t\": ").append(e.ts)
                        .append(", \"f\": {");
                boolean f1 = true;
                for (Map.Entry<String, String> f : e.fields.entrySet()) {
                    sb.append(f1 ? "" : ", ");
                    f1 = false;
                    sb.append(Json.quote(f.getKey())).append(": ").append(Json.quote(f.getValue()));
                }
                sb.append("}}");
            }
            sb.append(first ? "]\n}\n" : "\n  ]\n}\n");
            text = sb.toString();
        }
        return BatchMemory.writeAtomic(file, text);
    }

    @SuppressWarnings("unchecked")
    private void load() {
        if (file == null || !file.isFile() || file.length() == 0) {
            return;
        }
        String text = readText(file);
        if (text == null) {
            return;
        }
        Object root = Json.parseOrNull(text);
        if (!(root instanceof Map)) {
            return;
        }
        Object list = ((Map<String, Object>) root).get("items");
        if (!(list instanceof List)) {
            return;
        }
        long now = System.currentTimeMillis();
        synchronized (lock) {
            for (Object o : (List<Object>) list) {
                if (!(o instanceof Map)) {
                    continue;
                }
                Map<String, Object> m = (Map<String, Object>) o;
                Item e = new Item();
                e.key = str(m.get("k"));
                if (e.key.isEmpty()) {
                    continue;
                }
                e.size = num(m.get("s"));
                e.mtime = num(m.get("m"));
                e.status = str(m.get("st"));
                if (e.status.isEmpty()) {
                    e.status = PENDING;
                }
                e.ts = num(m.get("t"));
                Object f = m.get("f");
                if (f instanceof Map) {
                    for (Map.Entry<String, Object> fe : ((Map<String, Object>) f).entrySet()) {
                        e.fields.put(fe.getKey(), str(fe.getValue()));
                    }
                }
                // 过期 / 空的直接丢：留着只会让下一次批量白跑一次 take()
                if (now - e.ts > EXPIRE_MS || e.fields.isEmpty()) {
                    continue;
                }
                items.put(e.key, e);
            }
        }
    }

    private static String readText(File f) {
        try {
            byte[] buf = new byte[(int) Math.min(f.length(), 8L * 1024 * 1024)];
            FileInputStream in = new FileInputStream(f);
            try {
                int off = 0;
                while (off < buf.length) {
                    int n = in.read(buf, off, buf.length - off);
                    if (n < 0) {
                        break;
                    }
                    off += n;
                }
                return new String(buf, 0, off, "UTF-8");
            } finally {
                try {
                    in.close();
                } catch (IOException ignored) {
                }
            }
        } catch (Exception e) {
            return null;
        }
    }

    private static String str(Object o) {
        return o == null ? "" : String.valueOf(o);
    }

    private static long num(Object o) {
        if (o instanceof Number) {
            return ((Number) o).longValue();
        }
        if (o != null) {
            try {
                return Long.parseLong(String.valueOf(o).trim());
            } catch (NumberFormatException ignored) {
            }
        }
        return 0;
    }

    /** 测试与「立即落盘」用：把当前未保存的改动写下去。 */
    public boolean flush() {
        return save();
    }

    /** 仅供测试：绕过文件直接构造（dir 为 null 时只在内存里）。 */
    static MatchQueue memoryOnly(String kind) {
        return new MatchQueue(null, kind);
    }
}
