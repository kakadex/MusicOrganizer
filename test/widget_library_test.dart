import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart' hide Tags;
import 'package:musicorganizer/app/repo.dart';
import 'package:musicorganizer/app/repo_changes.dart';
import 'package:musicorganizer/app/theme/mo_theme.dart';
import 'package:musicorganizer/app/theme/palette.dart';
import 'package:musicorganizer/app/ui_kit.dart';
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
    repo.setRoots(<TreeRef>[const TreeRef(treeUri: 'file:///r', rootDocId: 'r')]);
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

  testWidgets('标签读回后列表自动更新，不用手动刷新', (WidgetTester tester) async {
    final Repo repo = Repo.instance;
    repo.resetForTest();
    seed(repo);
    await pumpPage(tester);
    expect(find.text('示例歌名'), findsOneWidget);

    // 模拟「清空标签 → loadMeta 补读」的结果：VFile 与索引都换成空标签，
    // 再像 Repo.loadMeta 那样发一次 library 通知。
    // 页面不订阅这个通知的话，这里仍会显示旧标题，得手动下拉才更新。
    final VFile a = repo.files.firstWhere((VFile f) => f.docId == 'r/a.mp3');
    a.cacheMeta(Tags(), cover: false);
    repo.index.find(a.docId)?.applyTags(Tags(), false);
    repo.changes.emit(RepoDomain.library);
    await tester.pump();

    expect(find.text('示例歌名'), findsNothing, reason: '清空后不该还挂着旧标题');
    expect(find.text('a'), findsOneWidget, reason: '没有标签时应退化成文件名');
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
    // 批量补标签已收进「更多」，底部不再有独立按钮
    expect(find.text('更多'), findsOneWidget);
    expect(find.text('匹配标签'), findsNothing);
  });

  testWidgets('Ctrl+A 全选并进入多选，Esc 退出多选', (WidgetTester tester) async {
    final Repo repo = Repo.instance;
    repo.resetForTest();
    seed(repo);
    await pumpPage(tester);

    // 先把焦点交给页面（真实使用里焦点在页面/输入框上）
    await tester.tap(find.text('示例歌名'));
    await tester.pumpAndSettle();
    // 详情面板会弹出，先关掉
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(find.text('已选 3'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.textContaining('已选'), findsNothing);
  });

  testWidgets('Ctrl+F 聚焦搜索框', (WidgetTester tester) async {
    final Repo repo = Repo.instance;
    repo.resetForTest();
    seed(repo);
    await pumpPage(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    final EditableText field = tester.widget<EditableText>(find.byType(EditableText));
    expect(field.focusNode.hasFocus, isTrue);
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

  testWidgets('排序项里有「修改时间」和「标签完整度」', (WidgetTester tester) async {
    final Repo repo = Repo.instance;
    repo.resetForTest();
    seed(repo);
    await pumpPage(tester);

    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();

    expect(find.text('修改时间'), findsOneWidget);
    expect(find.text('标签完整度'), findsOneWidget);
  });

  testWidgets('搜索命中的词在标题里高亮（拆成多段渲染）',
      (WidgetTester tester) async {
    final Repo repo = Repo.instance;
    repo.resetForTest();
    seed(repo);
    await pumpPage(tester);

    await tester.enterText(find.byType(TextField), '示例歌名');
    await tester.pumpAndSettle();

    // 命中后标题用 Text.rich 渲染：命中词单独成段且加粗
    final Finder richFinder =
        find.descendant(of: find.byType(SongRow), matching: find.byType(RichText));
    final List<TextSpan> runs = <TextSpan>[];
    for (final Element e in richFinder.evaluate()) {
      final RichText rt = e.widget as RichText;
      final TextSpan? span = rt.text is TextSpan ? rt.text as TextSpan : null;
      if (span == null || span.children == null) continue;
      for (final InlineSpan c in span.children!) {
        if (c is! TextSpan) continue;
        // Text.rich 会再包一层：命中段落在内层
        if (c.children != null) {
          for (final InlineSpan g in c.children!) {
            if (g is TextSpan) runs.add(g);
          }
        } else {
          runs.add(c);
        }
      }
    }
    final Iterable<TextSpan> bold = runs.where(
        (TextSpan s) => s.text == '示例歌名' && s.style?.fontWeight == FontWeight.w700);
    expect(bold, isNotEmpty);
  });

  testWidgets('多选菜单里有批量改标签 / 改名 / 歌词工具 / 删除全部封面标签歌词 / 删除',
      (WidgetTester tester) async {
    final Repo repo = Repo.instance;
    repo.resetForTest();
    seed(repo);
    await pumpPage(tester);

    await tester.longPress(find.text('示例歌名'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('更多'));
    await tester.pumpAndSettle();

    expect(find.text('批量补标签'), findsOneWidget);
    expect(find.text('批量改标签'), findsOneWidget);
    expect(find.text('按标签改名'), findsOneWidget);
    expect(find.text('歌词工具'), findsOneWidget);
    expect(find.text('删除全部封面、标签、歌词'), findsOneWidget);
    // 「删除选中的文件」在面板折叠区外，滚一下再断言
    await tester.scrollUntilVisible(find.text('删除选中的文件'), 120,
        scrollable: find.byType(Scrollable).last);
    expect(find.text('删除选中的文件'), findsOneWidget);
  });
}
