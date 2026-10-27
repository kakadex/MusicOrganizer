package com.dsh.musicorganizer.musicorganizer

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.SystemClock

/**
 * 长任务前台服务。
 *
 * 批量匹配 / 写标签 / 补封面这类任务要跑几分钟，用户切到别的 App 之后
 * 普通后台进程随时会被系统回收。挂一条常驻通知把进程标成「前台」，
 * 任务才能跑完；任务结束就立刻收尾。
 *
 * **停止是一条命令，不是一个开关**：调用方不再 stopService，而是发一条
 * [ACTION_STOP]，由本服务在 [onStartCommand] 里自己消费。启动与停止因此落在
 * 同一条命令队列上、先来先处理——「还没进前台就被外部硬停」这条崩溃路径
 * （Android 12+ 的 ForegroundServiceDidNotStartInTime）在时序上就不存在了，
 * 不需要靠跨方法维护的静态标志去兜。
 */
class TaskForegroundService : Service() {

    /// 本次实例是否已经满足前台契约（只在 [handleStart] 里置位）。
    @Volatile
    private var foregroundStarted = false

    /// 停止命令到达时启动命令还没处理：先记下，由启动分支收尾。
    private var pendingStop = false

    /// 本次实例是否收到过启动命令（用来识别「服务是被停止命令唤醒的」）。
    private var sawStart = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        trace("onCreate")
    }

    /// 只更新通知内容：服务已经在跑时走这里，不要再 startForegroundService。
    fun update(title: String, text: String, done: Int, total: Int) {
        val n = buildNotification(title, text, done, total)
        manager().notify(NOTIFICATION_ID, n)
        // 已经进过前台时再调一次也无副作用，顺手保证系统那边的「5 秒内进前台」要求
        if (foregroundStarted) runCatching { startForegroundCompat(n) }
    }

    private fun manager(): NotificationManager =
        getSystemService(NotificationManager::class.java)

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> handleStop()
            else -> handleStart(intent)
        }
        return START_NOT_STICKY
    }

    private fun handleStart(intent: Intent?) {
        sawStart = true
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "正在处理"
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: ""
        val done = intent?.getIntExtra(EXTRA_DONE, 0) ?: 0
        val total = intent?.getIntExtra(EXTRA_TOTAL, 0) ?: 0
        trace("ACTION_START")
        // 每次 startForegroundService 都必须在 5 秒内 startForeground，否则系统直接杀进程。
        val started = runCatching { startForegroundCompat(buildNotification(title, text, done, total)) }
        if (started.isSuccess) {
            foregroundStarted = true
            trace("startForeground ok")
            // 停止命令可能比这次启动排得更早：契约已经满足，现在可以收尾了
            if (pendingStop) {
                trace("pendingStop -> stopSelf")
                stopSelf()
            }
        } else {
            // 进不了前台就诚实收尾：让前台状态说谎的话，后续更新会一直走
            // 「只刷通知」的分支，永远进不了前台，系统 5 秒后照样杀进程且无迹可查。
            android.util.Log.e("MO", "startForeground failed", started.exceptionOrNull())
            trace("startForeground failed")
            stopSelf()
        }
    }

    private fun handleStop() {
        trace("ACTION_STOP foregroundStarted=$foregroundStarted sawStart=$sawStart")
        when {
            // 已经在前台：直接收尾
            foregroundStarted -> stopSelf()
            // 服务是被停止命令唤醒的，没有启动在排队：别让服务空转在那儿
            !sawStart -> stopSelf()
            // 启动命令还在后面排队：契约由它来满足，这里只记一笔
            else -> pendingStop = true
        }
    }

    /**
     * Android 15（API 35）起 dataSync 这类前台服务有累计运行时长上限，
     * 到点系统会回调这里；不自己收尾就会抛 RemoteServiceException。
     */
    override fun onTimeout(startId: Int) {
        trace("onTimeout startId=$startId -> stopSelf")
        stopSelf()
    }

    private fun startForegroundCompat(notification: Notification) {
        // API 34+ 必须带类型、且清单里要声明对应权限，否则抛 SecurityException
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun buildNotification(title: String, text: String, done: Int, total: Int): Notification {
        ensureChannel()
        val builder = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
        if (total > 0) {
            builder.setContentText("$text（$done/$total）").setProgress(total, done, false)
        } else if (text.isNotEmpty()) {
            builder.setContentText(text)
        }
        if (Build.VERSION.SDK_INT >= 31) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }
        return builder.build()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < 26) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "整理任务",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "批量匹配、写入与封面任务进行中"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    override fun onDestroy() {
        // 先改状态再撤前台：调用方看到「不在前台」会重新走启动流程，
        // 服务能再次进前台，不会撞 5 秒超时。实例级状态随之复位。
        trace("onDestroy")
        foregroundStarted = false
        pendingStop = false
        sawStart = false
        instance = null
        @Suppress("DEPRECATION")
        if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_REMOVE)
        else stopForeground(true)
        super.onDestroy()
    }

    /// 一条线打完整个前台服务生命周期，出问题时 grep FgsTrace 就能还原时间线。
    private fun trace(msg: String) {
        android.util.Log.d(
            TRACE_TAG,
            "$msg ts=${SystemClock.uptimeMillis()} pid=${android.os.Process.myPid()}"
        )
    }

    companion object {
        @Volatile
        var instance: TaskForegroundService? = null
            private set

        /// 服务实例是否还在（决定「更新」是走通知还是再起一次服务）。
        fun isRunning(): Boolean = instance != null

        /// 服务是否已经满足前台契约（决定「停止」能不能直接 stopService）。
        fun isForeground(): Boolean = instance?.foregroundStarted == true

        const val CHANNEL_ID = "mo_task"
        const val NOTIFICATION_ID = 7701
        const val TRACE_TAG = "FgsTrace"
        const val ACTION_START = "com.dsh.musicorganizer.action.START_TASK"
        const val ACTION_STOP = "com.dsh.musicorganizer.action.STOP_TASK"
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
        const val EXTRA_DONE = "done"
        const val EXTRA_TOTAL = "total"
        const val EXTRA_SEQ = "seq"
    }
}
