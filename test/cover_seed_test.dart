/// 扫描读标签时顺手生成封面缩略图（0.2.92）。
///
/// 这是这次封面问题的**真正根治点**：`loadMeta` 读标签时封面字节本来就已经
/// 在手上（`TagParseResult.cover`），旧代码只拿它算一个「有没有封面」的布尔
/// 就把字节丢掉，之后列表要封面又得重读一遍文件头 + 重新解码。920 首就是
/// 920 次重复读盘——这才是「滚动要加载」的根源。
///
/// 这里锁住 [CoverCache.seed]：原图进去、内存里拿到的是**缩过的**小图，
/// 且第二次能同步命中。
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/app/cover_cache.dart';
import 'package:musicorganizer/app/cover_thumb_cache.dart';
import 'package:musicorganizer/core/model/vfile.dart';

VFile song(int i) => VFile(
    docId: 'album/song$i.mp3',
    parentId: 'album',
    name: 'song$i.mp3',
    size: 1000,
    lastModified: 1700000000000);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    CoverThumbCache.instance.resetForTest();
    CoverThumbCache.dirOverride = () async => null; // 不落盘，只测内存那半
    CoverThumbCache.encoderOverride = (Uint8List src, int width) async =>
        Uint8List.fromList(List<int>.filled(64, 0xAA)); // 固定缩成 64 字节
    CoverCache.instance.clear();
  });

  tearDown(() {
    CoverThumbCache.dirOverride = null;
    CoverThumbCache.encoderOverride = null;
    CoverThumbCache.instance.resetForTest();
    CoverCache.instance.clear();
  });

  test('seed 原图后内存里是缩过的小图（不是 2MB 原图）', () async {
    final VFile f = song(1);
    final Uint8List original =
        Uint8List.fromList(List<int>.filled(2 * 1024 * 1024, 0x01));

    await CoverCache.instance.seed(f, original);

    final Uint8List? hit = CoverCache.instance.peek(f);
    expect(hit, isNotNull, reason: '扫描完就该能同步命中，列表不用再读盘');
    expect(hit!.length, 64, reason: '内存里必须是缩图，不能是 2MB 原图');
    expect(CoverCache.instance.bytesUsed, 64);
  });

  test('seed 之后列表侧 peek 一帧出图（模拟行重建）', () async {
    final VFile f = song(2);
    expect(CoverCache.instance.peek(f), isNull, reason: '扫描前没有');

    await CoverCache.instance.seed(
        f, Uint8List.fromList(List<int>.filled(500 * 1024, 0x02)));

    // 行重建时走的就是这句同步取值
    expect(CoverCache.instance.peek(f), isNotNull);
  });

  test('空封面不污染缓存', () async {
    final VFile f = song(3);
    await CoverCache.instance.seed(f, Uint8List(0));
    expect(CoverCache.instance.peek(f), isNull);
    expect(CoverCache.instance.entryCount, 0);
  });

  test('缩图失败时退回原图，仍然能显示（不让用户看到空白）', () async {
    CoverThumbCache.encoderOverride = (Uint8List src, int width) async => null;
    final VFile f = song(4);
    await CoverCache.instance.seed(
        f, Uint8List.fromList(List<int>.filled(500, 0x03)));
    expect(CoverCache.instance.peek(f), isNotNull);
    expect(CoverCache.instance.peek(f)!.length, 500);
  });
}
