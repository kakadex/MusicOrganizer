import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/media/media_import.dart';

/// 系统媒体库条目「是否已在曲库目录里」的判定。
/// 这个判断错了，用户就会看到「系统媒体库 = 我授权过的那个文件夹」，
/// 点一下又把同一批歌复制一遍。
void main() {
  MediaTrack track(String rel) => MediaTrack(
        id: 1,
        uri: 'content://media/external/audio/media/1',
        name: 'a.mp3',
        artist: '',
        album: '',
        title: '',
        durationMs: 200000,
        size: 1024,
        mime: 'audio/mpeg',
        relativePath: rel,
      );

  test('曲库目录内的条目被识别出来', () {
    expect(track('Documents/MoTest/未识别/').insideRoot('primary:Documents/MoTest'),
        isTrue);
    expect(track('Music/').insideRoot('primary:Music'), isTrue);
  });

  test('目录外的不算', () {
    expect(track('Music/').insideRoot('primary:Documents/MoTest'), isFalse);
    // 只是前缀相同、但不是同一层目录
    expect(track('Documents/MoTest2/').insideRoot('primary:Documents/MoTest'),
        isFalse);
  });

  test('没有相对路径时不误判', () {
    expect(track('').insideRoot('primary:Music'), isFalse);
  });
}
