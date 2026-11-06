/// 打包版封面存储的行为（0.2.93）。
///
/// 锁住新方案的四条命脉：
/// 1. **一次加载**：整个文件读一次进内存，之后取值零 IO；
/// 2. **新鲜度**：文件变了旧图作废；
/// 3. **落盘原子**：临时文件 + 改名，中途失败不留坏文件；
/// 4. **坏文件自愈**：格式不认识就删掉重建，不让用户卡死。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/app/cover_pack_store.dart';
import 'package:musicorganizer/core/model/vfile.dart';

VFile song(String id, {int size = 1000, int mtime = 1700000000000}) =>
    VFile(docId: id, name: '$id.mp3', size: size, lastModified: mtime);

Uint8List blob(int n, int fill) =>
    Uint8List.fromList(List<int>.filled(n, fill));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mo_pack_');
    CoverPackStore.instance.resetForTest();
    CoverPackStore.dirOverride = () async => tmp;
  });

  tearDown(() async {
    CoverPackStore.instance.resetForTest();
    CoverPackStore.dirOverride = null;
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('放入后能立刻取值（纯内存，不读盘）', () async {
    final CoverPackStore s = CoverPackStore.instance;
    await s.ensureLoaded();
    final VFile f = song('a/1.mp3');
    s.put(f, blob(100, 0x11));

    expect(s.peekOf(f), blob(100, 0x11));
    expect(s.entryCount, 1);
  });

  test('落盘后重新加载：内容还在（关键——跨进程复用）', () async {
    final VFile f1 = song('a/1.mp3');
    final VFile f2 = song('a/2.mp3', size: 2000);

    CoverPackStore.instance
      ..put(f1, blob(100, 0x22))
      ..put(f2, blob(150, 0x33));
    await CoverPackStore.instance.flush();

    // 模拟进程重启
    CoverPackStore.instance.resetForTest();
    CoverPackStore.dirOverride = () async => tmp;

    final int n = await CoverPackStore.instance.ensureLoaded();
    expect(n, 2);
    expect(CoverPackStore.instance.peekOf(f1), blob(100, 0x22));
    expect(CoverPackStore.instance.peekOf(f2), blob(150, 0x33));
  });

  test('文件变了（大小或时间）：旧图不返回，但条目保留不自毁', () async {
    final CoverPackStore s = CoverPackStore.instance;
    await s.ensureLoaded();
    final VFile f = song('a/3.mp3');
    s.put(f, blob(80, 0x44));

    expect(s.peekOf(song('a/3.mp3', size: 999)), isNull, reason: '大小变了不该返回旧图');
    // 0.2.96：条目保留——旧版这里会删掉并标脏，最终把整个缓存文件清空
    expect(s.has('a/3.mp3'), isTrue,
        reason: '失配只影响这一次返回，不能删除数据（否则会自毁整包缓存）');
    expect(s.peekOf(f), blob(80, 0x44), reason: '换回正确的 key 仍应命中');
  });

  test('坏文件不会卡死：删掉重建，load 返回 0', () async {
    final Directory d = Directory('${tmp.path}${Platform.pathSeparator}cover_pack');
    await d.create(recursive: true);
    await File('${d.path}${Platform.pathSeparator}cover_pack.bin')
        .writeAsBytes(blob(500, 0x00)); // 不是我们的格式

    final int n = await CoverPackStore.instance.ensureLoaded();
    expect(n, 0, reason: '坏文件当没有缓存处理');

    // 之后还能正常写入
    final VFile f = song('a/4.mp3');
    CoverPackStore.instance.put(f, blob(90, 0x55));
    expect(CoverPackStore.instance.peekOf(f), isNotNull);
  });

  test('太小的字节被拒（坏图不污染索引）', () async {
    final CoverPackStore s = CoverPackStore.instance;
    await s.ensureLoaded();
    final VFile f = song('a/5.mp3');
    s.put(f, blob(10, 0x66));
    expect(s.has('a/5.mp3'), isFalse);
  });

  test('remove 之后取不到，且下次落盘不会回来', () async {
    final VFile f = song('a/6.mp3');
    final CoverPackStore s = CoverPackStore.instance;
    await s.ensureLoaded();
    s.put(f, blob(100, 0x77));
    s.remove(f);
    expect(s.peekOf(f), isNull);
    await s.flush();

    s.resetForTest();
    CoverPackStore.dirOverride = () async => tmp;
    expect(await s.ensureLoaded(), 0);
  });

  test('900 首：内存里全有，打包文件大小合理', () async {
    final CoverPackStore s = CoverPackStore.instance;
    await s.ensureLoaded();
    for (int i = 0; i < 900; i++) {
      final VFile f = song('primary:Music/Artist$i/song$i.mp3', size: 4000000 + i);
      s.put(f, blob(30 * 1024, i & 0xFF));
    }
    expect(s.entryCount, 900);

    await s.flush();
    final int size = await s.packFileSize();
    expect(size, greaterThan(0));
    final double mb = size / 1024 / 1024;
    expect(mb, lessThan(40), reason: '900×30KB 应在 27MB 左右，实测 $mb MB');

    // 模拟重启后一次加载
    s.resetForTest();
    CoverPackStore.dirOverride = () async => tmp;
    final DateTime t0 = DateTime.now();
    final int n = await s.ensureLoaded();
    final int ms = DateTime.now().difference(t0).inMilliseconds;
    expect(n, 900);
    expect(ms, lessThan(3000), reason: '一次加载 900 张应远快于 920 次小文件读取，实测 $ms ms');
  });
}
