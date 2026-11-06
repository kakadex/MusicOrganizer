package com.dsh.musicorganizer.musicorganizer

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat

/**
 * 迷你播放器的通知栏控制（0.2.96 的系统控制窗口）。
 *
 * 用户切到其它应用后，通知栏应出现媒体样式的控制卡（歌名 + 播放/暂停 +
 * 停止），并且锁屏也能控制——这是 [MediaSessionCompat] 的标准能力。
 *
 * 架构：本服务只负责「显示通知 + 转发控制命令」，播放本身仍在
 * [MiniPlayerPlugin]（前台服务的通知需要持续的播放状态才有意义）。
 * 命令通过 [Companion.emit] 静态回调给插件实例，插件再走 MethodChannel
 * 通知 Dart 侧刷新界面状态——单一事实源仍是 Dart 的 MiniPlayer。
 */
class PlaybackNotificationService : Service() {

    private var session: MediaSessionCompat? = null

    override fun onCreate() {
        super.onCreate()
        val s = MediaSessionCompat(this, "MoMiniPlayer")
        s.setCallback(object : MediaSessionCompat.Callback() {
            override fun onPlay() = Companion.emit("play")
            override fun onPause() = Companion.emit("pause")
            override fun onStop() = Companion.emit("stop")
            override fun onSkipToNext() = Companion.emit("next")
            override fun onSkipToPrevious() = Companion.emit("prev")
            // 通知卡进度条拖动（0.3.2）：系统把目标位置（毫秒）发过来，
            // 转给插件在播放器上直接 seek，然后按新位置刷新通知。
            override fun onSeekTo(pos: Long) {
                Companion.emitSeek(pos)
            }
        })
        // 允许媒体按钮（蓝牙耳机线控等）路由进来
        s.setFlags(MediaSessionCompat.FLAG_HANDLES_MEDIA_BUTTONS or
                MediaSessionCompat.FLAG_HANDLES_TRANSPORT_CONTROLS)
        session = s
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: ""
        val artist = intent?.getStringExtra(EXTRA_ARTIST) ?: ""
        val playing = intent?.getBooleanExtra(EXTRA_PLAYING, false) ?: false
        val positionMs = intent?.getLongExtra(EXTRA_POSITION, 0L) ?: 0L
        val durationMs = intent?.getLongExtra(EXTRA_DURATION, 0L) ?: 0L
        val cover = intent?.getByteArrayExtra(EXTRA_COVER)

        // 必须在 startForeground 之前把 session 关联到通知（媒体样式才会生效）
        val meta = MediaMetadataCompat.Builder()
            .putString(MediaMetadataCompat.METADATA_KEY_TITLE, title.ifBlank { "正在试听" })
            .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, artist.ifBlank { "未知歌手" })
        // 时长必须有：系统靠它画可拖动的进度条；没有时通知卡不显示拖动条
        if (durationMs > 0) {
            meta.putLong(MediaMetadataCompat.METADATA_KEY_DURATION, durationMs)
        }
        // 封面位图：有的话媒体卡片左上角就会显示大图（与用户示例一致）
        if (cover != null && cover.isNotEmpty()) {
            meta.putBitmap(
                MediaMetadataCompat.METADATA_KEY_ALBUM_ART,
                android.graphics.BitmapFactory.decodeByteArray(cover, 0, cover.size)
            )
        }
        session?.setMetadata(meta.build())
        session?.setPlaybackState(
            PlaybackStateCompat.Builder()
                .setActions(
                    PlaybackStateCompat.ACTION_PLAY or
                        PlaybackStateCompat.ACTION_PAUSE or
                        PlaybackStateCompat.ACTION_STOP or
                        PlaybackStateCompat.ACTION_SKIP_TO_NEXT or
                        PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS or
                        PlaybackStateCompat.ACTION_SEEK_TO)
                .setState(
                    if (playing) PlaybackStateCompat.STATE_PLAYING
                    else PlaybackStateCompat.STATE_PAUSED,
                    positionMs, if (playing) 1f else 0f)
                .build()
        )

