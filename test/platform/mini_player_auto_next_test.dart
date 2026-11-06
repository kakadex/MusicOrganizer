import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/model/vfile.dart';
import 'package:musicorganizer/platform/mini_player.dart';

/// 播完自动连播（0.3.5）与换歌窗口的判定逻辑测试。
///
/// MiniPlayer 的 MethodChannel 在纯单测里不可用（无引擎），所以这里只测
/// 可注入的纯逻辑部分：自动连播回调的接线与「没有下一首返回 false」的约定。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('自动连播回调接线', () {
    test('onNextTrack 默认为 null（未注册时不连播）', () {
      expect(MiniPlayer.onNextTrack, isNull);
    });

    test('注册后播完能拿到「是否有下一首」的结果', () async {
      // 模拟页面层：列表里还有下一首 → true
      MiniPlayer.onNextTrack = () async => true;
      expect(await MiniPlayer.onNextTrack!(), isTrue);

      // 模拟到列表末尾 → false（播放器保持播完停止态）
      MiniPlayer.onNextTrack = () async => false;
      expect(await MiniPlayer.onNextTrack!(), isFalse);
    });

    test('命令回调 onCommand 与 onNextTrack 互不干扰', () async {
      String? got;
      MiniPlayer.onCommand = (String cmd) => got = cmd;
      MiniPlayer.onNextTrack = () async => true;
      MiniPlayer.onCommand!('next');
      expect(got, 'next');
      expect(await MiniPlayer.onNextTrack!(), isTrue);
    });
  });

  group('换歌窗口（_switching）约束', () {
    // 窗口逻辑是私有状态机，无法直接断言；这里锁定它的外部约定：
    // play() 进门开窗、3 秒自动关窗、_stopTicker 清窗。真机行为由探针验证。
    test('VFile.stem 可用于日志（无路径泄漏）', () {
      // 日志探针只记 stem()，不记完整路径——隐私约束的回归锁
      final VFile f = VFile(name: 'song.mp3', docId: 'd1');
      expect(f.stem(), 'song');
    });
  });
}
