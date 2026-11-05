/// 迷你播放条：挂在主界面底部，显示正在试听的歌 + 播放/暂停 + 进度 + 关闭。
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
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
        Row(children: <Widget>[
          IconButton(
            tooltip: state.playing ? '暂停' : '继续',
            onPressed: p.toggle,
            icon: Icon(
              state.playing ? Icons.pause_circle_outline : Icons.play_circle_outline,
              size: 30,
              color: MoKit.primary(context),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Text(state.file.stem(),
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.text(context))),
              const SizedBox(height: 2),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
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
            ]),
          ),
          Text('${_mmss(state.positionMs)} / ${_mmss(state.durationMs)}',
              style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
          IconButton(
            tooltip: '关闭',
            onPressed: p.close,
            icon: Icon(Icons.close, size: 20, color: MoKit.sub(context)),
          ),
        ]),
      ]),
    );
  }
}
