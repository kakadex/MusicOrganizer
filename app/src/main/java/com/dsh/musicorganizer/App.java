package com.dsh.musicorganizer;

import android.app.Application;
import android.os.Process;

import java.io.File;
import java.io.FileWriter;
import java.io.PrintWriter;
import java.io.StringWriter;

/**
 * 自定义 Application：安装全局未捕获异常处理器。
 * 任何线程发生未捕获异常时，先把堆栈写入内部文件 last_crash.txt（留痕），
 * 再交给系统默认处理器（弹"应用已停止"）。
 * 由于 MainActivity 启动期的大部分逻辑已被同步 try-catch 覆盖并显示在屏幕上，
 * 这里主要用于兜底（覆盖极少数同步 try 包不住的路径，并保留崩溃证据）。
 */
public class App extends Application {

    public static final String CRASH_FILE = "last_crash.txt";

    @Override
    public void onCreate() {
        super.onCreate();
        // 日志落盘（v0.1.9）：内存里的日志一崩溃就没了，先装好目录再装崩溃处理
        com.dsh.musicorganizer.core.AppLog.install(
                new File(getFilesDir(), "logs"));
        final Thread.UncaughtExceptionHandler def =
                Thread.getDefaultUncaughtExceptionHandler();
        Thread.setDefaultUncaughtExceptionHandler(
                new Thread.UncaughtExceptionHandler() {
                    @Override
                    public void uncaughtException(Thread thread, Throwable ex) {
                        try {
                            StringWriter sw = new StringWriter();
                            PrintWriter pw = new PrintWriter(sw);
                            pw.println("thread=" + thread.getName());
                            ex.printStackTrace(pw);
                            pw.flush();
                            String text = sw.toString();
                            File f = new File(getFilesDir(), CRASH_FILE);
                            FileWriter fw = new FileWriter(f);
                            fw.write(text);
                            fw.close();
                            // 同步写进持久化日志：导出日志时能带上崩溃堆栈
                            com.dsh.musicorganizer.core.AppLog.writeSync(
                                    com.dsh.musicorganizer.core.AppLog.ERROR, "crash", text);
                        } catch (Throwable ignore) {
                            // 写文件失败也不要影响后续
                        }
                        if (def != null) {
                            def.uncaughtException(thread, ex);
                        } else {
                            Process.killProcess(Process.myPid());
                        }
                    }
                });
    }
}
