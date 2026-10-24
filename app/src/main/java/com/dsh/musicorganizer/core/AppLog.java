package com.dsh.musicorganizer.core;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStreamWriter;
import java.io.Writer;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;

/**
 * 结构化持久化日志（纯 Java、零第三方依赖）：
 *
 * <p>此前日志只是内存里的一个 ListView：闪退、切后台被回收、或者用户手点「清空」，
 * 证据就没了 —— 而用户反馈问题时最需要的恰恰是「出事前那几十行」。
 * 这里做三件事：<b>分级</b>（DEBUG/INFO/WARN/ERROR）、<b>按天落盘</b>、<b>可导出</b>。
 *
 * <p>实现上刻意保持「纯 Java + 单写线程」：
 * <ul>
 *   <li>写盘不在调用线程做（日志调用点常在主线程），投递到有界队列由独立守护线程合并写；</li>
 *   <li>队列满时丢最旧的，绝不阻塞业务线程；</li>
 *   <li>崩溃路径用 {@link #writeSync} 落盘后再放行，保证最后一条一定在文件里。</li>
 * </ul>
 * 不依赖 Android，所以能在纯 JVM 里跑回归（{@code tools/AppLogTest}）。
 */
public final class AppLog {

    private AppLog() {
    }

    public static final int DEBUG = 0;
    public static final int INFO = 1;
    public static final int WARN = 2;
    public static final int ERROR = 3;

    /** 保留天数：超过的按文件名日期清理。 */
    public static final int KEEP_DAYS = 7;
    /** 单条消息上限，防止把整个堆栈塞成一行巨型日志。 */
    private static final int MAX_MESSAGE = 2000;
    /** 待写队列上限；满了丢最旧的（宁可丢日志，不可卡业务）。 */
    private static final int QUEUE_MAX = 4096;
    /** 导出时最多取这么多字符（约 2MB），再多用户也读不完。 */
    public static final int EXPORT_MAX_CHARS = 400 * 1024;

    private static final String PREFIX = "app-";
    private static final String SUFFIX = ".log";

    private static final LinkedBlockingQueue<Item> QUEUE = new LinkedBlockingQueue<Item>(QUEUE_MAX);
    private static final Object IO_LOCK = new Object();

    private static volatile File dir;
    private static volatile int minLevel = DEBUG;
    private static volatile Thread writer;

    /** 一条待写日志；done != null 时表示「写完请放行」（用于 flush / 崩溃落盘）。 */
    private static final class Item {
        final int level;
        final String tag;
        final String message;
        final CountDownLatch done;

        Item(int level, String tag, String message, CountDownLatch done) {
            this.level = level;
            this.tag = tag;
            this.message = message;
            this.done = done;
        }
    }

    /** 指定日志目录（通常是 {@code filesDir/logs}）；同时清理过期文件。 */
    public static void install(File logDir) {
        dir = logDir;
        if (logDir != null && !logDir.exists()) {
            //noinspection ResultOfMethodCallIgnored
            logDir.mkdirs();
        }
        prune(KEEP_DAYS);
    }

    public static File dir() {
        return dir;
    }

    /** 低于该级别的日志丢弃（默认 DEBUG，即全收）。 */
    public static void setMinLevel(int level) {
        minLevel = level;
    }

    public static String levelName(int level) {
        switch (level) {
            case ERROR:
                return "ERROR";
            case WARN:
                return "WARN";
            case INFO:
                return "INFO";
            default:
                return "DEBUG";
        }
    }

    /** 把界面/业务里用惯的字符串级别（info / warning / error / success）映到数值级别。 */
    public static int levelOf(String level) {
        if (level == null) {
            return INFO;
        }
        String s = level.trim().toLowerCase(Locale.US);
        if ("error".equals(s) || "fatal".equals(s)) {
            return ERROR;
        }
        if ("warning".equals(s) || "warn".equals(s)) {
            return WARN;
        }
        if ("debug".equals(s)) {
            return DEBUG;
        }
        // info / success 都按 INFO：成功信息没有单独的检索价值
        return INFO;
    }

    // ------------------------------------------------------------------
    // 写入
    // ------------------------------------------------------------------

    /** 异步写一条。永不抛异常、永不阻塞（队列满时丢最旧）。 */
    public static void write(int level, String tag, String message) {
        if (dir == null || level < minLevel) {
            return;
        }
        ensureWriter();
        offer(new Item(level, tag, message, null));
    }

