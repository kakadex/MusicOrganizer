/// 「垃圾文件」自动后台扫描的界面级回归（0.2.58）。
///
/// 这一版把「先点一下才开始扫」改成「进页面自动在后台扫一次 + 进度条」，
/// 这里盯三件事：
/// 1. 进清理页不用任何点击就会开始扫，扫描中能看到进度条与已扫过数量；
/// 2. 扫完显示「发现 N 个」，N 与判定规则一致；
/// 3. 扫过一次之后返回再进来不重扫（安卓上 SAF 遍历很贵，不能每次进页面都走一遍）。
///
/// 不依赖任何插件：存储层用内存假实现，只实现 `children()`。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/app/repo.dart';
import 'package:musicorganizer/core/fs/file_store.dart';
import 'package:musicorganizer/core/fs/tree_ref.dart';
import 'package:musicorganizer/core/model/vfile.dart';
import 'package:musicorganizer/feature/organize/organize_page.dart';

/// 内存目录树：docId -> 子项。只实现遍历要用的 `children()`。
class _MemStore implements FileStore {
  _MemStore(this.tree);

  final Map<String, List<VFile>> tree;

  /// 被调用了几次：用来断言「第二次进页面没有重新遍历」。
  int childCalls = 0;

  /// 非空时 `children()` 会等它完成，测试借此停在「正在扫描」那一帧上。
  Completer<void>? gate;

  @override
  Future<List<VFile>> children(VFile dir) async {
    childCalls++;
    final Completer<void>? g = gate;
    if (g != null) await g.future;
    return tree[dir.docId] ?? const <VFile>[];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

VFile _f(String parent, String name, {int size = 5 * 1024 * 1024, bool dir = false}) =>
    VFile(
      docId: '$parent/$name',
      parentId: parent,
      name: name,
      size: dir ? 0 : size,
      lastModified: 1,
      dir: dir,
    );

void main() {
  final Repo repo = Repo.instance;

  setUp(() {
    repo.resetForTest();
    OrganizePage.resetJunkCacheForTest();
  });

  _MemStore buildStore() {
    final VFile sub = _f('r', '子目录', dir: true);
    return _MemStore(<String, List<VFile>>{
      'r': <VFile>[
        _f('r', '示例歌名.mp3'),
        _f('r', 'Thumbs.db', size: 1024),
        _f('r', '示例歌名.lrc', size: 256),
        sub,
      ],
      sub.docId: <VFile>[
        _f('sub', '示例歌名.mp3.tmp', size: 128),
      ],
    });
  }

  Future<void> pumpCleanupPage(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: OrganizePage(section: OrganizeSection.cleanup, embedded: true),
    ));
    await tester.pump(); // 首帧 + postFrame 回调（排上自动扫描）
  }

  testWidgets('进清理页自动开始扫描：显示进度条与已扫过数量，扫完显示发现数',
      (WidgetTester tester) async {
    final _MemStore store = buildStore()..gate = Completer<void>();
    repo.store = store;
    repo.setRoots(<TreeRef>[const TreeRef(treeUri: 'file:///r', rootDocId: 'r')]);

    await pumpCleanupPage(tester);
    // 还没点任何东西，也没有开始扫（等转场动画走完）
    expect(find.textContaining('正在后台'), findsNothing);

    // 300ms 后自动开始；卡在 children() 上，停在「扫描中」这一帧
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.textContaining('正在后台扫描'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.textContaining('点一下停止'), findsOneWidget);

    // 放行，让遍历跑完
    store.gate!.complete();
    await tester.pump();
    await tester.pump();

    // Thumbs.db（系统垃圾）+ .tmp（临时文件）两个候选
    expect(find.textContaining('发现 2 个'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('扫过之后再进页面不重扫（复用本次运行的结果）',
      (WidgetTester tester) async {
    final _MemStore store = buildStore();
    repo.store = store;
    repo.setRoots(<TreeRef>[const TreeRef(treeUri: 'file:///r', rootDocId: 'r')]);

    await pumpCleanupPage(tester);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('发现 2 个'), findsOneWidget);
    final int first = store.childCalls;
    expect(first, greaterThan(0));

    // 关掉页面再进来（同一个曲库目录）
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await pumpCleanupPage(tester);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();

    expect(find.textContaining('发现 2 个'), findsOneWidget);
    expect(store.childCalls, first, reason: '第二次进页面不应再遍历目录树');
  });

  testWidgets('扫描中点一下可停止，结果作废、下次进来重扫',
      (WidgetTester tester) async {
    final _MemStore store = buildStore()..gate = Completer<void>();
    repo.store = store;
    repo.setRoots(<TreeRef>[const TreeRef(treeUri: 'file:///r', rootDocId: 'r')]);

    await pumpCleanupPage(tester);
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.textContaining('正在后台扫描'), findsOneWidget);

    await tester.tap(find.text('垃圾文件'));
    await tester.pump();
    store.gate!.complete();
    await tester.pump();

    expect(find.textContaining('正在后台扫描'), findsNothing);
    expect(find.textContaining('准备扫描'), findsOneWidget);
  });
}
