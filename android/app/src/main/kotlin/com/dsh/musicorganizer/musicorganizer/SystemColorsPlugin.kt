package com.dsh.musicorganizer.musicorganizer

import android.content.Context
import android.content.res.Resources
import android.os.Build
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 读取 Android 12+ 的系统动态色（Material You 壁纸取色）。
 *
 * 为什么自己读资源、不引 `dynamic_color` 包：项目一贯零新增依赖，而这个插件
 * 只是把 `system_accent*` / `system_neutral*` 的 65 个色值读出来交给 Dart，
 * 一个文件就够（0.3.17）。
 *
 * 键名约定：`a1_600` / `n1_50` 这类「短名_色调」，与 Dart 侧
 * `MoPalette.fromSystem` 的取值一致。
 */
class SystemColorsPlugin(private val context: Context) :
    MethodChannel.MethodCallHandler {

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "getPalette") {
            result.notImplemented()
            return
        }
        // 12 以下没有动态色：返回 null，Dart 侧回退固定色板（不是错误）。
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            result.success(null)
            return
        }
        try {
            val tones = listOf(0, 10, 50, 100, 200, 300, 400, 500, 600, 700, 800, 900, 1000)
            val system = Resources.getSystem()
            val map = HashMap<String, Int>()
            fun put(short: String, name: String) {
                val id = system.getIdentifier(name, "color", "android")
                if (id != 0) {
                    // 必须走 ContextCompat（经过应用 theme overlay）：直接
                    // Resources.getSystem().getColor 拿不到动态色。
                    map["${short}_${name.substringAfterLast('_')}"] =
                        ContextCompat.getColor(context, id)
                }
            }
            for (t in tones) {
                put("a1", "system_accent1_$t")
                put("a2", "system_accent2_$t")
                put("n1", "system_neutral1_$t")
                put("n2", "system_neutral2_$t")
            }
            // 部分 OEM 关掉了 flag_monet：此时读到的是 AOSP 默认 Material 色，
            // 仍然是合法配色，照用；一个都读不到才回退。
            result.success(if (map.isEmpty()) null else map)
        } catch (_: Throwable) {
            // 取色失败不许挡启动。
            result.success(null)
        }
    }
}
