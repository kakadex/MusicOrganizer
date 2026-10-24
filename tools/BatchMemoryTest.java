import com.dsh.musicorganizer.core.BatchMemory;
import com.dsh.musicorganizer.core.BatchSkip;
import com.dsh.musicorganizer.core.VFile;

import java.io.File;
import java.io.FileOutputStream;
import java.io.OutputStreamWriter;
import java.io.Writer;
import java.util.ArrayList;
import java.util.List;

/**
 * 增量匹配记忆回归测试（纯 JVM）。
 *
 * 覆盖：
 *   1. 记录 / 跳过 / 文件指纹变化后失效
 *   2. 三种状态（无结果 / 被拦 / 已写入）
 *   3. 落盘与重新加载（模拟进程被杀）
 *   4. 自动落盘阈值（不显式 save 也不至于全丢）
 *   5. 损坏文件容错、清除、摘要文案
 */
public final class BatchMemoryTest {

    private static int passed = 0;
    private static int failed = 0;

    public static void main(String[] args) throws Exception {
        File dir = new File(System.getProperty("java.io.tmpdir"),
                "batchmem-test-" + System.nanoTime());
        dir.mkdirs();

        basics(dir);
        fingerprint(dir);
        persist(dir);
        autoSave(dir);
        robustness(dir);
        forget(dir);
        ignoreExisting(dir);
        batchSkip();
        cleanup(dir);

        System.out.println();
        System.out.println("结果：通过 " + passed + "，失败 " + failed);
        if (failed > 0) {
            System.exit(1);
        }
    }

    // ------------------------------------------------------------------

    private static void basics(File dir) {
        section("记录与跳过");
        BatchMemory mem = BatchMemory.open(dir, "t1");
        check("初始为空", mem.size() == 0);
        check("没记录不跳过", !mem.shouldSkip("a.mp3", 100, 1000));
        mem.record("a.mp3", 100, 1000, BatchMemory.NO_HIT);
        check("无结果后跳过", mem.shouldSkip("a.mp3", 100, 1000));
        check("状态正确", BatchMemory.NO_HIT.equals(mem.statusOf("a.mp3", 100, 1000)));
        check("跳过计数", mem.skipCount() == 1);
        mem.record("b.mp3", 200, 2000, BatchMemory.REJECTED);
        check("被拦也跳过", mem.shouldSkip("b.mp3", 200, 2000));
        mem.markDone("c.mp3", 300, 3000);
        check("已写入跳过", mem.shouldSkip("c.mp3", 300, 3000));
        check("条数 3", mem.size() == 3);
        check("摘要含分类", mem.summary().contains("无结果 1")
                && mem.summary().contains("被拦 1") && mem.summary().contains("已写入 1"));
        check("空键不记录", recordIgnored(mem));
    }

    private static boolean recordIgnored(BatchMemory mem) {
        int before = mem.size();
        mem.record("", 1, 1, BatchMemory.NO_HIT);
        mem.record("x", 1, 1, null);
        return mem.size() == before;
    }

    private static void fingerprint(File dir) {
        section("文件指纹");
        BatchMemory mem = BatchMemory.open(dir, "t2");
        mem.record("a.mp3", 100, 1000, BatchMemory.NO_HIT);
        check("同大小同时间 → 跳过", mem.shouldSkip("a.mp3", 100, 1000));
        check("大小变了 → 重查", !mem.shouldSkip("a.mp3", 101, 1000));
        check("时间变了 → 重查", !mem.shouldSkip("a.mp3", 100, 2000));
        check("状态查询也失效", mem.statusOf("a.mp3", 101, 1000).isEmpty());
        // mtime 取不到（0）时只比大小
        mem.record("b.mp3", 500, 0, BatchMemory.NO_HIT);
        check("mtime=0 视为通配", mem.shouldSkip("b.mp3", 500, 9999));
    }

    private static void persist(File dir) {
        section("落盘与重新加载");
        BatchMemory mem = BatchMemory.open(dir, "t3");
        mem.record("p1.mp3", 10, 100, BatchMemory.NO_HIT);
        mem.record("p2.mp3", 20, 200, BatchMemory.DONE);
        check("save 成功", mem.save());
        check("文件已生成", mem.file().isFile());
        BatchMemory re = BatchMemory.open(dir, "t3");
        check("重新加载条数", re.size() == 2);
        check("无结果仍生效", re.shouldSkip("p1.mp3", 10, 100));
        check("已写入仍生效", re.shouldSkip("p2.mp3", 20, 200));
        check("别的任务互不影响", BatchMemory.open(dir, "t4").size() == 0);
    }

    private static void autoSave(File dir) {
        section("自动落盘");
        BatchMemory mem = BatchMemory.open(dir, "t5");
        for (int i = 0; i < 45; i++) {
            mem.record("auto" + i + ".mp3", i, i, BatchMemory.NO_HIT);
        }
        // 没有显式 save：靠 SAVE_EVERY 阈值落盘
        BatchMemory re = BatchMemory.open(dir, "t5");
        check("阈值触发过落盘", re.size() >= 40);
    }

