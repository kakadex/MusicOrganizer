package com.dsh.musicorganizer.musicorganizer

import android.content.ContentResolver
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaPlayer
import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 应用内迷你播放器（单曲试听）。
 *
 * 用系统 [MediaPlayer] 播 SAF 文档：**不能直接把 content uri 喂给
 * setDataSource**（树内文档 uri 会报 0x80000000），必须先用
 * ContentResolver 打开文件描述符再交给播放器——这个错误就是踩过 0x2.81
 * 第一版之后修的。单实例：一次只播一首，播新的自动停旧的。
 * 事件（完成 / 出错）回推 Dart 侧刷新按钮状态。
 */
class MiniPlayerPlugin(
    private val engine: FlutterEngine,
    private val resolver: ContentResolver,
    private val audioManager: AudioManager,
    private val appContext: Context,
) {

    private var player: MediaPlayer? = null
    private var channel: MethodChannel? = null
    private var preparedDocId: String? = null

    /// 音频焦点请求（0.2.96 的播放只设了 AudioAttributes，没申请焦点——
    /// 结果与其它音乐 App 同时出声）。API 26+ 用 AudioFocusRequest，
    /// 更早版本走废弃的 requestAudioFocus 重载。
    private var focusRequest: AudioFocusRequest? = null
    private var hasFocus = false

    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        when (change) {
            AudioManager.AUDIOFOCUS_LOSS -> {
                // 永久失去（别的 App 长期占用）：彻底停掉，重置回未播放
                runCatching { player?.stop(); player?.release() }
                player = null
                preparedDocId = null
                hasFocus = false
                android.util.Log.d("MO", "player focus loss -> stop")
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                // 短暂失去（来电、导航播报）：暂停，回来后由用户自己继续
                runCatching { if (player?.isPlaying == true) player?.pause() }
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                // 短暂且可压低（提示音）：压低音量而不是停
                runCatching { player?.setVolume(0.15f, 0.15f) }
            }
            AudioManager.AUDIOFOCUS_GAIN -> {
                // 焦点回来了：恢复音量并继续播放
                runCatching {
                    player?.setVolume(1.0f, 1.0f)
                    if (preparedDocId != null && player?.isPlaying == false) player?.start()
                }
            }
        }
    }

    private fun requestFocus(): Boolean {
        if (hasFocus) return true
        val granted: Int
        if (android.os.Build.VERSION.SDK_INT >= 26) {
            val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build())
                .setOnAudioFocusChangeListener(focusListener)
                .build()
            focusRequest = req
            granted = audioManager.requestAudioFocus(req)
        } else {
            @Suppress("DEPRECATION")
            granted = audioManager.requestAudioFocus(
                focusListener,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN
            )
        }
        hasFocus = granted == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        return hasFocus
    }

    private fun abandonFocus() {
        if (!hasFocus) return
        runCatching {
            if (android.os.Build.VERSION.SDK_INT >= 26) {
                focusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
            } else {
                @Suppress("DEPRECATION")
                audioManager.abandonAudioFocus(focusListener)
            }
        }
        focusRequest = null
        hasFocus = false
    }

    companion object {
        const val CHANNEL = "com.dsh.musicorganizer/player"
    }

    fun attach(messenger: io.flutter.plugin.common.BinaryMessenger) {
        channel = MethodChannel(messenger, CHANNEL).also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "play" -> {
                        val uri = call.argument<String>("uri") ?: ""
                        val docId = call.argument<String>("docId") ?: ""
                        result.success(play(uri, docId))
                    }
                    "pause" -> {
                        runCatching { player?.pause() }
                        result.success(null)
                    }
                    "resume" -> {
                        runCatching { player?.start() }
                        result.success(null)
                    }
                    "stop" -> {
                        stop()
                        result.success(null)
                    }
                    "seek" -> {
                        val ms = (call.argument<Number>("ms") ?: 0).toInt()
                        runCatching { player?.seekTo(ms) }
                        result.success(null)
                    }
                    "position" -> result.success(player?.currentPosition ?: 0)
                    "duration" -> result.success(
                        if (player?.isPlaying == true || preparedDocId != null) player?.duration ?: 0
                        else 0
                    )
                    "isPlaying" -> result.success(runCatching { player?.isPlaying }.getOrNull() == true)
                    // 0.2.96：更新通知栏媒体控制卡（歌名/歌手/封面/进度/播放态）
                    "updateNotification" -> {
                        val ctx = appContext
                        if (ctx != null) {
                            PlaybackNotificationService.update(
                                ctx,
                                call.argument<String>("title") ?: "",
                                call.argument<String>("artist") ?: "",
                                call.argument<Boolean>("playing") ?: false,
                                (call.argument<Number>("position") ?: 0).toLong(),
                                (call.argument<Number>("duration") ?: 0).toLong(),
                                call.argument<ByteArray>("cover")
                            )
                        }
                        result.success(null)
                    }
                    // 通知栏「停止」按钮：彻底停掉并撤掉通知
                    "stopService" -> {
                        val ctx = appContext
                        stop()
                        ctx?.let { PlaybackNotificationService.stop(it) }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        // 通知按钮 / 蓝牙线控的命令 → 转发给 Dart 侧处理
        // （play/pause/stop 由插件本地直接执行；next/prev 必须由 Dart 选下一首）
        PlaybackNotificationService.commandSink = { cmd ->
            val ctx = appContext
            when (cmd) {
                "play" -> { requestFocus(); runCatching { player?.start() } }
                "pause" -> runCatching { player?.pause() }
                "stop" -> {
                    stop()
                    ctx?.let { PlaybackNotificationService.stop(it) }
                }
                else -> {
                    // next/prev 等「选曲」类命令：交给 Dart 决定播哪首
                    MethodChannel(messenger, CHANNEL).invokeMethod("onCommand", cmd)
                }
            }
            // 命令执行后刷新通知（播放态可能变了）
            ctx?.let { c ->
                player?.let { p ->
                    PlaybackNotificationService.update(
                        c, lastTitle, lastArtist,
                        runCatching { p.isPlaying }.getOrNull() == true,
                        runCatching { p.currentPosition.toLong() }.getOrDefault(0L),
                        runCatching { p.duration.toLong() }.getOrDefault(0L),
                        lastCover
                    )
                }
            }
        }
    }

    /// 通知卡显示用的元数据（由 Dart 在 play 时带给原生）
    var lastTitle: String = ""
    var lastArtist: String = ""
    var lastCover: ByteArray? = null

    /// 返回 null=已开始播放（或已在播这首），否则为错误文案。
    private fun play(uri: String, docId: String): String? {
        if (uri.isBlank()) return "无效的文件位置"
        // 同一首：播着就继续，暂停中就接着放
        if (docId == preparedDocId && player != null) {
            runCatching {
                if (player?.isPlaying == false) player?.start()
            }
            return null
        }
        // 先申请音频焦点：拿不到就礼貌地不播（其它 App 正在强占，如通话中）
        if (!requestFocus()) return "其它应用正在占用音频"
        stop()
        val p = MediaPlayer()
        return try {
            p.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build()
            )
            // 树内文档 uri 直接 setDataSource 会报 0x80000000：
            // 先开文件描述符（MediaPlayer 会复制一份 fd，用完即可关闭 pfd）
            val pfd = resolver.openFileDescriptor(android.net.Uri.parse(uri), "r")
                ?: return "打不开这个文件"
            val dsOk = runCatching { p.setDataSource(pfd.fileDescriptor) }
            pfd.close()
            dsOk.recover { throw it }.getOrThrow()
            p.setOnCompletionListener {
                // 播完：只复位「已备好」标记，界面状态由 Dart 侧轮询检测
                preparedDocId = null
            }
            p.setOnErrorListener { _, what, extra ->
                preparedDocId = null
                android.util.Log.d("MO", "player error what=$what extra=$extra")
                true
            }
            // setDataSource 后 prepare() 对 content uri 是本地读取，一般毫秒级；
            // 不用异步 prepareAsync，简化状态机（单曲试听场景卡一下无妨）。
            p.prepare()
            p.start()
            player = p
            preparedDocId = docId
            null
        } catch (e: Exception) {
            runCatching { p.release() }
            player = null
            preparedDocId = null
            "播不了：${e.message ?: e.javaClass.simpleName}"
        }
    }

    private fun stop() {
        player?.let { runCatching { it.stop(); it.release() } }
        player = null
        preparedDocId = null
        abandonFocus()
    }
}
