/// 封面内存缓存的容量策略（0.2.61）。
///
/// 背景：`CoverCache` 原来只有 400 条上限，存的却是原始图（单张最大 12MB），
/// 400 条能吃掉上百 MB，滚动时频繁 GC。现在改成「条数 + 字节」双上限。
///
/// 这里只测容量账本与淘汰顺序（新增的状态），不假装验证真实解码——
/// 那部分由 widget_covers_resume_test 与真机负责。
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/app/cover_cache.dart';
import 'package:musicorganizer/app/cover_thumb_cache.dart';

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

  Uint8List blob(int n) =>
      Uint8List.fromList(List<int>.generate(n, (int i) => i & 0xFF));

  test('塞进去之后条数与字节数都对得上', () {
    final CoverCache c = CoverCache.instance;
    c.debugPut('a', blob(100));
    c.debugPut('b', blob(250));
    expect(c.entryCount, 2);
    expect(c.bytesUsed, 350);
  });

  test('同一个键重复写：字节数按新值算，不会累加', () {
    final CoverCache c = CoverCache.instance;
    c.debugPut('a', blob(1000));
    expect(c.bytesUsed, 1000);
    c.debugPut('a', blob(300));
    expect(c.entryCount, 1);
    expect(c.bytesUsed, 300, reason: '替换而不是累加');
    expect(c.debugGet('a')!.length, 300);
  });

  test('超过条数上限会淘汰，且淘汰后账本仍然一致', () {
    final CoverCache c = CoverCache.instance;
    // 0.2.88：条数上限从 400 提到 4000（900 首的库装得下，不再因条数被砍）。
    // 这里塞超出上限的量，确认淘汰机制本身还在、账本不漂。
    for (int i = 0; i < 4500; i++) {
      c.debugPut('k$i', blob(16));
    }
    expect(c.entryCount, lessThanOrEqualTo(4000),
        reason: '必须被压到条数上限以内');
    expect(c.bytesUsed, c.entryCount * 16,
        reason: '字节账本必须与条数 × 单条大小严格一致');
  });

  test('超过字节上限会淘汰（这是本次新增的那一维）', () {
    final CoverCache c = CoverCache.instance;
    // 上限 24MB：塞 8 条 4MB 的「大图」共 32MB
    const int big = 4 * 1024 * 1024;
    for (int i = 0; i < 8; i++) {
      c.debugPut('big$i', blob(big));
    }
    expect(c.bytesUsed, lessThanOrEqualTo(24 * 1024 * 1024),
        reason: '字节数必须被压到 24MB 以内——旧版这一维完全没有');
    // 留下的必须是最新的那批（FIFO 淘汰最早插入的）
    expect(c.debugGet('big7'), isNotNull, reason: '最新插入的必须还在');
    expect(c.debugGet('big0'), isNull, reason: '最早插入的应先被淘汰');
  });

  test('淘汰后继续写入，账本不漂移、也不会变负数', () {
    final CoverCache c = CoverCache.instance;
    const int big = 4 * 1024 * 1024;
    for (int round = 0; round < 20; round++) {
      c.debugPut('r$round', blob(big));
      expect(c.bytesUsed, greaterThanOrEqualTo(0));
      expect(c.bytesUsed, lessThanOrEqualTo(24 * 1024 * 1024));
    }
  });

  test('clear 之后占用归零', () {
    final CoverCache c = CoverCache.instance;
    c.debugPut('a', blob(500));
    c.debugPut('b', blob(700));
    expect(c.bytesUsed, 1200);
    c.clear();
    expect(c.entryCount, 0);
    expect(c.bytesUsed, 0);
  });

  test('重复 clear 不会把字节计数变成负数', () {
    final CoverCache c = CoverCache.instance;
    for (int i = 0; i < 5; i++) {
      c.clear();
      expect(c.bytesUsed, 0);
    }
  });
}
