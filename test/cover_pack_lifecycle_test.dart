/// 封面打包存储的**完整生命周期**验证（0.2.94）。
///
/// 0.2.93 发出去后真机仍然「重启就要慢滑一遍才正常」，说明我只测了「编解码
/// 正确」，没测「数据真的活过进程重启」。这里把三个疑点逐个钉死：
///
///   ① 写入 → 杀进程（重置单例）→ 重新加载，数据还在吗？
///   ② 首次拿不到目录（启动早期时序）→ 会不会把整个缓存**永久禁用**？
///   ③ flush 期间又有新写入 → 会不会丢？
///
/// 这些测试写出来先看它们**红**，再改代码让它们变绿。
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
    tmp = await Directory.systemTemp.createTemp('mo_life_');
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

  /// 模拟杀进程重启：清空内存态，但保留磁盘。
  void restart() {
    CoverPackStore.instance.resetForTest();
    CoverPackStore.dirOverride = () async => tmp;
  }

  test('① 写入 → 落盘 → 重启 → 数据还在', () async {
    final VFile f1 = song('a/1.mp3');
    final VFile f2 = song('a/2.mp3');
    await CoverPackStore.instance.ensureLoaded();
    CoverPackStore.instance
      ..put(f1, blob(100, 0x11))
      ..put(f2, blob(200, 0x22));
    await CoverPackStore.instance.flush();

    restart();

    final int n = await CoverPackStore.instance.ensureLoaded();
    expect(n, 2, reason: '重启后必须能读回来');
    expect(CoverPackStore.instance.peekOf(song('a/1.mp3')), blob(100, 0x11));
    expect(CoverPackStore.instance.peekOf(song('a/2.mp3')), blob(200, 0x22));
  });

  test('② 首次拿不到目录（启动早期）→ 不该永久禁用缓存', () async {
    // 模拟 path_provider 还没就绪：第一次返回 null
    int calls = 0;
    CoverPackStore.instance.resetForTest();
    CoverPackStore.dirOverride = () async {
      calls++;
      if (calls == 1) return null; // 第一次失败
      return tmp; // 之后就绪
    };

    expect(await CoverPackStore.instance.ensureLoaded(), 0,
        reason: '第一次拿不到目录，返回 0 是合理的');

    // 关键：目录就绪后必须能恢复，不能一直返回 0
    final VFile f = song('a/3.mp3');
    CoverPackStore.instance.put(f, blob(90, 0x33));
    await CoverPackStore.instance.flush();
    expect(CoverPackStore.instance.peekOf(f), isNotNull, reason: '内存写入应生效');

    restart();
    CoverPackStore.dirOverride = () async => tmp;
    final int n = await CoverPackStore.instance.ensureLoaded();
    expect(n, 1, reason: '目录就绪后必须能正常读写，不能因为首次失败就永远禁用');
  });

  test('③ flush 期间又写入：不能丢', () async {
    final CoverPackStore s = CoverPackStore.instance;
    await s.ensureLoaded();
    final VFile a = song('a/a.mp3');
    s.put(a, blob(100, 0x44));

    // 同时触发两次 flush（模拟补图过程中落盘 + 防抖到期）
    final Future<void> f1 = s.flush();
    final VFile b = song('a/b.mp3');
    s.put(b, blob(120, 0x55)); // flush 进行中被写入
    final Future<void> f2 = s.flush();
    await Future.wait(<Future<void>>[f1, f2]);
    // 再补一次，确保最后一批也落盘
    await s.flush();

    restart();
    final int n = await s.ensureLoaded();
    expect(n, 2, reason: 'flush 期间写入的那条不能丢');
    expect(s.peekOf(song('a/b.mp3')), blob(120, 0x55));
  });

  test('④ 防抖未到期就杀进程：内存数据会丢（已知，靠定期 flush 缓解）', () async {
    // 这条记录设计边界：put 之后如果**从不** flush，进程被杀就丢。
    // 生产代码的缓解是：补图每 50 首 flush 一次 + 补完 flush 一次。
    final CoverPackStore s = CoverPackStore.instance;
    await s.ensureLoaded();
    final VFile f = song('a/c.mp3');
    s.put(f, blob(150, 0x66));
    restart();

    final int n = await s.ensureLoaded();
    expect(n, 0, reason: '没 flush 就杀进程确实会丢——这是已知边界，不是 bug');
  });

  test('⑤ 900 首完整生命周期：写入→落盘→重启→全部命中', () async {
    final CoverPackStore s = CoverPackStore.instance;
    await s.ensureLoaded();
    for (int i = 0; i < 900; i++) {
      s.put(song('primary:Music/A$i/s$i.mp3', size: 4000000 + i),
          blob(20 * 1024, i & 0xFF));
    }
    await s.flush();

    restart();
    final DateTime t0 = DateTime.now();
    final int n = await s.ensureLoaded();
    final int ms = DateTime.now().difference(t0).inMilliseconds;
    expect(n, 900, reason: '900 首重启后必须全部读回');
    expect(ms, lessThan(5000), reason: '一次加载应很快，实测 $ms ms');

    // 逐条核对都能取到
    int hit = 0;
    for (int i = 0; i < 900; i++) {
      if (s.peekOf(song('primary:Music/A$i/s$i.mp3', size: 4000000 + i)) != null) {
        hit++;
      }
    }
    expect(hit, 900);
  });
}
