/// 整库补齐封面缩略图（0.2.91）。
///
/// 这是「滚动全程不加载」的根治手段：扫描完成后后台把缺的小图一次生成好，
/// 之后滚动只碰小图/内存，不再现场读 256KB 文件头。
///
/// 这里锁住三件事：**已存在的跳过（增量）**、**只补缺的**、**可以中途停**。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
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
    tmp = await Directory.systemTemp.createTemp('mo_fill_');
    CoverThumbCache.instance.resetForTest();
    CoverThumbCache.dirOverride = () async => tmp;
    CoverThumbCache.encoderOverride = (Uint8List src, int width) async =>
        Uint8List.fromList(List<int>.filled(120, 0x77));
  });

  tearDown(() async {
    CoverThumbCache.dirOverride = null;
    CoverThumbCache.encoderOverride = null;
    CoverThumbCache.instance.resetForTest();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<bool> hasThumb(VFile f) async {
    final File file = File('${tmp.path}${Platform.pathSeparator}cover_thumbs'
        '${Platform.pathSeparator}${ThumbPolicy.fileName(ThumbPolicy.keyOf(f))}');
    return file.exists();
  }

  test('补齐缺失的小图；已在磁盘上的不重复生成', () async {
    final List<VFile> files = <VFile>[song(1), song(2), song(3)];
    // 先给第 1 首放一张已有的小图
    await CoverThumbCache.instance.save(
        files[0], Uint8List.fromList(List<int>.filled(120, 0x11)));
    expect(await hasThumb(files[0]), isTrue);

    final List<VFile> asked = <VFile>[];
    final int made = await CoverThumbCache.instance.fillMissing(
      files,
      readCover: (VFile f) async {
        asked.add(f);
        return Uint8List.fromList(List<int>.filled(120, 0x22));
      },
    );

    expect(made, 2, reason: '只应新生成第 2、3 首');
    expect(asked.length, 2, reason: '已有小图的第 1 首不该再读一次');
    expect(await hasThumb(files[1]), isTrue);
    expect(await hasThumb(files[2]), isTrue);
  });

  test('读不到封面的歌不留垃圾文件', () async {
    final List<VFile> files = <VFile>[song(5)];
    final int made = await CoverThumbCache.instance.fillMissing(
      files,
      readCover: (VFile f) async => null,
    );
    expect(made, 0);
    expect(await hasThumb(files[0]), isFalse,
        reason: '没封面就不该落盘，否则下次会被当成有效缓存');
  });

  test('shouldStop 为真时立刻停手（不和滑动抢磁盘）', () async {
    final List<VFile> files = <VFile>[for (int i = 0; i < 10; i++) song(i)];
    int calls = 0;
    final int made = await CoverThumbCache.instance.fillMissing(
      files,
      readCover: (VFile f) async {
        calls++;
        return Uint8List.fromList(List<int>.filled(120, 0x33));
      },
      shouldStop: () => calls >= 2,
    );
    expect(made, 2, reason: '第 2 首之后应停');
    expect(calls, 2);
  });

  test('progress 回调报出进度', () async {
    final List<VFile> files = <VFile>[song(7), song(8)];
    final List<String> seen = <String>[];
    await CoverThumbCache.instance.fillMissing(
      files,
      readCover: (VFile f) async => Uint8List.fromList(List<int>.filled(120, 0x44)),
      onProgress: (int done, int total, int made) => seen.add('$done/$total/$made'),
    );
    expect(seen, <String>['1/2/1', '2/2/2']);
  });
}