        startForeground(NOTIFICATION_ID, buildNotification(title, playing, positionMs, durationMs))
        return START_NOT_STICKY
    }

    private fun buildNotification(title: String, playing: Boolean, positionMs: Long, durationMs: Long): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            if (manager.getNotificationChannel(CHANNEL_ID) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, "试听播放", NotificationManager.IMPORTANCE_LOW).apply {
                        description = "音乐整理的试听播放控制"
                        setShowBadge(false)
                    }
                )
            }
        }
        val openApp = PendingIntent.getActivity(
            this, 0,
            packageManager.getLaunchIntentForPackage(packageName)
                ?.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val style = androidx.media.app.NotificationCompat.MediaStyle()
            .setMediaSession(session?.sessionToken)
            .setShowActionsInCompactView(0, 1, 2)

        val b = androidx.core.app.NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(title.ifBlank { "音乐整理 · 试听" })
            .setContentIntent(openApp)
            .setOngoing(playing)
            .setOnlyAlertOnce(true)
            .setStyle(style)
            .setVisibility(androidx.core.app.NotificationCompat.VISIBILITY_PUBLIC)
            .addAction(action(android.R.drawable.ic_media_previous, "上一首", "prev"))
            .addAction(
                action(
                    if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
                    if (playing) "暂停" else "播放",
                    if (playing) "pause" else "play"))
            .addAction(action(android.R.drawable.ic_media_next, "下一首", "next"))

        // 播放中不显示停止（通知可滑动划掉=隐式停止）；暂停时给显式停止
        if (!playing) {
            b.addAction(action(android.R.drawable.ic_delete, "停止", "stop"))
        }
        return b.build()
    }

    private fun action(icon: Int, label: String, cmd: String): androidx.core.app.NotificationCompat.Action {
        val pi = PendingIntent.getBroadcast(
            this, cmd.hashCode(),
            Intent(this, PlaybackControlReceiver::class.java).apply { action = cmd },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return androidx.core.app.NotificationCompat.Action(icon, label, pi)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        session?.release()
        session = null
        instance = null
        super.onDestroy()
    }

    companion object {
        const val CHANNEL_ID = "mo_playback"
        const val NOTIFICATION_ID = 7702
        const val EXTRA_TITLE = "title"
        const val EXTRA_ARTIST = "artist"
        const val EXTRA_PLAYING = "playing"
        const val EXTRA_POSITION = "position"
        const val EXTRA_DURATION = "duration"
        const val EXTRA_COVER = "cover"

        @Volatile
        var instance: PlaybackNotificationService? = null
            private set

        /// 命令回调（由 MiniPlayerPlugin 注册；通知按钮 → 插件 → Dart）
        @Volatile
        var commandSink: ((String) -> Unit)? = null

        /// 拖动进度回调（由 MiniPlayerPlugin 注册）：毫秒 → 插件 seek 播放器
        @Volatile
        var seekSink: ((Long) -> Unit)? = null

        fun emit(cmd: String) {
            commandSink?.invoke(cmd)
        }

        fun emitSeek(posMs: Long) {
            seekSink?.invoke(posMs)
        }

        /// 更新通知内容（由 MiniPlayerPlugin 在播放/暂停/停歌时调用）。
        fun update(
            context: Context,
            title: String,
            artist: String,
            playing: Boolean,
            positionMs: Long = 0L,
            durationMs: Long = 0L,
            cover: ByteArray? = null,
        ) {
            val intent = Intent(context, PlaybackNotificationService::class.java)
                .putExtra(EXTRA_TITLE, title)
                .putExtra(EXTRA_ARTIST, artist)
                .putExtra(EXTRA_PLAYING, playing)
                .putExtra(EXTRA_POSITION, positionMs)
                .putExtra(EXTRA_DURATION, durationMs)
            cover?.let { intent.putExtra(EXTRA_COVER, it) }
            if (Build.VERSION.SDK_INT >= 26) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, PlaybackNotificationService::class.java))
        }
    }
}
