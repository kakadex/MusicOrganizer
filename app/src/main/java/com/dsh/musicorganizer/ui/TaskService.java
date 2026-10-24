package com.dsh.musicorganizer.ui;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;

import com.dsh.musicorganizer.core.TaskControl;

/**
 * 前台服务 —— 让长任务（联网匹配 / 批量歌词 / 整理扫描）在退到后台后继续运行，
 * 并在通知栏提供实时进度与「暂停 / 继续」「停止」操作。
 *
 * 零第三方依赖：只用框架 Notification.Builder（API 26+ 走通知渠道）。
 */
public class TaskService extends Service {

    public static final String ACTION_START = "com.dsh.musicorganizer.TASK_START";
    public static final String ACTION_TOGGLE = "com.dsh.musicorganizer.TASK_TOGGLE";
    public static final String ACTION_STOP = "com.dsh.musicorganizer.TASK_STOP";

    private static final String CHANNEL_ID = "mo_task_progress";
    private static final int NOTIFY_ID = 1001;

    // ------------------------------------------------------------------
    // 外部入口
    // ------------------------------------------------------------------

    /**
     * 「希望服务处于前台」的意图标记。
     *
     * <p>为什么需要它：{@code startForegroundService()} 只是「预约」，服务真正创建可能要几百毫秒，
     * 而任务可能在这之前就已经跑完并调用了 {@link #stop}。此时 {@code stopService} 找不到运行中的服务、
     * 等于空操作，随后预约被兑现 —— 于是出现一条「任务早就结束了」的僵尸进度通知，
     * 前台服务永不退出。反过来，进程被系统回收后重启（静态变量全丢）、
     * 预约送达时 {@code TaskCenter.current()} 为 null，若此时直接 return 而不调 {@code startForeground()}，
     * 系统就会抛 {@code ForegroundServiceDidNotStartInTimeException} 把应用崩掉。
     */
    private static volatile boolean wantRunning = false;

