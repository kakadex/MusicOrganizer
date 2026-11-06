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

  /// 通知栏控制按钮的回调（原生 → Dart）：next/prev 由页面层注册处理。
  /// 0.2.96 起通知栏有媒体控制卡，上一首/下一首要由 Dart 选曲。
  static void Function(String cmd)? onCommand;

  /// 最近一次播放的封面字节（通知卡显示用；由调用方在 play 时带上）。
  Uint8List? lastCover;

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

  /// 预热（main/shell 里调一次）。监听通知栏按钮命令（next/prev 等选曲类）。
  void wire() {
    _ch.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'onCommand') {
        onCommand?.call(call.arguments as String? ?? '');
      }
      return null;
    });
  }

  /// 播一首。安卓应用内播放；桌面退回系统默认播放器。
  Future<void> play(VFile f, {SafFileStore? saf, Future<String?> Function(VFile)? openExternal}) async {
    _error = null;
    _saf = saf;
    _openExternal = openExternal;
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
        // 0.2.96：通知栏媒体控制卡（切到其它应用也能看到/控制）
        await _ch.invokeMethod<void>('updateNotification', <String, Object?>{
          'title': f.stem(),
          'artist': '音乐整理',
          'playing': true,
          'position': 0,
          'duration': duration,
          if (lastCover != null) 'cover': lastCover,
        });
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

  /// 播放/暂停切换。**总是以当前登记的 [PlayerState.file] 为准**：
  /// 继续播放也走 play 重新交付（原生侧同一首会秒续），避免「暂停了旧的
  /// 又选了新的，点播放却把旧的续上」——resume 只认播放器里的旧实例。
  Future<void> toggle() async {
    final PlayerState? s = state;
    if (s == null) return;
    if (s.playing) {
      try {
        await _ch.invokeMethod<void>('pause');
        state = PlayerState(
            file: s.file,
            playing: false,
            durationMs: s.durationMs,
            positionMs: s.positionMs);
        await _syncNotification(s.file, false, s.positionMs, s.durationMs);
        notifyListeners();
      } on Exception {
        // 忽略
      }
    } else {
      await playCurrent();
    }
  }

  /// 同步通知栏控制卡状态（播放/暂停/进度）。
  Future<void> _syncNotification(
      VFile f, bool playing, int positionMs, int durationMs) async {
    try {
      await _ch.invokeMethod<void>('updateNotification', <String, Object?>{
        'title': f.stem(),
        'artist': '音乐整理',
        'playing': playing,
        'position': positionMs,
        'duration': durationMs,
        if (lastCover != null) 'cover': lastCover,
      });
    } on Exception {
      // 桌面无通道
    }
  }

  /// 重新交付当前登记的歌（原生侧同一首 docId 会快速续播不重头）。
  Future<void> playCurrent() async {
    final PlayerState? s = state;
    if (s == null) return;
    await play(s.file, saf: _saf, openExternal: _openExternal);
  }

  SafFileStore? _saf;
  Future<String?> Function(VFile)? _openExternal;

  /// 快退 / 快进 [seconds] 秒（拖进度用，边界自动钳住）。
  Future<void> skip(int seconds) async {
    final PlayerState? s = state;
    if (s == null) return;
    final int target = (s.positionMs + seconds * 1000)
        .clamp(0, s.durationMs <= 0 ? s.positionMs : s.durationMs);
    await seekTo(target);
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
        unawaited(_syncNotification(s.file, s.playing, ms, s.durationMs));
        notifyListeners();
      }
    } on Exception {
      // 拖动失败不影响播放
    }
  }

  Future<void> close() async {
    try {
      await _ch.invokeMethod<void>('stop');
      await _ch.invokeMethod<void>('stopService');
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
