import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart' hide Tags;
import 'package:musicorganizer/app/repo.dart';
import 'package:musicorganizer/app/theme/mo_theme.dart';
import 'package:musicorganizer/app/theme/palette.dart';
import 'package:musicorganizer/core/model/tags.dart';
import 'package:musicorganizer/core/fs/tree_ref.dart';
import 'package:musicorganizer/core/model/vfile.dart';
import 'package:musicorganizer/core/scan/search_index.dart';
import 'package:musicorganizer/feature/library/library_page.dart';

/// 曲库页的界面级回归：不依赖任何插件（SAF / SharedPreferences / path_provider），
/// 直接把 Repo 的曲库与索引塞好再挂页面，验证渲染 / 筛选 / 排序 / 多选。
void main() {
  VFile audio(String id, String name, {int size = 1024}) =>
      VFile(docId: id, parentId: 'r', name: name, size: size, lastModified: 1);

  void seed(Repo repo) {
    final VFile a = audio('r/a.mp3', 'a.mp3');
    a.cacheMeta(Tags()
      ..put('title', '示例歌名')
      ..put('artist', '示例歌手')
      ..put('album', '示例专辑'), cover: true);
    final VFile b = audio('r/b.mp3', 'b.mp3', size: 2048);
    b.cacheMeta(Tags()..put('title', '另一首'));
    final VFile c = audio('r/c.flac', 'c.flac', size: 4096);

    // 单例复用：上一条用例改过的筛选/排序会留在设置里，这里复位
    repo.settings.set('filter', 0);
    repo.settings.set('sort_key', 0);
    repo.settings.set('sort_desc', false);
    // 页面只在「已选目录」后才显示搜索与筛选，这里直接给一个根
    repo.root = const TreeRef(treeUri: 'file:///r', rootDocId: 'r');
    repo.files = <VFile>[a, b, c];
    repo.index.clear();
    for (final VFile f in repo.files) {
      final Entry e = Entry(
        docId: f.docId,
        name: f.name,
        relPath: f.name,
        size: f.size,
        modified: f.lastModified,
        file: f,
      );
      if (f.metaCached()) e.applyTags(f.cachedTags, f.cachedHasCover);
      repo.index.add(e);
    }
  }

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: MoTheme.build(MoPalette.of(MoThemeId.minimal, dark: false), dark: false),
      home: const Scaffold(body: LibraryPage()),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('默认列出全部曲目，标签已读的显示标题与歌手', (WidgetTester tester) async {
    final Repo repo = Repo.instance;
    repo.resetForTest();
    seed(repo);
    await pumpPage(tester);

    expect(find.text('音乐库'), findsOneWidget);
    // 标题优先标签，未读标签的显示文件名
    expect(find.text('示例歌名'), findsOneWidget);
    expect(find.text('示例歌手 · 示例专辑'), findsOneWidget);
    expect(find.text('另一首'), findsOneWidget);
    // 没读过标签时标题退化为文件名（去扩展名）
    expect(find.text('c'), findsOneWidget);
  });

  testWidgets('筛选「无标签」只剩缺项的那首', (WidgetTester tester) async {
    final Repo repo = Repo.instance;
    repo.resetForTest();
    seed(repo);
    await pumpPage(tester);

    await tester.tap(find.text('无标签'));
    await tester.pumpAndSettle();

    expect(find.text('示例歌名'), findsNothing);
    expect(find.text('另一首'), findsOneWidget);
    // 没读过标签时标题退化为文件名（去扩展名）
    expect(find.text('c'), findsOneWidget);
  });

  testWidgets('排序切换为大小后顺序变化', (WidgetTester tester) async {
    final Repo repo = Repo.instance;
    repo.resetForTest();
    seed(repo);
    await pumpPage(tester);

    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();
    await tester.tap(find.text('大小'));
    await tester.pumpAndSettle();

    // 升序：a(1024) < b(2048) < c(4096)
    final double ya = tester.getTopLeft(find.text('示例歌名')).dy;
    final double yb = tester.getTopLeft(find.text('另一首')).dy;
    final double yc = tester.getTopLeft(find.text('c')).dy;
    expect(ya < yb, isTrue);
    expect(yb < yc, isTrue);
  });

  testWidgets('长按进入多选，出现操作条', (WidgetTester tester) async {
    final Repo repo = Repo.instance;
    repo.resetForTest();
    seed(repo);
    await pumpPage(tester);

    await tester.longPress(find.text('示例歌名'));
    await tester.pumpAndSettle();

    expect(find.textContaining('已选'), findsOneWidget);
    expect(find.text('全选'), findsOneWidget);
    expect(find.text('匹配标签'), findsOneWidget);
  });

  testWidgets('搜索能过滤（按歌手）', (WidgetTester tester) async {
    final Repo repo = Repo.instance;
    repo.resetForTest();
    seed(repo);
    await pumpPage(tester);

    await tester.enterText(find.byType(TextField), '示例歌手');
    await tester.pumpAndSettle();

    expect(find.text('示例歌名'), findsOneWidget);
    expect(find.text('另一首'), findsNothing);
  });
}
