/// 列表现读出来的封面必须进打包存储（0.2.95）。
///
/// 这是 0.2.93/0.2.94 漏掉的缺口：只有「后台补图」那条路会写 pack，
/// 而 `CoverCache.load()` 现场读出来的原图只进了内存缓存——重启就没了，
/// 于是每次启动都得重新慢滑一遍。这里锁住「读了就要存」。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/app/cover_pack_store.dart';
import 'package:musicorganizer/app/cover_thumb_cache.dart';
import 'package:musicorganizer/core/model/vfile.dart';

VFile song(String id) => VFile(
    docId: id, name: '$id.mp3', size: 1000, lastModified: 1700000000000);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mo_seedpack_');
    CoverPackStore.instance.resetForTest();
    CoverPackStore.dirOverride = () async => tmp;
    CoverThumbCache.instance.resetForTest();
    CoverThumbCache.dirOverride = () async => tmp;
    // 固定缩成 64 字节，方便断言
    CoverThumbCache.encoderOverride = (Uint8List src, int width) async =>
        Uint8List.fromList(List<int>.filled(64, 0xAA));
  });

  tearDown(() async {
    CoverPackStore.instance.resetForTest();
    CoverPackStore.dirOverride = null;
    CoverThumbCache.instance.resetForTest();
    CoverThumbCache.dirOverride = null;
    CoverThumbCache.encoderOverride = null;
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  /// 模拟 `CoverCache.load()` 读到原图后的收尾动作：
  /// encodeSmall → 存进 pack → 落盘。
  Future<void> simulateListLoad(VFile f, Uint8List original) async {
    final Uint8List? small = await CoverThumbCache.instance.encodeSmall(original);
    if (small != null) {
      CoverPackStore.instance.put(f, small);
    }
    await CoverPackStore.instance.flush();
  }

  test('列表现读后重启：打包里还在（这就是之前缺的那一步）', () async {
    final VFile f = song('a/1.mp3');
    await CoverPackStore.instance.ensureLoaded();
    await simulateListLoad(f, Uint8List.fromList(List<int>.filled(500, 0x11)));

    // 模拟杀进程
    CoverPackStore.instance.resetForTest();
    CoverPackStore.dirOverride = () async => tmp;

    final int n = await CoverPackStore.instance.ensureLoaded();
    expect(n, 1, reason: '列表现读的封面必须活过重启');
    expect(CoverPackStore.instance.peekOf(f), isNotNull);
  });

  test('10 首逐个现读 → 重启后 10 首都在', () async {
    await CoverPackStore.instance.ensureLoaded();
    for (int i = 0; i < 10; i++) {
      await simulateListLoad(
          song('a/s$i.mp3'), Uint8List.fromList(List<int>.filled(300, i)));
    }

    CoverPackStore.instance.resetForTest();
    CoverPackStore.dirOverride = () async => tmp;

    expect(await CoverPackStore.instance.ensureLoaded(), 10);
    for (int i = 0; i < 10; i++) {
      expect(CoverPackStore.instance.peekOf(song('a/s$i.mp3')), isNotNull);
    }
  });

  test('缩图失败时不写坏数据', () async {
    CoverThumbCache.encoderOverride = (Uint8List src, int width) async => null;
    final VFile f = song('a/bad.mp3');
    await CoverPackStore.instance.ensureLoaded();
    await simulateListLoad(f, Uint8List.fromList(List<int>.filled(500, 0x22)));
    expect(CoverPackStore.instance.has(f.docId), isFalse);
  });
}
