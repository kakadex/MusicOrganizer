/// 应用内迷你播放器（单曲试听）。
///
/// 安卓走原生 MediaPlayer（content uri 直播）；桌面用默认播放器打开
///（`openWithPlayer`）。播放状态用 [ChangeNotifier] 广播，PlayBar 订阅。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/model/vfile.dart';
import '../core/fs/saf_file_store.dart';

/// 播放中的歌 + 进度。
class PlayerState {
  const PlayerState({
    required this.file,
    required this.playing,
    this.durationMs = 0,
    this.positionMs = 0,
  });

  final VFile file;
  final bool playing;
  final int durationMs;
  final int positionMs;
}

/// 迷你播放器控制器（全局单例）。
class MiniPlayer extends ChangeNotifier {
  MiniPlayer._();

  static final MiniPlayer instance = MiniPlayer._();

  static const MethodChannel _ch =
      MethodChannel('com.dsh.musicorganizer/player');

  PlayerState? state;
  Timer? _ticker;
  String? _error;

  /// 连续两次轮询到「没在播」：判定播完（避免个别状态抖动误判）。
  int _idleTicks = 0;

  /// 最近一次错误（界面上显示过就清）。
  String? get error => _error;
  void clearError() {
    _error = null;
    notifyListeners();
  }

  /// 预热（main/shell 里调一次）。本实现不依赖原生事件流——播完检测
  /// 由进度轮询顺带完成（连续两次「没在播」即算播完），桌面端零开销。
  void wire() {}

  /// 播一首。安卓应用内播放；桌面退回系统默认播放器。
  Future<void> play(VFile f, {SafFileStore? saf, Future<String?> Function(VFile)? openExternal}) async {
    _error = null;
    if (saf != null) {
      try {
        final String? uri = await saf.playerUri(f);
        if (uri == null) {
          _error = '拿不到文件位置';
          notifyListeners();
          return;
        }
        final String? err = await _ch.invokeMethod<String>(
            'play', <String, Object?>{'uri': uri, 'docId': f.docId});
        if (err != null) {
          _error = err;
          notifyListeners();
          return;
        }
        final int duration =
            await _ch.invokeMethod<int>('duration') ?? 0;
        state = PlayerState(file: f, playing: true, durationMs: duration);
        _startTicker();
        notifyListeners();
        return;
      } on MissingPluginException {
        // 落到下面的桌面路径
      } on PlatformException catch (e) {
        _error = '播放失败：${e.message ?? e.code}';
        notifyListeners();
        return;
      }
    }
    // 桌面（或安卓插件缺失时兜底）：用系统默认播放器
    if (openExternal != null) {
      final String? err = await openExternal(f);
      if (err != null) _error = err;
    }
    notifyListeners();
  }

  Future<void> toggle() async {
    final PlayerState? s = state;
    if (s == null) return;
    try {
      if (s.playing) {
        await _ch.invokeMethod<void>('pause');
        state = PlayerState(
            file: s.file,
            playing: false,
            durationMs: s.durationMs,
            positionMs: s.positionMs);
      } else {
        await _ch.invokeMethod<void>('resume');
        state = PlayerState(
            file: s.file,
            playing: true,
            durationMs: s.durationMs,
            positionMs: s.positionMs);
      }
      notifyListeners();
    } on MissingPluginException {
      // 无通道（桌面）：忽略
    } on PlatformException {
      // 忽略
    }
  }

  Future<void> seekTo(int ms) async {
    try {
      await _ch.invokeMethod<void>('seek', <String, Object?>{'ms': ms});
      final PlayerState? s = state;
      if (s != null) {
        state = PlayerState(
            file: s.file,
            playing: s.playing,
            durationMs: s.durationMs,
            positionMs: ms);
        notifyListeners();
      }
    } on Exception {
      // 拖动失败不影响播放
    }
  }

  Future<void> close() async {
    try {
      await _ch.invokeMethod<void>('stop');
    } on Exception {
      // 桌面无通道
    }
    _stopTicker();
    state = null;
    notifyListeners();
  }

  /// 250ms 轮询进度（MediaPlayer 没有进度流，这是最省事的稳态做法）。
  /// 顺带做播完检测：播放中连续两次查到 isPlaying=false → 已播完。
  void _startTicker() {
    _stopTicker();
    _idleTicks = 0;
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (Timer t) async {
      final PlayerState? s = state;
      if (s == null || !s.playing) return;
      try {
        final bool playing =
            await _ch.invokeMethod<bool>('isPlaying') ?? false;
        if (!playing) {
          _idleTicks++;
          if (_idleTicks >= 2) {
            // 播完（或被系统停了）：停在当前进度，按钮变「继续」
            final int pos = await _ch.invokeMethod<int>('position') ?? s.positionMs;
            state = PlayerState(
                file: s.file,
                playing: false,
                durationMs: s.durationMs,
                positionMs: pos);
            _stopTicker();
            notifyListeners();
          }
          return;
        }
        _idleTicks = 0;
        final int pos = await _ch.invokeMethod<int>('position') ?? 0;
        final int dur = await _ch.invokeMethod<int>('duration') ?? s.durationMs;
        state = PlayerState(
            file: s.file, playing: true, durationMs: dur, positionMs: pos);
        notifyListeners();
      } on Exception {
        t.cancel();
      }
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  @override
  void dispose() {
    _stopTicker();
    super.dispose();
  }
}