    /** 同步写一条（崩溃兜底用）：等它真正落盘再返回。 */
    public static void writeSync(int level, String tag, String message) {
        if (dir == null) {
            return;
        }
        ensureWriter();
        CountDownLatch latch = new CountDownLatch(1);
        offer(new Item(level, tag, message, latch));
        try {
            latch.await(1500, TimeUnit.MILLISECONDS);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    /** 等队列里的日志全部落盘（导出前调用，避免导出少最后几行）。 */
    public static boolean flush(long timeoutMs) {
        if (dir == null) {
            return false;
        }
        ensureWriter();
        CountDownLatch latch = new CountDownLatch(1);
        if (!offer(new Item(-1, null, null, latch))) {
            return false;
        }
        try {
            return latch.await(timeoutMs, TimeUnit.MILLISECONDS);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return false;
        }
    }

    private static boolean offer(Item item) {
        if (!QUEUE.offer(item)) {
            QUEUE.poll(); // 丢最旧
            return QUEUE.offer(item);
        }
        return true;
    }

    private static void ensureWriter() {
        if (writer != null) {
            return;
        }
        synchronized (IO_LOCK) {
            if (writer != null) {
                return;
            }
            Thread t = new Thread(new Runnable() {
                @Override
                public void run() {
                    loop();
                }
            }, "applog");
            t.setDaemon(true);
            writer = t;
            t.start();
        }
    }

    private static void loop() {
        SimpleDateFormat stamp = new SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US);
        SimpleDateFormat day = new SimpleDateFormat("yyyy-MM-dd", Locale.US);
        List<Item> batch = new ArrayList<Item>(64);
        while (true) {
            try {
                Item first = QUEUE.poll(1, TimeUnit.SECONDS);
                if (first == null) {
                    continue;
                }
                batch.clear();
                batch.add(first);
                QUEUE.drainTo(batch, 255);
                StringBuilder sb = new StringBuilder();
                for (Item it : batch) {
                    if (it.message != null) {
                        sb.append(stamp.format(new Date()))
                                .append(' ').append(pad(it.level))
                                .append('[').append(it.tag == null ? "app" : it.tag).append("] ")
                                .append(flatten(it.message))
                                .append('\n');
                    }
                }
                if (sb.length() > 0) {
                    append(day.format(new Date()), sb.toString());
                }
                for (Item it : batch) {
                    if (it.done != null) {
                        it.done.countDown();
                    }
                }
            } catch (InterruptedException e) {
                return;
            } catch (Throwable t) {
                // 写日志失败绝不能反过来影响业务
                for (Item it : batch) {
                    if (it.done != null) {
                        it.done.countDown();
                    }
                }
                batch.clear();
            }
        }
    }

    /** 级别名补到 5 个字符，让导出文件里各列对齐（纯美观，便于贴进反馈）。 */
    private static String pad(int level) {
        String name = levelName(level);
        while (name.length() < 5) {
            name = name + ' ';
        }
        return name;
    }

    /** 多行消息压成「首行 + 缩进续行」，避免一条日志把整个文件撑烂。 */
    private static String flatten(String message) {
        String msg = message.length() > MAX_MESSAGE ? message.substring(0, MAX_MESSAGE) + "…" : message;
        return msg.replace("\r\n", "\n").replace('\r', '\n').replace("\n", "\n    ");
    }

    private static void append(String day, String text) throws IOException {
        File d = dir;
        if (d == null) {
            return;
        }
        if (!d.exists()) {
            //noinspection ResultOfMethodCallIgnored
            d.mkdirs();
        }
        File f = new File(d, PREFIX + day + SUFFIX);
        synchronized (IO_LOCK) {
            Writer w = null;
            try {
                w = new OutputStreamWriter(new FileOutputStream(f, true), "UTF-8");
                w.write(text);
            } finally {
                if (w != null) {
                    w.close();
                }
            }
        }
    }

    // ------------------------------------------------------------------
    // 读取 / 导出 / 清理
    // ------------------------------------------------------------------

    /** 现有日志文件，按日期从旧到新。 */
    public static List<File> files() {
        List<File> out = new ArrayList<File>();
        File d = dir;
        if (d == null || !d.isDirectory()) {
            return out;
        }
        File[] all = d.listFiles();
        if (all == null) {
            return out;
        }
        for (File f : all) {
            if (f.isFile() && f.getName().startsWith(PREFIX) && f.getName().endsWith(SUFFIX)) {
                out.add(f);
            }
        }
        java.util.Collections.sort(out, new Comparator<File>() {
            @Override
            public int compare(File a, File b) {
                return a.getName().compareTo(b.getName());
            }
        });
        return out;
    }

    /** 「3 个文件 / 96 KB」，给界面显示用。 */
    public static String stats() {
        List<File> list = files();
        long bytes = 0;
        for (File f : list) {
            bytes += f.length();
        }
        return list.size() + " 个文件 / " + humanSize(bytes);
    }

    public static String humanSize(long bytes) {
        if (bytes < 1024) {
            return bytes + " B";
        }
        if (bytes < 1024 * 1024) {
            return (bytes / 1024) + " KB";
        }
        return String.format(Locale.US, "%.1f MB", bytes / 1024.0 / 1024.0);
    }

    /**
     * 生成可直接贴进反馈的文本：{@code header} + 最近若干天的日志（超出上限从头截断）。
     */
    public static String exportText(String header, int maxChars) {
        flush(2000);
        List<File> list = files();
        StringBuilder body = new StringBuilder();
        for (int i = list.size() - 1; i >= 0; i--) {
            String text = readAll(list.get(i));
            if (text.isEmpty()) {
                continue;
            }
            if (body.length() + text.length() > maxChars) {
                int room = maxChars - body.length();
                if (room > 0) {
                    body.insert(0, text.substring(Math.max(0, text.length() - room)));
                }
                body.insert(0, "…（更早的日志已省略）\n");
                break;
            }
            body.insert(0, text);
            if (body.length() >= maxChars) {
                break;
            }
        }
        StringBuilder sb = new StringBuilder();
        if (header != null && !header.isEmpty()) {
            sb.append(header).append('\n');
        }
        sb.append("---- 运行日志（共 ").append(list.size()).append(" 个文件，")
                .append(humanSize(body.length()))
                .append("，保留 ").append(KEEP_DAYS).append(" 天）----\n");
        if (body.length() == 0) {
            sb.append("（还没有日志）\n");
        } else {
            sb.append(body);
        }
        return sb.toString();
    }

    private static String readAll(File f) {
        synchronized (IO_LOCK) {
            byte[] buf;
            try {
                long len = f.length();
                if (len <= 0) {
                    return "";
                }
                buf = new byte[(int) Math.min(len, 4L * 1024 * 1024)];
                java.io.FileInputStream in = new java.io.FileInputStream(f);
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
                    in.close();
                }
            } catch (IOException e) {
                return "";
            }
        }
    }

