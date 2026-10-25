import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:musicorganizer/core/fs/saf_file_store.dart';
import 'package:musicorganizer/core/fs/tree_ref.dart';
import 'package:musicorganizer/core/model/vfile.dart';
import 'package:path_provider/path_provider.dart';

/// SAF 真机冒烟（运行留待 AVD/真机，见主理人安排）：
/// 用已授权目录树：列目录 → 创建小文件 → 写 → 读回 → 删除。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('SAF 冒烟：列目录 → 读写小文件 → 删除', (WidgetTester tester) async {
    final SafFileStore store = SafFileStore();
    final List<TreeRef> roots = await store.roots();
    if (roots.isEmpty) {
      // 自动化环境无已授权树：跳过（真机需先 pickTree 授权）
      return;
    }

    final TreeRef tree = roots.first;
    final VFile? root = await store.stat(tree.rootDocId);
    expect(root, isNotNull);
    expect(root!.dir, isTrue);

    final List<VFile> children = await store.children(root);
    expect(children, isA<List<VFile>>());

    final String name = 'mo_smoke_${DateTime.now().millisecondsSinceEpoch}.txt';
    final VFile created = await store.createFile(root, name, 'text/plain');
    expect(created.name, isNotEmpty);

    final Directory tmp = await getTemporaryDirectory();
    final Uint8List payload = Uint8List.fromList(<int>[1, 2, 3, 4, 5]);

    final File local = File('${tmp.path}/$name');
    await local.writeAsBytes(payload);
    await store.writeFromLocal(created, local);

    final File back = File('${tmp.path}/back_$name');
    await store.copyToLocal(created, back);
    expect(await back.readAsBytes(), payload);

    expect(await store.delete(created), isTrue);
    expect(await store.stat(created.docId), isNull);
  });
}
