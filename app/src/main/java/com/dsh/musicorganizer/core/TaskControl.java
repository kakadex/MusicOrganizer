package com.dsh.musicorganizer.core;

import java.util.ArrayList;
import java.util.List;

/**
 * 任务控制器 —— 同时承担「进度上报」与「暂停 / 取消」。
 *
 * <p>设计要点：
 * <ul>
 *   <li>实现 {@link CancelToken}：各业务的循环体本来就在每轮调用 isCancelled()，
 *       这里把「暂停」实现为在该检查点阻塞工作线程，因此无需改动各处循环即可获得
 *       逐文件粒度的暂停能力。</li>
 *   <li>进度状态可被任意线程读取，UI / 通知栏各自取最新值。</li>
 *   <li>纯 Java，不依赖 Android，便于离线回归测试。</li>
 * </ul>
 */
public class TaskControl implements CancelToken {

    /** 状态变化监听（在工作线程触发，调用方需自行切主线程）。 */
    public interface Listener {
        void onState(TaskControl control);
    }

    private volatile boolean paused = false;
    private volatile boolean cancelled = false;
    private volatile boolean finished = false;

    private volatile int done = 0;
    private volatile int total = 0;
    private volatile String message = "";
    private volatile long startedAt = System.currentTimeMillis();
    private volatile long finishedAt = 0;

    private final List<Listener> listeners = new ArrayList<Listener>();

    private final Object pauseLock = new Object();

    public TaskControl() {
        this("");
    }

    public TaskControl(String message) {
        this.message = message == null ? "" : message;
    }

    // ---- CancelToken ----

    /**
     * 检查点：暂停期间阻塞，直到恢复或取消；取消后返回 true。
     * 各业务循环每轮都会调用，因此暂停是「下一个检查点生效」。
     */
    @Override
    public boolean isCancelled() {
        waitIfPaused();
        return cancelled;
    }

    private void waitIfPaused() {
        if (!paused) {
            return;
        }
        synchronized (pauseLock) {
            while (paused && !cancelled) {
                try {
                    pauseLock.wait(150);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    return;
                }
            }
        }
    }

    /** 不阻塞的取消状态查询（UI 用）。 */
    public boolean isCancelledNow() {
        return cancelled;
    }

    public boolean isPaused() {
        return paused;
    }

    public boolean isFinished() {
        return finished;
    }

    public void pause() {
        if (finished || cancelled) {
            return;
        }
        paused = true;
        notifyListeners();
    }

    public void resume() {
        if (!paused) {
            return;
        }
        paused = false;
        synchronized (pauseLock) {
            pauseLock.notifyAll();
        }
        notifyListeners();
    }

    public void togglePause() {
        if (paused) {
            resume();
        } else {
            pause();
        }
    }

    /** 请求停止：解除暂停并让检查点返回已取消。工作线程会自行收尾退出。 */
    public void cancel() {
        if (cancelled || finished) {
            return;
        }
        cancelled = true;
        paused = false;
        synchronized (pauseLock) {
            pauseLock.notifyAll();
        }
        notifyListeners();
    }

    /** 工作线程结束时调用，标记完成并记录耗时。 */
    public void finish() {
        finished = true;
        paused = false;
        finishedAt = System.currentTimeMillis();
        synchronized (pauseLock) {
            pauseLock.notifyAll();
        }
        notifyListeners();
    }

    // ---- 进度 ----

    /** 上报进度；total<=0 表示总量未知（只显示已处理数）。 */
    public void report(int done, int total, String message) {
        this.done = done;
        this.total = total;
        if (message != null) {
            this.message = message;
        }
        notifyListeners();
    }

    public int done() {
        return done;
    }

    public int total() {
        return total;
    }

    public String message() {
        return message;
    }

    /** 0~100；总量未知时返回 -1（通知栏用不确定进度条）。 */
    public int percent() {
        if (total <= 0) {
            return -1;
        }
        int p = (int) (100L * done / total);
        if (p < 0) {
            return 0;
        }
        return Math.min(p, 100);
    }

    public long elapsedMs() {
        long end = finishedAt > 0 ? finishedAt : System.currentTimeMillis();
        return Math.max(0, end - startedAt);
    }

    /** 形如「37/120 · 周杰伦 - 七里香.mp3」。 */
    public String summary() {
        StringBuilder sb = new StringBuilder();
        if (total > 0) {
            sb.append(done).append('/').append(total).append("  ·  ");
        } else if (done > 0) {
            sb.append(done).append("  ·  ");
        }
        sb.append(message);
        if (paused) {
            sb.append("　（已暂停）");
        }
        return sb.toString();
    }

    // ---- 监听 ----

    public void addListener(Listener listener) {
        if (listener == null) {
            return;
        }
        synchronized (listeners) {
            if (!listeners.contains(listener)) {
                listeners.add(listener);
            }
        }
    }

    public void removeListener(Listener listener) {
        synchronized (listeners) {
            listeners.remove(listener);
        }
    }

    private void notifyListeners() {
        Listener[] snapshot;
        synchronized (listeners) {
            snapshot = listeners.toArray(new Listener[0]);
        }
        for (Listener l : snapshot) {
            try {
                l.onState(this);
            } catch (Throwable ignored) {
                // 监听器异常不能影响任务本身
            }
        }
    }
}