    /** 删除超过 {@code keepDays} 天的日志文件（按文件名里的日期判断）。 */
    public static int prune(int keepDays) {
        if (keepDays <= 0) {
            return 0;
        }
        long cutoff = System.currentTimeMillis() - keepDays * 24L * 3600L * 1000L;
        SimpleDateFormat fmt = new SimpleDateFormat("yyyy-MM-dd", Locale.US);
        int removed = 0;
        for (File f : files()) {
            String name = f.getName().substring(PREFIX.length(), f.getName().length() - SUFFIX.length());
            long t;
            try {
                t = fmt.parse(name).getTime();
            } catch (Exception e) {
                continue;
            }
            // 当天文件保留（cutoff 对齐到天，避免刚写的被删）
            if (t < cutoff - 24L * 3600L * 1000L) {
                if (f.delete()) {
                    removed++;
                }
            }
        }
        return removed;
    }

    /** 清空所有已落盘的日志（界面「清空」时连文件一起清，否则导出又把旧日志带回来）。 */
    public static int clearFiles() {
        int removed = 0;
        for (File f : files()) {
            if (f.delete()) {
                removed++;
            }
        }
        return removed;
    }

    /** 测试与调试用：当前待写队列长度。 */
    public static int pending() {
        return QUEUE.size();
    }

    /** 便捷：把多个异常堆栈拼成一段文本。 */
    public static String stackTrace(Throwable t) {
        if (t == null) {
            return "";
        }
        java.io.StringWriter sw = new java.io.StringWriter();
        t.printStackTrace(new java.io.PrintWriter(sw));
        return sw.toString();
    }

    /** 只保留最新的 N 个文件（按总量兜底，防止某天刷爆）。 */
    public static int trimToFiles(int maxFiles) {
        List<File> list = files();
        int removed = 0;
        while (list.size() > maxFiles) {
            File f = list.remove(0);
            if (f.delete()) {
                removed++;
            }
        }
        return removed;
    }

    /** 调试：列出文件名（测试断言用）。 */
    public static List<String> fileNames() {
        List<String> out = new ArrayList<String>();
        for (File f : files()) {
            out.add(f.getName());
        }
        return out;
    }
}
