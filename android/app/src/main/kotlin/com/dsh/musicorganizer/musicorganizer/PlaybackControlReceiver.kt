package com.dsh.musicorganizer.musicorganizer

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** 通知栏媒体控制按钮 → [PlaybackNotificationService.emit] → MiniPlayerPlugin。 */
class PlaybackControlReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val cmd = intent.action ?: return
        PlaybackNotificationService.emit(cmd)
    }
}
