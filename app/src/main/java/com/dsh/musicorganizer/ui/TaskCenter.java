package com.dsh.musicorganizer.ui;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;

import com.dsh.musicorganizer.core.TaskControl;

import java.util.ArrayList;
import java.util.List;

/**
 * 全局任务中心：同一时刻只允许一个长任务，对外提供进度 / 暂停 / 停止，
 * 并驱动前台服务的通知栏进度。
 *
 * 任务在单线程池里跑，前台服务持有通知，因此退到后台或锁屏后仍会继续。
 */
public final class TaskCenter {

    private TaskCenter() {
    }

    private static final Handler MAIN = new Handler(Looper.getMainLooper());
    private static final List<Runnable> OBSERVERS = new ArrayList<Runnable>();

    private static TaskControl current;
    private static String title = "";
    private static Context appContext;
    /** 当前任务注册的「已获取部分」预览提供者；没有则为 null（面板不显示预览按钮）。 */
    private static PartialPreview partial;

    private static long lastNotifyAt = 0;

    private static final TaskControl.Listener STATE = new TaskControl.Listener() {
        @Override
        public void onState(TaskControl control) {
            long now = System.currentTimeMillis();
            // 通知栏刷新限流：普通进度 400ms 一次，暂停/停止等状态变化立即刷新
            boolean urgent = control.isPaused() || control.isCancelledNow()
                    || control.isFinished();
            if (urgent || now - lastNotifyAt > 400) {
                lastNotifyAt = now;
                TaskService.update(appContext);
            }
            MAIN.post(new Runnable() {
                @Override
                public void run() {
                    List<Runnable> snapshot;
                    synchronized (OBSERVERS) {
                        snapshot = new ArrayList<Runnable>(OBSERVERS);
                    }
                    for (Runnable r : snapshot) {
                        try {
                            r.run();
                        } catch (Throwable ignored) {
                        }
                    }
                }
            });
        }
    };

    public static void init(Context ctx) {
        if (ctx != null) {
            appContext = ctx.getApplicationContext();
        }
    }

    /** 开始一个任务；若已有任务在跑则返回 null。 */
    public static synchronized TaskControl begin(Context ctx, String jobTitle) {
        init(ctx);
        if (current != null && !current.isFinished()) {
            return null;
        }
        TaskControl control = new TaskControl("准备中…");
        control.addListener(STATE);
        current = control;
        partial = null; // 上一任务遗留的预览提供者不能带到新任务
        title = jobTitle == null || jobTitle.isEmpty() ? "任务" : jobTitle;
        TaskService.start(appContext);
        return control;
    }

    /** 任务收尾：标记完成并撤掉通知栏。 */
    public static synchronized void end() {
        TaskControl control = current;
        if (control == null) {
            return;
        }
        control.finish();
        partial = null;
        TaskService.stop(appContext);
    }

    /** 注册本任务的「已获取部分」预览（在 {@link #begin} 之后、任务开跑时调用）。 */
    public static synchronized void setPartial(PartialPreview preview) {
        partial = preview;
    }

    /** 当前任务的已获取部分预览提供者；没有则为 null。 */
    public static synchronized PartialPreview partial() {
        return partial;
    }

    public static synchronized TaskControl current() {
        return current;
    }

    public static String title() {
        return title;
    }

    public static synchronized boolean busy() {
        return current != null && !current.isFinished();
    }

    // ---- 观察者（主线程回调）----

    public static void addObserver(Runnable r) {
        if (r == null) {
            return;
        }
        synchronized (OBSERVERS) {
            if (!OBSERVERS.contains(r)) {
                OBSERVERS.add(r);
            }
        }
    }

    public static void removeObserver(Runnable r) {
        synchronized (OBSERVERS) {
            OBSERVERS.remove(r);
        }
    }
}
