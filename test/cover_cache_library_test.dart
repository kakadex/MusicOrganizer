/// 封面内存缓存能否装下整个曲库（0.2.88）。
///
/// 背景：用户反馈「滚动不卡，但每次下翻到新部分都要重新加载封面」。
/// 查代码发现：`CoverCache` 的**条数**上限是 400，而真实曲库有 900+ 首；
/// 每一行的封面字节只有 20–40KB，24MB 字节预算根本用不完，卡住的是条数。
/// 滚过 400 首之后前面的一律被淘汰，回滚/再下翻就要重来一遍。
///
/// 另外旁挂图（同名 .jpg / 目录 cover.jpg）的结果原来**不进** `CoverCache`，
/// 走的是带 5 分钟 TTL 的独立缓存，等于每行重建都要重查。这里一并锁住。
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/app/cover_cache.dart';
import 'package:musicorganizer/app/cover_thumb_cache.dart';
import 'package:musicorganizer/core/model/vfile.dart';

Uint8List thumb(int n) => Uint8List.fromList(List<int>.filled(n, 0x11));

VFile song(int i) =>
    VFile(docId: 'album/song$i.mp3', parentId: 'album', name: 'song$i.mp3', size: 1000);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    CoverThumbCache.instance.resetForTest();
    CoverThumbCache.dirOverride = () async => null;
    CoverThumbCache.encoderOverride = (Uint8List src, int width) async => src;
    CoverCache.instance.clear();
  });

  tearDown(() {
    CoverThumbCache.dirOverride = null;
    CoverThumbCache.encoderOverride = null;
    CoverThumbCache.instance.resetForTest();
    CoverCache.instance.clear();
  });

  test('900 首曲库的缩略图应全部留在内存里（旧版 400 条上限会淘汰掉一半）', () {
    final CoverCache c = CoverCache.instance;
    // 每张缩略图 30KB，900 张约 27MB… 这里用 24KB/张（21.6MB）模拟真实情况
    for (int i = 0; i < 900; i++) {
      c.debugPut(CoverCache.keyOf(song(i)), thumb(24 * 1024));
    }
    expect(c.entryCount, 900,
        reason: '整库 900 首都应留在内存里：字节预算够（约 21.6MB < 24MB），'
            '不该因为条数上限被淘汰');
    expect(c.peek(song(0)), isNotNull, reason: '最早的那首不能被淘汰');
    expect(c.peek(song(899)), isNotNull, reason: '最新的那首当然要在');
  });

  test('字节预算仍然是真上限：塞满大图后仍会按字节淘汰', () {
    final CoverCache c = CoverCache.instance;
    const int big = 4 * 1024 * 1024;
    for (int i = 0; i < 10; i++) {
      c.debugPut('big$i', thumb(big));
    }
    expect(c.bytesUsed, lessThanOrEqualTo(24 * 1024 * 1024),
        reason: '字节上限不能被放宽，否则又会 OOM');
    expect(c.debugGet('big0'), isNull, reason: '最早插入的大图应被淘汰');
  });

  test('旁挂封面（同名图/目录图）的结果也要进统一内存缓存', () {
    final CoverCache c = CoverCache.instance;
    final VFile f = song(7);
    expect(c.peek(f), isNull);
    c.put(f, thumb(20 * 1024));
    expect(c.peek(f), isNotNull,
        reason: '写入后必须能同步读到——这是「重建行不闪占位」的前提');
  });

  test('put 覆盖同一个键时字节账本按新值算', () {
    final CoverCache c = CoverCache.instance;
    final VFile f = song(1);
    c.put(f, thumb(1000));
    c.put(f, thumb(400));
    expect(c.entryCount, 1);
    expect(c.bytesUsed, 400);
  });
}
