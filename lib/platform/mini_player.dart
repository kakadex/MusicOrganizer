/// 应用内迷你播放器（单曲试听）。
///
/// 安卓走原生 MediaPlayer（content uri 直播）；桌面用默认播放器打开
///（`openWithPlayer`）。播放状态用 [ChangeNotifier] 广播，PlayBar 订阅。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/log/log.dart';
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

  /// 播完自动接下一首的回调（0.3.5）：由页面层注册，返回 false 或不注册
  /// 都表示「没有下一首」，播放器保持播完停止的状态。
  /// 参数 fromUser 为 false 时表示这是自动连播（区别于通知栏按钮）。
  static Future<bool> Function()? onNextTrack;

  /// 最近一次播放的封面字节（通知卡显示用；由调用方在 play 时带上）。
  Uint8List? lastCover;

  PlayerState? state;
  Timer? _ticker;
  String? _error;

  /// 连续两次轮询到「没在播」：判定播完（避免个别状态抖动误判）。
  int _idleTicks = 0;

  /// 是否正在自动连播换歌（0.3.5）：换歌窗口期内（约 3 秒）轮询不再做
  /// 播完判定——新歌 prepare 期间 isPlaying=false 会被旧轮询误判成「播完」，
  /// 连跳两首就是这个机制（这也是真机「上一曲要点两次」的头号嫌疑）。
  bool _switching = false;
  Timer? _switchGuard;

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
        final String cmd = call.arguments as String? ?? '';
        // 探针（0.3.5）：Dart 侧收到命令即记一条，与原生 svc-emit 对账
        // ——原生发了 Dart 没收到 = 通道层丢；Dart 收了没反应 = 页面层问题。
        Log.info('[PlayerCmd] Dart 收到 cmd=$cmd');
        onCommand?.call(cmd);
      }
      return null;
    });
  }

  /// 播一首。安卓应用内播放；桌面退回系统默认播放器。
  Future<void> play(VFile f, {SafFileStore? saf, Future<String?> Function(VFile)? openExternal}) async {
    _error = null;
    _saf = saf;
    _openExternal = openExternal;
    // 换歌窗口（0.3.5）：从现在起到原生播放器真正开始播新歌之间，
    // isPlaying 必然返回 false。窗口期内轮询不做播完判定——否则上一首的
    // 轮询会把「正在换歌」误判成「上一首播完了」，再自动跳一首。
    _beginSwitchWindow();
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

  /// 换歌窗口管理（0.3.5）：play() 进门就开窗口，3 秒后自动关
  ///（prepare 毫秒级，3 秒是极宽裕的上限；期间轮询跳过播完判定）。
  void _beginSwitchWindow() {
    _switching = true;
    _switchGuard?.cancel();
    _switchGuard = Timer(const Duration(seconds: 3), () {
      _switching = false;
    });
  }

  /// 250ms 轮询进度（MediaPlayer 没有进度流，这是最省事的稳态做法）。
  /// 顺带做播完检测：播放中连续两次查到 isPlaying=false → 已播完，
  /// 播完触发 [onNextTrack] 自动连播（0.3.5；没注册或返回 false 就停在播完态）。
  void _startTicker() {
    _stopTicker();
    _idleTicks = 0;
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (Timer t) async {
      final PlayerState? s = state;
      if (s == null || !s.playing) return;
      // 换歌窗口期：新播放器还没起来，isPlaying 必然是 false，
      // 这段时间不做播完判定（否则会把「正在换歌」误判成「播完了」）
      if (_switching) return;
      try {
        final bool playing =
            await _ch.invokeMethod<bool>('isPlaying') ?? false;
        if (!playing) {
          _idleTicks++;
          if (_idleTicks >= 2) {
            // 播完（或被系统停了）：停在当前进度，按钮变「继续」；
            // 注册了自动连播就接着放下一首
            final int pos = await _ch.invokeMethod<int>('position') ?? s.positionMs;
            state = PlayerState(
                file: s.file,
                playing: false,
                durationMs: s.durationMs,
                positionMs: pos);
            _stopTicker();
            notifyListeners();
            final Future<bool> Function()? next = onNextTrack;
            if (next != null) {
              Log.info('[Player] 播完自动连播: ${s.file.stem()} 播完于 $pos ms');
              final bool ok = await next();
              if (!ok) Log.info('[Player] 自动连播：页面层返回无下一首');
            }
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
    _switchGuard?.cancel();
    _switchGuard = null;
    _switching = false;
  }

  @override
  void dispose() {
    _stopTicker();
    super.dispose();
  }

  /// 探针（0.3.5）：通知卡选曲命令的到达与执行结果，用于定位
  /// 「上一曲/下一曲偶发要点两次」。只记命令名、当前索引与结果，无隐私。
  static void Function(String stage, String detail)? probeSink;
}
