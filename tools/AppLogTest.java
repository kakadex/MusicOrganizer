import com.dsh.musicorganizer.core.AppLog;

import java.io.File;
import java.io.FileWriter;

/**
 * 持久化日志回归测试（纯 JVM）。
 *
 * 覆盖：
 *   1. 落盘：写 → flush → 文件里能读到，且带时间戳与级别
 *   2. 级别过滤：低于 minLevel 的不写
 *   3. writeSync：崩溃路径不等 flush 也已落盘
 *   4. 多行消息缩进、超长消息截断
 *   5. 导出文本：带 header、带统计行、被清空后不乱
 *   6. 过期清理（prune）与清空文件
 */
public final class AppLogTest {

    private static int passed = 0;
    private static int failed = 0;
    private static File dir;

    public static void main(String[] args) throws Exception {
        dir = new File(System.getProperty("java.io.tmpdir"),
                "applog-test-" + System.nanoTime());
        AppLog.install(dir);

        basics();
        levelFilter();
        syncWrite();
        formatting();
        exportText();
        pruning();
        clearAll();

        System.out.println();
        System.out.println("结果：通过 " + passed + "，失败 " + failed);
        if (failed > 0) {
            System.exit(1);
        }
    }

    // ------------------------------------------------------------------

    private static void basics() throws Exception {
        section("落盘与 flush");
        check("目录已建好", dir.isDirectory());
        AppLog.write(AppLog.INFO, "tag", "hello log");
        check("flush 成功", AppLog.flush(3000));
        String text = dump();
        check("写入内容可见", text.contains("hello log"));
        check("带级别名", text.contains("INFO "));
        check("带分类", text.contains("[tag]"));
        check("带时间戳", text.matches("(?s).*\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}\\.\\d{3}.*"));
        check("文件按天命名", AppLog.fileNames().size() >= 1
                && AppLog.fileNames().get(AppLog.fileNames().size() - 1)
                .matches("app-\\d{4}-\\d{2}-\\d{2}\\.log"));
    }

    private static void levelFilter() throws Exception {
        section("级别过滤");
        AppLog.setMinLevel(AppLog.WARN);
        AppLog.write(AppLog.INFO, "tag", "should-not-appear");
        AppLog.write(AppLog.ERROR, "tag", "must-appear");
        AppLog.flush(3000);
        String text = dump();
        check("低于 minLevel 被丢弃", !text.contains("should-not-appear"));
        check("达到 minLevel 正常写入", text.contains("must-appear"));
        AppLog.setMinLevel(AppLog.DEBUG);
        AppLog.write(AppLog.DEBUG, "tag", "debug-after-reset");
        AppLog.flush(3000);
        check("恢复 DEBUG 后继续写", dump().contains("debug-after-reset"));
    }

    private static void syncWrite() {
        section("同步写（崩溃兜底）");
        AppLog.writeSync(AppLog.ERROR, "crash", "boom stacktrace");
        // 故意不调用 flush
        check("writeSync 返回后已在文件里", dump().contains("boom stacktrace"));
        check("级别是 ERROR", dump().contains("ERROR[cras"));
    }

    private static void formatting() throws Exception {
        section("格式：多行与超长");
        AppLog.write(AppLog.WARN, "tag", "line1\nline2");
        StringBuilder longMsg = new StringBuilder();
        for (int i = 0; i < 5000; i++) {
            longMsg.append('x');
        }
        AppLog.write(AppLog.INFO, "tag", longMsg.toString());
        AppLog.flush(3000);
        String text = dump();
        check("换行被缩进成续行", text.contains("line1\n    line2"));
        check("超长消息被截断并标记", text.contains("…") && !text.contains(longMsg.toString()));
    }

    private static void exportText() {
        section("导出文本");
        String out = AppLog.exportText("HEADER-LINE", 200000);
        check("含 header", out.contains("HEADER-LINE"));
        check("含统计行", out.contains("运行日志（共 "));
        check("含日志正文", out.contains("hello log"));
        check("空日志目录也给可读结果", exportEmpty());
        String tiny = AppLog.exportText("H", 200);
        check("超上限时保留尾部", tiny.length() < 1000);
    }

    private static boolean exportEmpty() {
        File empty = new File(dir, "empty-" + System.nanoTime());
        AppLog.install(empty);
        String out = AppLog.exportText(null, 1000);
        AppLog.install(dir);
        return out.contains("（还没有日志）");
    }

    private static void pruning() throws Exception {
        section("过期清理与统计");
        File old = new File(AppLog.dir(), "app-2000-01-01.log");
        FileWriter w = new FileWriter(old);
        w.write("2000-01-01 00:00:00.000 INFO  [old] ancient\n");
        w.close();
        check("老文件存在", old.isFile());
        int removed = AppLog.prune(AppLog.KEEP_DAYS);
        check("prune 删掉过期文件", removed == 1 && !old.isFile());
        check("今天的文件还在", AppLog.files().size() >= 1);
        check("stats 可读", AppLog.stats().contains("个文件 /"));
        check("humanSize 字节", AppLog.humanSize(512).endsWith(" B"));
        check("humanSize KB", AppLog.humanSize(4096).endsWith(" KB"));
        check("humanSize MB", AppLog.humanSize(2L * 1024 * 1024).endsWith(" MB"));
    }

    private static void clearAll() throws Exception {
        section("清空文件");
        AppLog.write(AppLog.INFO, "tag", "will-be-cleared");
        AppLog.flush(3000);
        check("清空前有内容", dump().contains("will-be-cleared"));
        int n = AppLog.clearFiles();
        check("清空了文件", n >= 1 && AppLog.files().isEmpty());
        check("清空后导出提示无日志", AppLog.exportText(null, 1000).contains("（还没有日志）"));
        AppLog.write(AppLog.INFO, "tag", "after-clear");
        AppLog.flush(3000);
        check("清空后还能继续写", dump().contains("after-clear"));
        // 清理临时目录
        for (File f : AppLog.files()) {
            //noinspection ResultOfMethodCallIgnored
            f.delete();
        }
        //noinspection ResultOfMethodCallIgnored
        AppLog.dir().delete();
    }

    // ------------------------------------------------------------------

    private static String dump() {
        StringBuilder sb = new StringBuilder();
        for (File f : AppLog.files()) {
            try {
                java.io.BufferedReader br = new java.io.BufferedReader(
                        new java.io.InputStreamReader(
                                new java.io.FileInputStream(f), "UTF-8"));
                try {
                    String line;
                    while ((line = br.readLine()) != null) {
                        sb.append(line).append('\n');
                    }
                } finally {
                    br.close();
                }
            } catch (Exception ignored) {
            }
        }
        return sb.toString();
    }

    private static void section(String title) {
        System.out.println("[ " + title + " ]");
    }

    private static void check(String name, boolean ok) {
        if (ok) {
            passed++;
            System.out.println("  ok   " + name);
        } else {
            failed++;
            System.out.println("  FAIL " + name);
        }
    }
}