    public static void start(Context ctx) {
        wantRunning = true;
        try {
            Intent intent = new Intent(ctx, TaskService.class).setAction(ACTION_START);
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                ctx.startForegroundService(intent);
            } else {
                ctx.startService(intent);
            }
        } catch (Throwable ignored) {
            // Android 12+ 后台启动前台服务受限；失败不影响任务本身，只是没有通知栏进度
            wantRunning = false;
        }
    }

    public static void stop(Context ctx) {
        wantRunning = false;
        try {
            ctx.stopService(new Intent(ctx, TaskService.class));
        } catch (Throwable ignored) {
        }
    }

    /** 刷新通知栏进度（任意线程可调）。 */
    public static void update(Context ctx) {
        if (ctx == null) {
            return;
        }
        try {
            NotificationManager nm =
                    (NotificationManager) ctx.getSystemService(Context.NOTIFICATION_SERVICE);
            if (nm == null) {
                return;
            }
            TaskControl c = TaskCenter.current();
            if (c == null || c.isFinished()) {
                // 任务已收尾：必须把通知撤掉。这条通知带 setOngoing(true)，
                // 若服务恰好没起来（后台受限），没人会替我们调用 stopForeground，
                // 它会永远贴在通知栏上、连滑都滑不掉。
                nm.cancel(NOTIFY_ID);
                return;
            }
            nm.notify(NOTIFY_ID, build(ctx, c));
        } catch (Throwable ignored) {
        }
    }

    // ------------------------------------------------------------------
    // Service 生命周期
    // ------------------------------------------------------------------

    @Override
    public void onCreate() {
        super.onCreate();
        // 建渠道失败绝不能把 onCreate 抛死：那样 onStartCommand 永远不会执行，
        // 系统只会看到「服务没进前台」，照样抛 ForegroundServiceDidNotStartInTimeException。
        try {
            createChannel();
        } catch (Throwable t) {
            com.dsh.musicorganizer.core.AppLog.write(
                    com.dsh.musicorganizer.core.AppLog.WARN, "TaskService",
                    "创建通知渠道失败：" + t);
        }
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        String action = intent == null ? ACTION_START : intent.getAction();
        // 铁律：这里必须先 startForeground()，且不能因为任何判断提前 return。
        // 由 startForegroundService() 拉起的服务若 5 秒内没调用它，系统会抛
        // ForegroundServiceDidNotStartInTimeException 直接崩溃（与业务逻辑成败无关）。
        if (!goForeground()) {
            stopSelf();
            return START_NOT_STICKY;
        }

        TaskControl control = TaskCenter.current();
        if (control == null) {
            // 预约送达时任务已经不在了（进程被重启 / 任务秒结束）：先把前台站住再退，
            // 顺序反了就是上面那个崩溃。用 stopSelf(startId) 而不是 stopSelf()，
            // 万一此刻已经有下一轮 start 排在后面，服务不能被我这次收尾顺手关掉。
            stopSelf(startId);
            return START_NOT_STICKY;
        }
        if (ACTION_TOGGLE.equals(action)) {
            control.togglePause();
        } else if (ACTION_STOP.equals(action)) {
            control.cancel();
        }
        if (control.isFinished() || !wantRunning) {
            // 任务在服务创建完成之前就结束了，别留下一条永远不会消失的进度通知
            stopSelf(startId);
            return START_NOT_STICKY;
        }
        if (ACTION_TOGGLE.equals(action) || ACTION_STOP.equals(action)) {
            update(this);
        }
        return START_NOT_STICKY;
    }

    @Override
    public void onDestroy() {
        wantRunning = false;
        try {
            stopForeground(true);
        } catch (Throwable ignored) {
        }
        super.onDestroy();
    }

    /**
     * 进入前台并挂上通知。失败时返回 false（调用方必须立即 stopSelf，不能继续裸跑）。
     *
     * <p>Android 10+ 显式声明 dataSync 类型：清单里已写，这里再传一次是为了
     * 「清单被改坏 / 系统按启动方推断类型」时也能明确自己的身份。
     */
    private boolean goForeground() {
        TaskControl control = TaskCenter.current();
        Notification n = control == null ? idleNotification(this) : build(this, control);
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFY_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC);
            } else {
                startForeground(NOTIFY_ID, n);
            }
            return true;
        } catch (Throwable t) {
            // 少数机型在通知被全局关闭 / 后台启动受限时会拒绝，绝不能把它咽下去后继续裸跑
            com.dsh.musicorganizer.core.AppLog.write(
                    com.dsh.musicorganizer.core.AppLog.WARN, "TaskService",
                    "startForeground 失败：" + t);
            return false;
        }
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    // ------------------------------------------------------------------
    // 通知构建
    // ------------------------------------------------------------------

    private void createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return;
        }
        NotificationManager nm =
                (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        if (nm == null || nm.getNotificationChannel(CHANNEL_ID) != null) {
            return;
        }
        NotificationChannel ch = new NotificationChannel(CHANNEL_ID, "任务进度",
                NotificationManager.IMPORTANCE_LOW);
        ch.setDescription("联网匹配 / 批量歌词 / 整理任务的进度");
        ch.setShowBadge(false);
        nm.createNotificationChannel(ch);
    }

    /**
     * 兜底通知：任务已经不在（或进程被重启过）时，也要有一条合法通知，
     * 才能完成「先进前台再退出」这个动作。内容尽量中性，避免用户看到「0/0」这种怪数字。
     */
    private static Notification idleNotification(Context ctx) {
        Notification.Builder b;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            b = new Notification.Builder(ctx, CHANNEL_ID);
        } else {
            b = new Notification.Builder(ctx);
        }
        b.setSmallIcon(android.R.drawable.stat_sys_download);
        b.setContentTitle("音乐整理");
        b.setContentText("任务已结束");
        b.setShowWhen(false);
        b.setOnlyAlertOnce(true);
        Intent open = new Intent(ctx, MainActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP);
        b.setContentIntent(PendingIntent.getActivity(ctx, 0, open, pendingFlags()));
        return b.build();
    }

    private static Notification build(Context ctx, TaskControl c) {
        Notification.Builder b;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            b = new Notification.Builder(ctx, CHANNEL_ID);
        } else {
            b = new Notification.Builder(ctx);
        }
        b.setSmallIcon(android.R.drawable.stat_sys_download);
        b.setContentTitle("音乐整理 · " + TaskCenter.title());
        b.setContentText(c.summary());

        int percent = c.percent();
        if (percent < 0) {
            b.setProgress(0, 0, true);
        } else {
            b.setProgress(100, percent, false);
        }
        b.setOngoing(true);
        b.setOnlyAlertOnce(true);
        b.setShowWhen(false);

        Intent open = new Intent(ctx, MainActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP);
        b.setContentIntent(PendingIntent.getActivity(ctx, 0, open,
                pendingFlags()));

        String toggleLabel = c.isPaused() ? "继续" : "暂停";
        int toggleIcon = c.isPaused()
                ? android.R.drawable.ic_media_play : android.R.drawable.ic_media_pause;
        b.addAction(new Notification.Action.Builder(toggleIcon, toggleLabel,
                PendingIntent.getService(ctx, 1,
                        new Intent(ctx, TaskService.class).setAction(ACTION_TOGGLE),
                        pendingFlags())).build());
        b.addAction(new Notification.Action.Builder(
                android.R.drawable.ic_menu_close_clear_cancel, "停止",
                PendingIntent.getService(ctx, 2,
                        new Intent(ctx, TaskService.class).setAction(ACTION_STOP),
                        pendingFlags())).build());
        return b.build();
    }

    private static int pendingFlags() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            return PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE;
        }
        return PendingIntent.FLAG_UPDATE_CURRENT;
    }
}
