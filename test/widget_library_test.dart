import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart' hide Tags;
import 'package:musicorganizer/app/repo.dart';
import 'package:musicorganizer/app/repo_changes.dart';
import 'package:musicorganizer/app/theme/mo_theme.dart';
import 'package:musicorganizer/app/theme/palette.dart';
import 'package:musicorganizer/app/ui_kit.dart';
import 'package:musicorganizer/core/fs/file_store.dart';
import 'package:musicorganizer/core/model/tags.dart';
import 'package:musicorganizer/core/fs/tree_ref.dart';
import 'package:musicorganizer/core/model/vfile.dart';
import 'package:musicorganizer/core/scan/search_index.dart';
import 'package:musicorganizer/feature/library/library_page.dart';

/// 曲库页的界面级回归：不依赖任何插件（SAF / SharedPreferences / path_provider），
/// 直接把 Repo 的曲库与索引塞好再挂页面，验证渲染 / 筛选 / 排序 / 多选。

/// 内存目录树：只实现扫描要用的 `children()`，其余走 noSuchMethod 兜底。
class _MemStore implements FileStore {
  _MemStore(this.tree);

  final Map<String, List<VFile>> tree;

  /// `children()` 被调用的次数，断言「root 到达后真的发生了扫描」。
  int childCalls = 0;

  @override
  Future<List<VFile>> children(VFile dir) async {
    childCalls++;
    return tree[dir.docId] ?? const <VFile>[];
  }

  // 0.3.7 桌面交互测试会走「双击播放」：FileStore 基类的 openWithPlayer
  // 是具体方法（不是抽象），noSuchMethod 兜底反而拦截不到它——必须显式
  // 覆写为「成功拉起」返回 null，否则测试环境报 NoSuchMethodError。
  @override
  Future<String?> openWithPlayer(VFile f) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  // 数据目录注入：单测环境没有 path_provider 插件，不给注入点的话
  // 后台增量扫触发的 saveLibraryCache 会挂起 20ms 轮询 Timer，
  // 每条用例结束时都报「Timer is still pending」。
  setUpAll(() {
    Repo.dataDirOverride = () async => Directory.systemTemp.createTemp('mo_test_');
  });

  VFile audio(String id, String name, {int size = 1024}) =>
      VFile(docId: id, parentId: 'r', name: name, size: size, lastModified: 1);

