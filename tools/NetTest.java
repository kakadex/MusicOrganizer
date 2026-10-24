import com.dsh.musicorganizer.core.CancelToken;
import com.dsh.musicorganizer.core.TaskControl;
import com.dsh.musicorganizer.net.Net;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.Callable;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * 离线回归测试（纯 JVM）：网络并发编排。
 *
 * 覆盖：
 *   1. map 结果顺序与输入一致（并发乱序完成，结果不能乱）
 *   2. map 确实在并发（10×150ms，5 路 → 明显快于串行）
 *   3. 已取消 → 一个都不跑
 *   4. 总时长跨多个等待切片时，必须等到全部完成（v0.1.49 真实 bug 回归）
 *   5. 取消后最多再等一个切片就收工（修 bug 不能把取消语义改慢）
 *   6. gather 总预算生效（慢任务不能拖住整批）
 *   7. gather 单任务抛异常不影响其它结果
 *
 * 不依赖 Android / 网络，用 tools/run_core_test.sh 跑。
 */
public class NetTest {

    static int fails = 0;

    static void ok(String name, boolean cond) {
        if (!cond) {
            fails++;
        }
        System.out.println((cond ? "  ok   " : "  FAIL ") + name);
    }

    public static void main(String[] a) throws Exception {
        orderPreserved();
        realParallel();
        cancelledDoesNothing();
        waitsForAllDespiteSlices();
        cancelStopsPromptly();
        gatherBudget();
        gatherToleratesFailure();

        System.out.println(fails == 0 ? "全部通过" : (fails + " 项失败"));
        if (fails > 0) {
            System.exit(1);
        }
    }

    /** 1. 结果顺序必须与输入一致。 */
    static void orderPreserved() {
        System.out.println("[1] map 结果顺序");
        List<Integer> items = new ArrayList<Integer>();
        for (int i = 0; i < 12; i++) {
            items.add(i);
        }
        List<Integer> out = Net.map(items, 4, null, new Net.Work<Integer, Integer>() {
            @Override
            public Integer run(Integer item) {
                // 故意让后面的任务先完成
                try {
                    Thread.sleep((12 - item) * 8L);
                } catch (InterruptedException ignored) {
                }
                return item * 2;
            }
        });
        ok("长度一致", out.size() == items.size());
        boolean ordered = true;
        for (int i = 0; i < out.size(); i++) {
            if (out.get(i) == null || out.get(i) != i * 2) {
                ordered = false;
                break;
            }
        }
        ok("元素与输入下标一一对应", ordered);
    }

    /** 2. 必须真的并发：10 个 150ms 任务，5 路应约 300~600ms，而不是 1500ms。 */
    static void realParallel() {
        System.out.println("[2] map 并发度");
        List<Integer> items = new ArrayList<Integer>();
        for (int i = 0; i < 10; i++) {
            items.add(i);
        }
        long start = System.currentTimeMillis();
        Net.map(items, 5, null, new Net.Work<Integer, Integer>() {
            @Override
            public Integer run(Integer item) {
                try {
                    Thread.sleep(150);
                } catch (InterruptedException ignored) {
                }
                return item;
            }
        });
        long cost = System.currentTimeMillis() - start;
        // 串行要 1500ms；5 路理论 300ms，放宽到 1000ms 抗 CI 抖动
        ok("耗时 " + cost + "ms < 1000ms（串行为 1500ms）", cost < 1000);
    }

    /** 3. 进来就已取消 → 不执行任何任务，结果全 null。 */
    static void cancelledDoesNothing() {
        System.out.println("[3] 已取消则不开工");
        TaskControl tc = new TaskControl();
        tc.cancel();
        final AtomicInteger ran = new AtomicInteger();
        List<Integer> items = new ArrayList<Integer>();
        for (int i = 0; i < 6; i++) {
            items.add(i);
        }
        List<Integer> out = Net.map(items, 3, tc, new Net.Work<Integer, Integer>() {
            @Override
            public Integer run(Integer item) {
                ran.incrementAndGet();
                return item;
            }
        });
        ok("执行次数为 0", ran.get() == 0);
        boolean allNull = true;
        for (Integer v : out) {
            if (v != null) {
                allNull = false;
                break;
            }
        }
        ok("结果全为 null", allNull);
        ok("长度仍与输入一致", out.size() == items.size());
    }