    private static void robustness(File dir) throws Exception {
        section("容错与清除");
        File bad = new File(dir, "t6.json");
        Writer w = new OutputStreamWriter(new FileOutputStream(bad), "UTF-8");
        w.write("{ 这不是 json");
        w.close();
        BatchMemory mem = BatchMemory.open(dir, "t6");
        check("坏文件不崩、当空处理", mem.size() == 0);
        mem.record("a.mp3", 1, 1, BatchMemory.NO_HIT);
        check("坏文件之后仍能记录", mem.shouldSkip("a.mp3", 1, 1));

        mem.clear();
        check("clear 后为空", mem.size() == 0 && !mem.shouldSkip("a.mp3", 1, 1));
        check("clear 后文件还在", mem.file().isFile());
        mem.delete();
        check("delete 后文件消失", !mem.file().isFile());
        check("空记忆摘要可读", BatchMemory.open(dir, "t7").summary().contains("还没有"));
    }

    /**
     * 「重新查询这 N 首」：只忘掉点名的那几首，其它歌的记忆不能丢。
     * 全清会让下一次批量把几万首重新查一遍，代价太大。
     */
    private static void forget(File dir) {
        section("忘记单首（重新查询入口）");
        BatchMemory mem = BatchMemory.open(dir, "f1");
        mem.record("a.mp3", 100, 1000, BatchMemory.NO_HIT);
        mem.record("b.mp3", 200, 2000, BatchMemory.REJECTED);
        mem.record("c.mp3", 300, 3000, BatchMemory.DONE);
        check("三首都在", mem.size() == 3);

        check("忘掉 a 返回 true", mem.forget("a.mp3"));
        check("a 不再跳过", !mem.shouldSkip("a.mp3", 100, 1000));
        check("b 仍跳过", mem.shouldSkip("b.mp3", 200, 2000));
        check("c 仍跳过", mem.shouldSkip("c.mp3", 300, 3000));
        check("条数减一", mem.size() == 2);
        check("重复忘掉返回 false", !mem.forget("a.mp3"));
        check("空键返回 false", !mem.forget(""));
        check("null 键返回 false", !mem.forget(null));

        // 批量忘掉（界面「重新查询这 N 首」走这个）
        List<String> keys = new ArrayList<String>();
        keys.add("b.mp3");
        keys.add("c.mp3");
        keys.add("not-exist.mp3");
        check("批量删掉 2 条", mem.forgetAll(keys) == 2);
        check("b 不再跳过", !mem.shouldSkip("b.mp3", 200, 2000));
        check("记忆清空", mem.size() == 0);
        check("空列表删 0 条", mem.forgetAll(new ArrayList<String>()) == 0);
        check("null 列表删 0 条", mem.forgetAll(null) == 0);

        // 忘记要落盘：重开不能又冒出旧结论
        mem.record("d.mp3", 400, 4000, BatchMemory.NO_HIT);
        mem.forget("d.mp3");
        BatchMemory again = BatchMemory.open(dir, "f1");
        check("重开后没复活", !again.shouldSkip("d.mp3", 400, 4000));
    }

    /**
     * 「忽略匹配记忆」开关：这一轮全部重查，但新结论照常记 ——
     * 和「清空记忆」不是一回事（清空之后下一轮又没有增量可用了）。
     */
    private static void ignoreExisting(File dir) {
        section("忽略已有记忆");
        BatchMemory mem = BatchMemory.open(dir, "i1");
        mem.record("a.mp3", 100, 1000, BatchMemory.NO_HIT);
        check("默认会跳过", mem.shouldSkip("a.mp3", 100, 1000));
        check("默认开关是关", !mem.ignoreExisting());

        mem.setIgnoreExisting(true);
        check("开关读出为开", mem.ignoreExisting());
        check("开着时不跳过", !mem.shouldSkip("a.mp3", 100, 1000));
        check("记录仍照常写入", recordWhileIgnoring(mem));

        mem.setIgnoreExisting(false);
        check("关掉后恢复跳过", mem.shouldSkip("a.mp3", 100, 1000));
        check("新结论已生效", BatchMemory.REJECTED.equals(
                mem.statusOf("a.mp3", 100, 1000)));
    }

    private static boolean recordWhileIgnoring(BatchMemory mem) {
        mem.record("a.mp3", 100, 1000, BatchMemory.REJECTED);
        return BatchMemory.REJECTED.equals(mem.statusOf("a.mp3", 100, 1000));
    }

    /** 跳过明细：界面据此拼「重新查询这 N 首」。 */
    private static void batchSkip() {
        section("跳过明细");
        BatchSkip skip = new BatchSkip();
        check("初始为空", !skip.hasMemorySkips());
        check("空文案为空串", skip.note().isEmpty());
        check("空数 0", skip.memoryCount() == 0);

        skip.addMemory(audio("a.mp3"));
        skip.addMemory(audio("b.mp3"));
        check("记了 2 首", skip.memoryCount() == 2);
        check("有跳过", skip.hasMemorySkips());
        check("文案含数量", skip.note().contains("2 首"));
        check("文件列表长度", skip.memoryFiles().size() == 2);
        check("文件顺序保留", "a.mp3".equals(skip.memoryFiles().get(0).name));

        skip.addMemory(null);
        check("null 不计入", skip.memoryCount() == 2);

        // 返回副本：调用方改列表不能影响内部
        skip.memoryFiles().clear();
        check("副本清空不影响内部", skip.memoryCount() == 2);
    }

    private static VFile audio(String name) {
        return new VFile("primary:Music/" + name, "primary:Music", name,
                "audio/mpeg", 100, 1000, false);
    }

    private static void cleanup(File dir) {
        section("清理");
        File[] files = dir.listFiles();
        int n = 0;
        if (files != null) {
            for (File f : files) {
                if (f.delete()) {
                    n++;
                }
            }
        }
        check("临时文件已清理", n >= 1 && dir.delete());
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
