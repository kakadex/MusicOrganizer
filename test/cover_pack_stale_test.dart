/// 打包缓存不许「自己把自己清空」（0.2.96）。
///
/// 真机日志暴露的致命 bug：`peekOf()` 发现 key 失配时，会
/// **删掉内存条目 + 标脏 + 把空表写回磁盘**——35MB 缓存被应用自己抹掉，
/// 于是每次重启都「加载 869 条」但实际全被清空、列表永远没图。
///
/// 这里锁住：失配只返回 null，条目保留，磁盘文件不被清空。
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
    tmp = await Directory.systemTemp.createTemp('mo_stale_');
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

  void restart() {
    CoverPackStore.instance.resetForTest();
    CoverPackStore.dirOverride = () async => tmp;
  }

  test('失配一次不删条目：再查同一条（恢复匹配后）仍能拿到', () async {
    final CoverPackStore s = CoverPackStore.instance;
    await s.ensureLoaded();
    final VFile good = song('a/1.mp3');
    s.put(good, blob(100, 0x11));

    // 用一个「改了 mtime」的版本查——失配
    expect(s.peekOf(song('a/1.mp3', mtime: 1)), isNull);
    // 条目必须还在：换回正确的 key 就该命中
    expect(s.peekOf(good), blob(100, 0x11),
        reason: '失配只是这一次不返回，不能把数据删了');
    expect(s.entryCount, 1);
  });

  test('失配后落盘：磁盘上的 869 条不会被清成 0', () async {
    final CoverPackStore s = CoverPackStore.instance;
    await s.ensureLoaded();
    final List<VFile> files = <VFile>[for (int i = 0; i < 20; i++) song('a/s$i.mp3')];
    for (final VFile f in files) {
      s.put(f, blob(200, 0x22));
    }
    await s.flush();
    final int sizeBefore = await s.packFileSize();
    expect(sizeBefore, greaterThan(0));

    // 模拟「整库 mtime 都变了」：批量查询全部失配
    for (final VFile f in files) {
      s.peekOf(song(f.docId, mtime: 999));
    }
    await s.flush();

    final int sizeAfter = await s.packFileSize();
    expect(sizeAfter, sizeBefore,
        reason: '失配不该导致把缓存文件重写成空表（旧 bug 正是这样抹掉 35MB）');

    // 重启后仍是 20 条
    restart();
    expect(await CoverPackStore.instance.ensureLoaded(), 20);
  });

  test('诊断汇总能反映失配次数（排查用）', () async {
    final CoverPackStore s = CoverPackStore.instance;
    await s.ensureLoaded();
    final VFile f = song('a/9.mp3');
    s.put(f, blob(100, 0x33));
    // 计数器是单例累计（不随 resetForTest 归零），所以断言「有增长」而非绝对数
    final String before = s.diagSummary();
    s.peekOf(song('a/9.mp3', mtime: 5)); // 失配一次
    final String after = s.diagSummary();
    expect(after, isNot(before), reason: '失配后诊断汇总应变化');
    expect(after, contains('失配'));
    expect(after, contains('包内 1 条'));
  });
}
