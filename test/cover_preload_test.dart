/// 封面批量预热（0.2.89）。
///
/// 背景：用户反馈「还是翻到哪里加载到哪里」。查代码发现真因不是缓存容量，
/// 而是：①滚动过程中 `_load()` 直接 return（paused），经过的行全是空白；
/// ②停手后才开跑，磁盘小图要异步读，慢一拍。
///
/// 这里锁住预热行为：磁盘上已有的小图应被一次性灌进内存，之后 `peek` 能
/// 同步命中（列表行重建时才能一帧就出图）。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/app/cover_cache.dart';
import 'package:musicorganizer/app/cover_thumb_cache.dart';
import 'package:musicorganizer/core/cover/thumb_policy.dart';
import 'package:musicorganizer/core/model/vfile.dart';

VFile song(int i) => VFile(
    docId: 'album/song$i.mp3',
    parentId: 'album',
    name: 'song$i.mp3',
    size: 1000,
    lastModified: 1700000000000);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mo_preload_');
    CoverThumbCache.instance.resetForTest();
    CoverThumbCache.dirOverride = () async => tmp;
    CoverThumbCache.encoderOverride = (Uint8List src, int width) async => src;
    CoverCache.instance.clear();
  });

  tearDown(() async {
    CoverThumbCache.dirOverride = null;
    CoverThumbCache.encoderOverride = null;
    CoverThumbCache.instance.resetForTest();
    CoverCache.instance.clear();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  /// 往「磁盘缓存目录」里按策略写一张假缩略图。
  Future<void> putDiskThumb(VFile f, int bytes) async {
    final Directory dir = Directory('${tmp.path}${Platform.pathSeparator}cover_thumbs');
    if (!await dir.exists()) await dir.create(recursive: true);
    final File out = File(
        '${dir.path}${Platform.pathSeparator}${ThumbPolicy.fileName(ThumbPolicy.keyOf(f))}');
    await out.writeAsBytes(Uint8List.fromList(List<int>.filled(bytes, 0x33)));
  }

  test('预热后内存里能同步命中（滚动重建行时一帧出图）', () async {
    final List<VFile> files = <VFile>[for (int i = 0; i < 5; i++) song(i)];
    for (final VFile f in files) {
      await putDiskThumb(f, 200);
    }
    expect(CoverCache.instance.peek(files.first), isNull, reason: '预热前内存是空的');

    final int n = await CoverThumbCache.instance.preloadInto(files);
    expect(n, 5, reason: '5 张磁盘小图都应灌进内存');
    for (final VFile f in files) {
      expect(CoverCache.instance.peek(f), isNotNull,
          reason: '预热后必须同步命中，否则重建行仍会闪空');
    }
  });

  test('磁盘上没有的歌被跳过，不会伪造封面', () async {
    final List<VFile> files = <VFile>[song(1), song(2)];
    await putDiskThumb(files.first, 200); // 只有第一首有

    final int n = await CoverThumbCache.instance.preloadInto(files);
    expect(n, 1);
    expect(CoverCache.instance.peek(files[0]), isNotNull);
    expect(CoverCache.instance.peek(files[1]), isNull,
        reason: '没有缓存就不该凭空出现封面');
  });

  test('空列表 / 无缓存目录时不炸', () async {
    expect(await CoverThumbCache.instance.preloadInto(<VFile>[]), 0);
    expect(await CoverThumbCache.instance.preloadInto(<VFile>[song(1)]), 0);
  });

  test('过小的坏文件（<64 字节）不算有效缩略图', () async {
    final VFile f = song(9);
    await putDiskThumb(f, 10);
    final int n = await CoverThumbCache.instance.preloadInto(<VFile>[f]);
    expect(n, 0);
    expect(CoverCache.instance.peek(f), isNull);
  });
}
