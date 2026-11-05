/// 迷你播放条：挂在主界面 / 编辑页底部，试听控制。
///
/// 布局（用户指定）：控制按钮在进度条**上方**居中一行——左「快退 5 秒」、
/// 中「播放/暂停」、右「快进 5 秒」；进度条加高到约 0.5cm（19dp 轨道 +
/// 大拇指），整体高度约为初版的三倍，避免误触。
library;

import 'package:flutter/material.dart';

import '../app/ui_kit.dart';
import 'mini_player.dart';

/// 底部迷你播放条。没有正在播的歌时返回零高度占位。
class PlayBar extends StatelessWidget {
  const PlayBar({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: MiniPlayer.instance,
      builder: (BuildContext context, Widget? _) {
        final PlayerState? s = MiniPlayer.instance.state;
        if (s == null) return const SizedBox.shrink();
        return _Bar(state: s);
      },
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.state});

  final PlayerState state;

  static String _mmss(int ms) {
    final int total = (ms / 1000).round();
    return '${(total / 60).floor()}:${(total % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final MiniPlayer p = MiniPlayer.instance;
    return Container(
      decoration: BoxDecoration(
        color: MoKit.card(context),
        border: Border(
            top: BorderSide(color: MoKit.line(context), width: 0.5)),
      ),
      // 整体高度约三倍于初版：上 10 + 按钮行 56 + 进度区约 44 + 下 10 ≈ 120
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
        // 控制按钮行：快退 5s —— 播放/暂停 —— 快进 5s，居中
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            IconButton(
              tooltip: '快退 5 秒',
              onPressed: () => p.skip(-5),
              icon: Icon(Icons.replay_5, size: 34, color: MoKit.text(context)),
            ),
            const SizedBox(width: 28),
            IconButton(
              tooltip: state.playing ? '暂停' : '播放',
              onPressed: p.toggle,
              icon: Icon(
                state.playing
                    ? Icons.pause_circle_filled
                    : Icons.play_circle_filled,
                size: 52,
                color: MoKit.primary(context),
              ),
            ),
            const SizedBox(width: 28),
            IconButton(
              tooltip: '快进 5 秒',
              onPressed: () => p.skip(5),
              icon:
                  Icon(Icons.forward_5, size: 34, color: MoKit.text(context)),
            ),
          ],
        ),
        // 进度条：轨道 19dp ≈ 0.5cm（含大拇指总触摸区更高，好拖不误触）
        SizedBox(
          height: 44,
          child: Row(children: <Widget>[
            Text(_mmss(state.positionMs),
                style: TextStyle(
                    fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 19,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 12),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
                ),
                child: Slider(
                  value: state.durationMs > 0
                      ? state.positionMs.clamp(0, state.durationMs).toDouble()
                      : 0,
                  max: state.durationMs > 0 ? state.durationMs.toDouble() : 1,
                  onChanged: state.durationMs > 0
                      ? (double v) => p.seekTo(v.round())
                      : null,
                ),
              ),
            ),
            Text(_mmss(state.durationMs),
                style: TextStyle(
                    fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
          ]),
        ),
        // 歌名放最下面一行，占位小
        Text(state.file.stem(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
      ]),
    );
  }
}