    /**
     * 4. 总时长跨多个等待切片时，必须等到全部完成 —— v0.1.49 真实 bug 的回归。
     *
     * <p>老实现 {@code awaitTermination(90s)} 调一次就到点返回，批量匹配（标签/歌词/封面
     * 三处都走这条路径）几百首要跑好几分钟，于是大约 50 首就被当成「跑完了」，剩下的静默
     * 变成 null，日志还打「匹配完成」。这里把切片压到 40ms、每个任务 60ms、3 路跑 12 个，
     * 总耗时约 240ms 会跨 6 个切片 —— 旧代码在这里就会丢结果。
     */
    static void waitsForAllDespiteSlices() {
        System.out.println("[4] 跨切片必须等完（v0.1.49 回归）");
        List<Integer> items = new ArrayList<Integer>();
        for (int i = 0; i < 12; i++) {
            items.add(i);
        }
        List<Integer> out = Net.mapIndexed(items, 3, null,
                new Net.IndexedWork<Integer, Integer>() {
                    @Override
                    public Integer run(int index, Integer item) {
                        try {
                            Thread.sleep(60);
                        } catch (InterruptedException ignored) {
                        }
                        return item * 3;
                    }
                }, 40L);
        int nonNull = 0;
        boolean ordered = true;
        for (int i = 0; i < out.size(); i++) {
            Integer v = out.get(i);
            if (v == null) {
                ordered = false;
            } else {
                nonNull++;
                if (v != i * 3) {
                    ordered = false;
                }
            }
        }
        ok("12 个任务全部完成（一个都没丢）", nonNull == 12);
        ok("结果仍与下标一一对应", ordered);
    }

    /** 5. 取消后最多再等一个切片就收工 —— 修 bug 不能把取消语义改慢。 */
    static void cancelStopsPromptly() {
        System.out.println("[5] 取消后及时收工");
        final TaskControl tc = new TaskControl();
        List<Integer> items = new ArrayList<Integer>();
        for (int i = 0; i < 40; i++) {
            items.add(i);
        }
        final AtomicInteger ran = new AtomicInteger();
        long start = System.currentTimeMillis();
        Net.mapIndexed(items, 3, tc, new Net.IndexedWork<Integer, Integer>() {
            @Override
            public Integer run(int index, Integer item) {
                ran.incrementAndGet();
                tc.cancel();   // 第一个任务一开工就取消
                try {
                    Thread.sleep(30);
                } catch (InterruptedException ignored) {
                }
                return item;
            }
        }, 300L);
        long cost = System.currentTimeMillis() - start;
        ok("耗时 " + cost + "ms < 1500ms（没有死等 40 个任务）", cost < 1500);
        ok("没有把 40 个全跑完（取消真的生效）", ran.get() < 40);
    }

    /** 6. gather 的总预算：慢任务不能拖住整批。 */
    static void gatherBudget() throws Exception {
        System.out.println("[6] gather 总预算");
        List<Callable<String>> tasks = new ArrayList<Callable<String>>();
        tasks.add(new SlowTask("fast", 30));
        tasks.add(new SlowTask("slow-1", 3000));
        tasks.add(new SlowTask("slow-2", 3000));
        long start = System.currentTimeMillis();
        List<String> out = Net.gather(tasks, 400, null);
        long cost = System.currentTimeMillis() - start;
        ok("耗时 " + cost + "ms < 1500ms", cost < 1500);
        ok("拿到已完成的结果（含 fast）", out.contains("fast"));
        ok("未完成任务不计入", out.size() < 3);
    }

    /** 5. 单任务异常只是少一个结果。 */
    static void gatherToleratesFailure() throws Exception {
        System.out.println("[7] gather 容错");
        List<Callable<String>> tasks = new ArrayList<Callable<String>>();
        tasks.add(new SlowTask("ok-1", 10));
        tasks.add(new Callable<String>() {
            @Override
            public String call() {
                throw new IllegalStateException("模拟源故障");
            }
        });
        tasks.add(new SlowTask("ok-2", 10));
        List<String> out = Net.gather(tasks, 3000, null);
        ok("异常源被跳过，其它结果保留", out.contains("ok-1") && out.contains("ok-2"));
    }

    static final class SlowTask implements Callable<String> {
        final String name;
        final long sleepMs;

        SlowTask(String name, long sleepMs) {
            this.name = name;
            this.sleepMs = sleepMs;
        }

        @Override
        public String call() throws Exception {
            Thread.sleep(sleepMs);
            return name;
        }
    }

    /** 让编译器确认 CancelToken 的新默认方法可用（不阻塞查询）。 */
    static void unused(CancelToken t) {
        t.isCancelledNow();
    }
}
