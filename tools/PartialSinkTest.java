import com.dsh.musicorganizer.core.PartialSink;

import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * PartialSink 回归：暂停预览依赖它「边跑边收、随时取快照」，
 * 而写入端是并发工作线程、读取端是 UI 主线程，线程安全必须验证。
 */
public class PartialSinkTest {

    private static int passed = 0;
    private static int failed = 0;

    private static void ok(String name, boolean cond) {
        if (cond) {
            passed++;
            System.out.println("  ✔ " + name);
        } else {
            failed++;
            System.out.println("  ✘ " + name);
        }
    }

    public static void main(String[] args) throws Exception {
        System.out.println("[PartialSink] 已获取结果缓冲区");

        PartialSink<String> sink = new PartialSink<String>();
        ok("初始为空", sink.size() == 0 && sink.snapshot().isEmpty() && sink.isEmpty());

        sink.add(null);
        ok("null 被忽略", sink.size() == 0);

        sink.add("a");
        List<String> first = sink.snapshot();
        ok("快照包含已收条目", first.size() == 1 && "a".equals(first.get(0)));

        sink.add("b");
        ok("旧快照不随后续写入变化（暂停时看到的是当时那一刻）", first.size() == 1);
        ok("缓冲区继续累积", sink.size() == 2);

        first.clear();
        ok("改快照不影响缓冲区", sink.size() == 2);

        sink.clear();
        ok("clear 清空", sink.size() == 0);

        // ---- 并发写入：多线程各写一批，一条都不能丢 ----
        final int threads = 8;
        final int per = 500;
        final PartialSink<Integer> concurrent = new PartialSink<Integer>();
        final CountDownLatch start = new CountDownLatch(1);
        final AtomicBoolean readerError = new AtomicBoolean(false);
        final AtomicInteger reads = new AtomicInteger();

        Thread reader = new Thread(new Runnable() {
            @Override
            public void run() {
                // 模拟 UI 主线程反复取快照（暂停时按钮每次刷新都会取数量）
                try {
                    while (!Thread.currentThread().isInterrupted()) {
                        List<Integer> snap = concurrent.snapshot();
                        if (snap == null) {
                            readerError.set(true);
                            return;
                        }
                        reads.incrementAndGet();
                    }
                } catch (Throwable t) {
                    readerError.set(true);
                }
            }
        }, "reader");
        reader.setDaemon(true);
        reader.start();

        Thread[] writers = new Thread[threads];
        for (int i = 0; i < threads; i++) {
            final int base = i * per;
            writers[i] = new Thread(new Runnable() {
                @Override
                public void run() {
                    try {
                        start.await();
                    } catch (InterruptedException e) {
                        Thread.currentThread().interrupt();
                        return;
                    }
                    for (int j = 0; j < per; j++) {
                        concurrent.add(Integer.valueOf(base + j));
                    }
                }
            }, "w" + i);
            writers[i].start();
        }
        start.countDown();
        for (Thread t : writers) {
            t.join();
        }
        reader.interrupt();
        reader.join(2000);

        ok("并发写入不丢条目（" + threads + "×" + per + " = " + concurrent.size() + "）",
                concurrent.size() == threads * per);
        ok("边写边读快照无异常（读了 " + reads.get() + " 次）", !readerError.get());

        int sum = 0;
        for (Integer v : concurrent.snapshot()) {
            sum += v;
        }
        int expect = (threads * per) * (threads * per - 1) / 2;
        ok("快照内容完整且无重复", sum == expect);

        System.out.println();
        System.out.println("结果：通过 " + passed + "，失败 " + failed);
        if (failed > 0) {
            System.exit(1);
        }
    }
}
