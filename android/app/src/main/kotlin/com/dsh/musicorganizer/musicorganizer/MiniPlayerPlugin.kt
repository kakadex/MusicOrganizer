package com.dsh.musicorganizer.musicorganizer

import android.content.ContentResolver
import android.media.AudioAttributes
import android.media.MediaPlayer
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
) {

    private var player: MediaPlayer? = null
    private var channel: MethodChannel? = null
    private var preparedDocId: String? = null

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
                    else -> result.notImplemented()
                }
            }
        }
    }

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
    }
}