  void seed(Repo repo) {
    // 桌面端页面初始化会后台增量扫（repo.rescan → store.children / stat），
    // 不给 store 的话 rescan 会把 rootUnavailable 置真、页面被空状态盖住——
    // 手机端首次授权路径不会走到这（resetForTest 已清 rootUnavailable），
    // 桌面测试宿主上必须给一个能列出内容的 store。
    repo.store = _MemStore(<String, List<VFile>>{
      'r': <VFile>[audio('r/a.mp3', 'a.mp3'), audio('r/b.mp3', 'b.mp3', size: 2048), audio('r/c.flac', 'c.flac', size: 4096)],
    });
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
      theme: MoTheme.build(MoPalette.light, dark: false),
      home: const Scaffold(body: LibraryPage()),
    ));
    await tester.pumpAndSettle();
    // seed 给了 store 后，页面初始化的后台增量扫会触发 saveLibraryCache；
    // 它内部有 20ms 轮询等待（repo.dart:478），pumpAndSettle 收不掉真 Timer，
    // 用 pump 推进假时钟把它耗干，否则用例结束时报「Timer is still pending」。
    await tester.pump(const Duration(seconds: 1));
  }

  /// 0.2.63 回归：首屏可能比授权恢复先出来（shell._boot 不再等 restoreRoot）。
  /// 此时 LibraryPage 看到「没 root」不能直接放弃，得等 root 通知一到就补扫。
  testWidgets('首屏先于授权恢复出现时，root 一到会自动补扫',
      (WidgetTester tester) async {
    final Repo repo = Repo.instance;
    repo.resetForTest();
    // 模拟「init 完成、restoreRoot 还没跑」：无 root、无 files，但 store 已就绪
    final _MemStore store = _MemStore(<String, List<VFile>>{
      'r': <VFile>[audio('r/a.mp3', 'a.mp3')],
    });
    repo.store = store;

    await tester.pumpWidget(MaterialApp(
      theme: MoTheme.build(MoPalette.light, dark: false),
      home: const Scaffold(body: LibraryPage()),
    ));
    await tester.pumpAndSettle();

    // 还没授权：应显示空状态，且没有扫描动作
    // 注意：顶部副标题与空状态各有一处「还没有选择曲库目录」，所以用 findsWidgets
    expect(store.childCalls, 0);
    expect(find.text('还没有选择曲库目录'), findsWidgets);

    // 授权恢复到达（等价于 restoreRoot 完成后的 setRoots + 通知）
    repo.setRoots(<TreeRef>[const TreeRef(treeUri: 'file:///r', rootDocId: 'r')]);
    await tester.pumpAndSettle();

    // 关键断言：扫描真的被触发了——children 至少被调用一次
    expect(store.childCalls, greaterThan(0),
        reason: 'root 到达后应自动补扫，不能停在空状态等人手动刷新');
  });

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

  testWidgets('长按后拖动到下一行，会连选下一行（拖选 O(1) 反查）',
      (WidgetTester tester) async {
    final Repo repo = Repo.instance;
    repo.resetForTest();
    seed(repo);
    await pumpPage(tester);

    // 真实拖选手势：按下第一行 → 按住超过长按阈值进入多选 → **不抬手指** →
    // 继续拖到第二行。不能用 tester.longPress()（它内部会抬手指，
    // 把 _dragSelecting 又关掉）。
    final Offset first = tester.getCenter(find.text('示例歌名'));
    final Offset second = tester.getCenter(find.text('另一首'));
    final TestGesture gesture = await tester.startGesture(first);
    await tester.pump(const Duration(milliseconds: 600)); // 超过长按阈值 500ms
    await tester.pumpAndSettle();
    expect(find.textContaining('已选 1'), findsOneWidget,
        reason: '长按后第一行应被选中');

    // 拖到第二行中心
    await gesture.moveTo(second);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    final Finder bar = find.textContaining('已选');
    expect(bar, findsOneWidget);
    final String text = (tester.widget<Text>(bar).data) ?? '';
    final int n = int.parse(RegExp(r'已选 (\d+)').firstMatch(text)!.group(1)!);
    expect(n, greaterThanOrEqualTo(2), reason: '拖到第二行应连选，实际 $text');
  });

  testWidgets('Ctrl+A 全选并进入多选，Esc 退出多选', (WidgetTester tester) async {
    final Repo repo = Repo.instance;
    repo.resetForTest();
    seed(repo);
    await pumpPage(tester);

    // 先把焦点交给页面（真实使用里焦点在页面/输入框上）
    await tester.tap(find.text('示例歌名').first);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    // 详情面板会弹出，先关掉
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(find.text('已选 3'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
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

  group('桌面端交互（0.3.7 第一期）', () {
    // 注意：flutter test 在桌面宿主上跑，Repo.isDesktop == true，
    // 所以这里验证的就是桌面路径的真实行为。
    //
    // 【手势机制前提】SongRow 的 InkWell 同时注册了 onTap 与 onDoubleTap：
    // Flutter 的双击识别器会让**单击延迟约 300ms**（等双击超时）才触发，
    // 这是框架固有行为（Windows 资源管理器同款体验）。测试里凡断言单击
    // 效果，必须先 pump 400ms 推过这个超时，否则 onTap 还没执行。
    testWidgets('Ctrl+点击行 = 进入多选并选中该行（不弹详情）',
        (WidgetTester tester) async {
      final Repo repo = Repo.instance;
      repo.resetForTest();
      seed(repo);
      await pumpPage(tester);

      // tap 回调同步读 HardwareKeyboard 全局状态：Ctrl 按下 → tap → pump 过
      // 双击超时（回调在超时后才跑，此时 Ctrl 仍按住）→ 松开
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(find.text('示例歌名').first);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.text('已选 1'), findsOneWidget,
          reason: 'Ctrl+点击应进多选并选中');
      expect(find.text('编辑标签'), findsNothing,
          reason: '不应弹出详情面板');
    });

    testWidgets('Shift+点击第二行 = 从锚点范围选中（锚点=上次点击行）',
        (WidgetTester tester) async {
      final Repo repo = Repo.instance;
      repo.resetForTest();
      seed(repo);
      await pumpPage(tester);

      // 先普通点击第一行（pump 过双击超时后进详情），关掉——确立锚点=行 0
      await tester.tap(find.text('示例歌名').first);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      // Shift+点击第三行：行 0 到行 2 全选（回调在双击超时后跑，那时 Shift
      // 必须仍按住，所以 keyUp 放在 pump 之后）
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tap(find.text('c').first);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();

      expect(find.text('已选 3'), findsOneWidget,
          reason: 'Shift+点击应范围选中 0..2 三行');
    });

    testWidgets('双击行 = 播放（不弹详情面板）', (WidgetTester tester) async {
      final Repo repo = Repo.instance;
      repo.resetForTest();
      seed(repo);
      await pumpPage(tester);

      // 手工双击：两次 tap 间隔小于双击阈值，第二次 tap 触发 onDoubleTap（播放）。
      // 第一击的 onTap 在双击超时后本会弹详情，但第二击构成双击后 onTap 取消、
      // onDoubleTap 接管——详情不应留下。
      await tester.tap(find.text('示例歌名').first);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(find.text('示例歌名').first);
      await tester.pumpAndSettle();
      // 换歌窗口 Timer（play() 里 3 秒）用假时钟推过去，避免 pending timer
      await tester.pump(const Duration(seconds: 4));

      expect(find.text('编辑标签'), findsNothing,
          reason: '双击的最终态不应停在详情面板');
      // 双击走播放：桌面端 MiniPlayer 走 openExternal（测试桩返回 null=成功），
      // 这里只验证「详情没弹出来」= 双击语义生效。
    });

    testWidgets('右键行 = 弹上下文菜单（含播放/详情/编辑/多选）',
        (WidgetTester tester) async {
      final Repo repo = Repo.instance;
      repo.resetForTest();
      seed(repo);
      await pumpPage(tester);

      final Offset pos = tester.getCenter(find.text('示例歌名'));
      final TestGesture gesture = await tester.startGesture(pos,
          kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(find.text('播放'), findsOneWidget);
      expect(find.text('查看详情'), findsOneWidget);
      expect(find.text('编辑标签'), findsOneWidget);
      expect(find.text('加入多选'), findsOneWidget);

      // 选「查看详情」应正常弹出详情（面板里的「编辑标签」按钮出现）
      await tester.tap(find.text('查看详情'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('编辑标签'), findsOneWidget);
    });

    testWidgets('普通单击仍进详情（桌面端默认行为不变）',
        (WidgetTester tester) async {
      final Repo repo = Repo.instance;
      repo.resetForTest();
      seed(repo);
      await pumpPage(tester);

      // 详情面板的编辑按钮文案是「编辑标签」。断言面板出现用它。
      // 【必须 pump 400ms】：单击在注册了 onDoubleTap 的 InkWell 上要等
      // 双击超时才触发（见本 group 头部说明），pumpAndSettle 不够。
      await tester.tap(find.text('示例歌名').first);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('编辑标签'), findsOneWidget, reason: '单击应弹详情');
    });
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

  // ------------------------------------------------------------------
  // 搜索防抖：连续输入合并成一次过滤；但「回车」「清空」必须立刻生效，
  // 否则用户打完字马上回车会拿到上一轮查询的结果。
  // ------------------------------------------------------------------
  group('搜索防抖', () {
    testWidgets('防抖窗口内列表保持不变，窗口过后才过滤',
        (WidgetTester tester) async {
      final Repo repo = Repo.instance;
      repo.resetForTest();
      seed(repo);
      await pumpPage(tester);

      // 初始三首都可见
      expect(find.text('示例歌名'), findsOneWidget);
      expect(find.text('另一首'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '示例歌手');
      // 只推进很短的时间，还没到 150ms 防抖窗口
      await tester.pump(const Duration(milliseconds: 50));

      // 还没过滤：「另一首」仍在
      expect(find.text('另一首'), findsOneWidget,
          reason: '防抖窗口内不应立刻过滤');

      // 越过防抖窗口
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();

      expect(find.text('示例歌名'), findsOneWidget);
      expect(find.text('另一首'), findsNothing,
          reason: '防抖窗口过后应完成过滤');
    });

    testWidgets('连续输入只按最后一次过滤', (WidgetTester tester) async {
      final Repo repo = Repo.instance;
      repo.resetForTest();
      seed(repo);
      await pumpPage(tester);

      // 模拟快速连打：每次间隔都小于防抖窗口
      await tester.enterText(find.byType(TextField), '示');
      await tester.pump(const Duration(milliseconds: 40));
      await tester.enterText(find.byType(TextField), '示例');
      await tester.pump(const Duration(milliseconds: 40));
      await tester.enterText(find.byType(TextField), '示例歌手');

      // 此时仍不应过滤（每次输入都会重置计时器）
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('另一首'), findsOneWidget,
          reason: '连续输入期间不应过滤');

      // 停顿超过窗口，按最后一次查询过滤
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(find.text('示例歌名'), findsOneWidget);
      expect(find.text('另一首'), findsNothing);
    });

    testWidgets('回车立即生效，不必等防抖窗口', (WidgetTester tester) async {
      final Repo repo = Repo.instance;
      repo.resetForTest();
      seed(repo);
      await pumpPage(tester);

      await tester.enterText(find.byType(TextField), '示例歌手');
      // 立刻提交（不等 150ms）
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(find.text('示例歌名'), findsOneWidget);
      expect(find.text('另一首'), findsNothing,
          reason: '回车应立即生效，不能等防抖');
    });

    testWidgets('清空按钮立即恢复全部曲目', (WidgetTester tester) async {
      final Repo repo = Repo.instance;
      repo.resetForTest();
      seed(repo);
      await pumpPage(tester);

      await tester.enterText(find.byType(TextField), '示例歌手');
      await tester.pumpAndSettle();
      expect(find.text('另一首'), findsNothing);

      // 点搜索框右侧的清空按钮
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();

      expect(find.text('另一首'), findsOneWidget,
          reason: '清空应立刻恢复，不必等防抖');
      expect(find.text('示例歌名'), findsOneWidget);
    });
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

  testWidgets('多选时按返回（含左右边缘侧滑）先退出多选，不退出应用',
      (WidgetTester tester) async {
    final Repo repo = Repo.instance;
    repo.resetForTest();
    seed(repo);
    await pumpPage(tester);

    await tester.longPress(find.text('示例歌名'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已选'), findsOneWidget);

    // 系统返回：安卓全面屏的左右边缘侧滑走的就是这条路由
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.textContaining('已选'), findsNothing, reason: '返回应当只退出多选');
    expect(find.text('音乐库'), findsOneWidget, reason: '页面还在，没被退出应用');
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
    // 菜单项变多了：按视觉顺序逐项滚到可见再断言（一次滚到底会把上面的顶出去）
    final Finder scrollable = find.byType(Scrollable).last;
    for (final String item in <String>[
      '批量改标签',
      '歌词工具',
      '删除全部封面、标签、歌词',
      '标签转简体',
      '按标签改名',
      '删除选中的文件',
    ]) {
      await tester.scrollUntilVisible(find.text(item), 80, scrollable: scrollable);
      expect(find.text(item), findsOneWidget);
    }
  });
}
