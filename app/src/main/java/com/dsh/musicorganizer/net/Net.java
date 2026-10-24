package com.dsh.musicorganizer.net;

import com.dsh.musicorganizer.core.CancelToken;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutorCompletionService;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * 网络并发编排（纯 Java，可离线测试，不依赖 Android）。
 *
 * <p>要解决的老问题：一首歌要依次查 7 个数据源，每个源一次 HTTP 往返，
 * 网络差时一首歌就要等好几个超时；批量 100 首就是几百次串行往返。
 *
 * <p>这里提供两件事：
 * <ul>
 *   <li>{@link #io()} —— 共享 IO 线程池：一首歌的多个源<b>同时</b>查（源级并发）；</li>
 *   <li>{@link #map} —— 多首歌<b>同时</b>查（文件级并发），结果按输入顺序返回。</li>
 * </ul>
 *
 * <p>为什么两级都用、却只用一个池：文件级 worker 跑在独立小池里，
 * 源级任务提交到 IO 池。若两者共用一个池，文件 worker 占满线程后等子任务会死锁。
 */
public final class Net {

    /** IO 池线程数。当前最多 7 个源并发，8 个线程留一点余量。 */
    public static final int IO_THREADS = 8;

    /**
     * 同时处理的文件数。手机/家用网络 3 路已能吃满带宽，
     * 再多会出现互相排队与频繁重传，反而更慢；也避免触发对方的限流。
     */
    public static final int FILE_CONCURRENCY = 3;

    /**
     * 本地文件批量预读（标签 / 封面）的并发度。
     *
     * <p>和上面的联网并发不是一回事：这里每首都是「开 SAF 文件 → 复制文件头 → 解析」，
     * 时间全花在等 IO 上，不占网络也不占 CPU。串行读一千多首要好几分钟，
     * 4 路并发实测快 2~3 倍；再多收益递减，还会让 provider 的复制互相抢带宽。
     */
    public static final int READ_THREADS = 4;

    /** 单个文件的源级总预算：最慢的 MusicBrainz 超时是 12s，按 12s 收口。 */
    public static final long SOURCE_BUDGET_MS = 12000L;

    /**
     * 等待线程池的单次切片时长。
     *
     * <p>这个数字**只在用户已取消时**起作用（让进行中的请求落地后就强制收工）。
     * 正常场景下会一直循环等到全部完成 —— 老实现是 {@code awaitTermination(90s)} 一次到点
     * 就返回半成品，几百首的批量匹配大约跑到 50 首就被当成「跑完了」（v0.1.49 修）。
     */
    public static final long AWAIT_SLICE_MS = 90000L;

    private static volatile ExecutorService ioPool;

    private Net() {
    }

    /** 共享 IO 线程池（daemon，进程内复用，省掉反复建池的开销）。 */
    public static ExecutorService io() {
        ExecutorService local = ioPool;
        if (local == null) {
            synchronized (Net.class) {
                local = ioPool;
                if (local == null) {
                    local = Executors.newFixedThreadPool(IO_THREADS, named("mo-net-io"));
                    ioPool = local;
                }
            }
        }
        return local;
    }

    private static ThreadFactory named(final String prefix) {
        final AtomicInteger seq = new AtomicInteger();
        return new ThreadFactory() {
            @Override
            public Thread newThread(Runnable r) {
                Thread t = new Thread(r, prefix + "-" + seq.incrementAndGet());
                t.setDaemon(true);
                return t;
            }
        };
    }

    /** 单元素处理任务（不关心序号）。 */
    public interface Work<T, R> {
        R run(T item);
    }

    /** 单元素处理任务，携带元素在输入列表中的原始序号。 */
    public interface IndexedWork<T, R> {
        R run(int index, T item);
    }

    /**
     * 有序并发处理：结果与 {@code items} 一一对应，未处理（被取消）的位置为 null。
     *
     * <p>暂停/停止仍然有效：每个 worker 在取任务前经过 {@link CancelToken#isCancelled()} 检查点，
     * 暂停就是 worker 阻塞在检查点上，不会继续发起新请求。
     */
    public static <T, R> List<R> map(List<T> items, int threads,
                                     final CancelToken cancel, final Work<T, R> work) {
        return mapIndexed(items, threads, cancel, new IndexedWork<T, R>() {
            @Override
            public R run(int index, T item) {
                return work.run(item);
            }
        });
    }

    /** 与 {@link #map} 相同，但 worker 能拿到元素序号（用于「边跑边收」按原顺序归位）。 */
    public static <T, R> List<R> mapIndexed(List<T> items, int threads,
                                            final CancelToken cancel,
                                            final IndexedWork<T, R> work) {
        return mapIndexed(items, threads, cancel, work, AWAIT_SLICE_MS);
    }

    /**
     * 同上，但单次等待切片可指定。
     *
     * <p>存在的意义是回归测试：把 90 秒压成几十毫秒，才能在合理时间内验证
     * 「跑不满一个切片就必须等完」这件事。生产代码一律走四参版本。
     */
    public static <T, R> List<R> mapIndexed(List<T> items, int threads,
                                            final CancelToken cancel,
                                            final IndexedWork<T, R> work,
                                            final long awaitSliceMs) {
        final int size = items.size();
        @SuppressWarnings("unchecked")
        final R[] out = (R[]) new Object[size];
        if (size == 0) {
            return new ArrayList<R>();
        }
        final int poolSize = Math.max(1, Math.min(threads, size));
        ExecutorService pool = Executors.newFixedThreadPool(poolSize, named("mo-file"));
        final AtomicInteger cursor = new AtomicInteger();
        try {
            final List<T> source = items;
            for (int i = 0; i < poolSize; i++) {
                pool.execute(new Runnable() {
                    @Override
                    public void run() {
                        while (true) {
                            if (cancel != null && cancel.isCancelled()) {
                                return;
                            }
                            int index = cursor.getAndIncrement();
                            if (index >= size) {
                                return;
                            }
                            try {
                                out[index] = work.run(index, source.get(index));
                            } catch (Throwable ignored) {
                                // 单首失败不影响其它文件；统计在业务层计数
                                out[index] = null;
                            }
                        }
                    }
                });
            }
        } finally {
            pool.shutdown();
        }
        awaitAll(pool, cancel, awaitSliceMs);
        List<R> result = new ArrayList<R>(size);
        for (R r : out) {
            result.add(r);
        }
        return result;
    }

    /**
     * 等到线程池真正终止。
     *
     * <p><b>为什么必须循环等</b>：老实现是 {@code awaitTermination(90, TimeUnit.SECONDS)}
     * 调一次就到点返回，而批量匹配（标签 / 歌词 / 封面三处都走这个方法）几百首要跑好几分钟。
     * 3 路并发、单首约 1.8 秒的实测节奏下，90 秒只够处理 50 首左右 —— 剩下的全部变成
     * {@code null} 静默丢掉，日志却照样打「标签匹配完成：待确认 N 首」，
     * 用户以为整批都跑完了。这是 v0.1.49 修掉的真实 bug。
     *
     * <p>取消语义保持不变：用户点了停止，最多再等一个切片让进行中的请求落地，然后强收。
     */
    private static void awaitAll(ExecutorService pool, CancelToken cancel, long sliceMs) {
        // 轮询粒度取 min(切片, 250ms)：取消必须尽快响应。
        // 老实现 awaitTermination(90s) 一次到点就返回有两层后果 —— 不但正常场景被截断成
        // 半成品，用户点了「停止」后也得干等满 90 秒才收工。
        long tick = Math.max(1L, Math.min(sliceMs, 250L));
        try {
            while (!pool.awaitTermination(tick, TimeUnit.MILLISECONDS)) {
                if (cancel != null && cancel.isCancelled()) {
                    pool.shutdownNow();   // 中断进行中的请求，立即收工
                    return;
                }
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            pool.shutdownNow();
        }
    }

    /**
     * 并发跑一批任务，按完成顺序收集；总预算用尽或用户取消时立即返回已完成的部分。
     *
     * <p>用 {@link ExecutorCompletionService} 轮询而不是逐个 get()，是为了让「停止」
     * 立刻生效，而不是等最慢的那个源超时。
     */
    public static <T> List<T> gather(List<Callable<T>> tasks, long budgetMs, CancelToken cancel) {
        List<T> out = new ArrayList<T>();
        if (tasks == null || tasks.isEmpty()) {
            return out;
        }
        ExecutorCompletionService<T> cs = new ExecutorCompletionService<T>(io());
        List<Future<T>> futures = new ArrayList<Future<T>>(tasks.size());
        for (Callable<T> task : tasks) {
            futures.add(cs.submit(task));
        }
        long deadline = System.currentTimeMillis() + Math.max(500L, budgetMs);
        int received = 0;
        while (received < tasks.size()) {
            long left = deadline - System.currentTimeMillis();
            if (left <= 0) {
                break;
            }
            if (cancel != null && cancel.isCancelledNow()) {
                break;
            }
            Future<T> done;
            try {
                // 150ms 一次轮询：既能让停止及时生效，也不至于空转
                done = cs.poll(Math.min(left, 150L), TimeUnit.MILLISECONDS);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                break;
            }
            if (done == null) {
                continue;
            }
            try {
                T value = done.get();
                if (value != null) {
                    out.add(value);
                }
            } catch (Exception ignored) {
                // 单源异常只是少一个源的结果
            }
            received++;
        }
        if (received < tasks.size()) {
            for (Future<T> f : futures) {
                f.cancel(true);
            }
        }
        return out;
    }
}
