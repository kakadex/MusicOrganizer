package com.dsh.musicorganizer.ui;

import android.os.Handler;
import android.os.Looper;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** 后台任务执行器：单线程顺序执行，结果回主线程。 */
public final class Tasks {

    private Tasks() {
    }

    private static final ExecutorService EXEC = Executors.newSingleThreadExecutor();
    private static final Handler MAIN = new Handler(Looper.getMainLooper());

    public interface Job {
        Object run() throws Exception;
    }

    public interface Callback {
        void done(Object result, Exception error);
    }

    public static void run(final Job job, final Callback callback) {
        EXEC.submit(new Runnable() {
            @Override
            public void run() {
                Object result = null;
                Exception error = null;
                try {
                    result = job.run();
                } catch (Exception e) {
                    error = e;
                }
                final Object r = result;
                final Exception e = error;
                MAIN.post(new Runnable() {
                    @Override
                    public void run() {
                        callback.done(r, e);
                    }
                });
            }
        });
    }

    public static void main(Runnable r) {
        MAIN.post(r);
    }
}
