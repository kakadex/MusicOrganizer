package com.dsh.musicorganizer.musicorganizer

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * 长任务前台服务。
 *
 * 批量匹配 / 写标签 / 补封面这类任务要跑几分钟，用户切到别的 App 之后
 * 普通后台进程随时会被系统回收。挂一条常驻通知把进程标成「前台」，
 * 任务才能跑完；任务结束就立刻 stopSelf，通知随即消失。
 */
class TaskForegroundService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> stopSelf()
            else -> {
                val title = intent?.getStringExtra(EXTRA_TITLE) ?: "正在处理"
                val text = intent?.getStringExtra(EXTRA_TEXT) ?: ""
                val done = intent?.getIntExtra(EXTRA_DONE, 0) ?: 0
                val total = intent?.getIntExtra(EXTRA_TOTAL, 0) ?: 0
                startForegroundCompat(buildNotification(title, text, done, total))
            }
        }
        return START_NOT_STICKY
    }

    private fun startForegroundCompat(notification: Notification) {
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
        @Suppress("DEPRECATION")
        if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_REMOVE)
        else stopForeground(true)
        super.onDestroy()
    }

    companion object {
        const val CHANNEL_ID = "mo_task"
        const val NOTIFICATION_ID = 7701
        const val ACTION_STOP = "com.dsh.musicorganizer.action.STOP_TASK"
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
        const val EXTRA_DONE = "done"
        const val EXTRA_TOTAL = "total"
    }
}
