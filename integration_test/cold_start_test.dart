import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:musicorganizer/app/repo.dart';
import 'package:musicorganizer/core/fs/desktop_file_store.dart';
import 'package:musicorganizer/core/model/vfile.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 冷启动秒开验证：首次全量扫描并落盘 → 模拟进程被杀（内存全清）→ 二次启动
/// 只从缓存恢复，断言恢复出的条目数、标签都在，且耗时明显小于首次。
///
/// 需要一个真实曲库，路径用 `--dart-define=MO_TEST_LIBRARY=<目录>` 给；
/// 没给就跳过——没有曲库时不该假通过。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const String library = String.fromEnvironment('MO_TEST_LIBRARY');

  testWidgets('二次启动用缓存撑起列表，不必重扫', (WidgetTester tester) async {
    if (library.isEmpty || !Directory(library).existsSync()) {
      return;
    }
    SharedPreferences.setMockInitialValues(<String, Object>{});

    final DesktopFileStore store = DesktopFileStore()
      ..directoryPicker = () async => library;
    await Repo.instance.init(storeOverride: store);
    expect(await Repo.instance.addRoot(), isTrue);

    // 第一次：递归目录 + 逐首读标签
    final Stopwatch first = Stopwatch()..start();
    final ScanOutcome out = await Repo.instance.rescan();
    await Repo.instance.loadMeta();
    first.stop();
    expect(out.ok, isTrue);
    final int total = Repo.instance.files
        .where((VFile f) => !f.dir && f.audio())
        .length;
    expect(total, greaterThan(0));
    final int uniqueIds = Repo.instance.files
        .where((VFile f) => !f.dir && f.audio())
        .map((VFile f) => f.docId)
        .toSet()
        .length;
    // 诊断：列表里的条目数与去重后的 docId 数若不一致，缓存恢复就会少条目
    // ignore: avoid_print
    print('[cold-start] total=$total uniqueIds=$uniqueIds');
    expect(uniqueIds, total, reason: '文件列表里出现了重复 docId');

    // 等最后一次落盘完成（产品里是后台保存，测试要确定性就显式等一下）
    await Repo.instance.saveLibraryCache();

    // 模拟进程被杀：内存里的文件列表与读过的标签全部丢失
    Repo.instance.files = <VFile>[];
    Repo.instance.index.clear();

    // 第二次：只从缓存恢复
    final Stopwatch again = Stopwatch()..start();
    final int restored = await Repo.instance.restoreLibraryCache();
    again.stop();

    expect(restored, total);
    final int withTags =
        Repo.instance.files.where((VFile f) => f.metaCached()).length;
    expect(withTags, total);
    expect(
      again.elapsedMilliseconds * 5,
      lessThan(first.elapsedMilliseconds),
      reason: '首次 ${first.elapsedMilliseconds}ms，缓存恢复 ${again.elapsedMilliseconds}ms',
    );
  });
}
