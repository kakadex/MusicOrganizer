/// 批量歌词「继续上次」必须真的续上：续跑进来的行不再联网，只有「重新获取」才重查。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart' hide Tags;
import 'package:musicorganizer/app/repo.dart';
import 'package:musicorganizer/core/fs/file_store.dart';
import 'package:musicorganizer/core/fs/tree_ref.dart';
import 'package:musicorganizer/core/match/match_queue.dart';
import 'package:musicorganizer/core/model/lyric_hit.dart';
import 'package:musicorganizer/core/model/tags.dart';
import 'package:musicorganizer/core/model/vfile.dart';
import 'package:musicorganizer/core/source/aggregator.dart';
import 'package:musicorganizer/feature/lyrics_batch/lyrics_batch_page.dart';

/// 最小文件系统：页面只要求 store 非空，读标签走的是已缓存的 meta。
class _FakeStore extends FileStore {
  @override
  Future<List<TreeRef>> roots() async => <TreeRef>[];

  @override
  Future<TreeRef?> pickTree() async => null;

  @override
  Future<void> releaseTree(TreeRef t) async {}

  @override
  Future<VFile?> stat(String id) async => null;

  @override
  Future<List<VFile>> children(VFile dir) async => <VFile>[];

  @override
  Uri documentUri(String id) => Uri.parse('file:///$id');

  @override
  Future<Uint8List> headBytes(VFile f, int maxBytes) async => Uint8List(0);

  @override
  Future<Uint8List> tailBytes(VFile f, int maxBytes) async => Uint8List(0);

  @override
  Future<void> copyToLocal(VFile f, File cacheTarget) async {}

  @override
  Future<void> writeFromLocal(VFile f, File cacheSource) async {}

  @override
  Future<VFile> createFile(VFile parent, String name, String mime) async =>
      VFile(docId: name, name: name);

  @override
  Future<VFile> createDir(VFile parent, String name) async =>
      VFile(docId: name, name: name, dir: true);

  @override
  Future<bool> delete(VFile f) async => false;

  @override
  Future<bool> rename(VFile f, String newName) async => false;

  @override
  Future<String?> move(VFile f, VFile targetDir) async => null;
}

void main() {
  testWidgets('续跑进来点「获取歌词」不联网；「重新获取」才重查 3 首',
      (WidgetTester tester) async {
    final Repo repo = Repo.instance;
    repo.resetForTest();
    repo.store = _FakeStore();
    // testWidgets 跑在 FakeAsync 里，真实 I/O 的 await 永不完成，必须用同步版
    final Directory dir = Directory.systemTemp.createTempSync('mo_ly_');
    repo.lyricsQueue = MatchQueue.open(dir, 'lyrics');

    final List<VFile> files = <VFile>[];
    for (int i = 0; i < 3; i++) {
      final VFile f = VFile(
        docId: 'd$i',
        name: 's$i.mp3',
        size: 100 + i,
        lastModified: 1000 + i,
      );
      // 已读过标签：页面读 meta 不会碰磁盘
      f.cacheMeta(Tags()..put('title', '歌$i'), cover: false, lyrics: false);
      files.add(f);
      // 上次查到的结果（续跑队列）
      repo.lyricsQueue!.put('d$i', f.size, f.lastModified, <String, String>{
        'text': '[00:01.00]上次的歌词$i',
        'title': '歌$i',
        'artist': '人$i',
        'source': 'netease',
        'score': '0.9',
      });
    }

    int calls = 0;
    LyricsBatchPage.debugLyricFetcher = (Object q) async {
      calls++;
      return LyricAggregateResult(<LyricHit>[], <String, String>{});
    };

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: LyricsBatchPage(files: files)),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('继续上次 3/3'), findsOneWidget);

    // 点「获取歌词」：续跑结果已经在了，不应该再联网
    await tester.tap(find.text('获取歌词'));
    // 注入的取词是立即返回的内存 Future，逐帧 pump 把微任务推完即可
    // （任务条有无限进度动画，不能用 pumpAndSettle）
    for (int i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(calls, 0, reason: '续跑进来的行必须跳过联网');

    // 点「重新获取」：这才是真的重查
    await tester.tap(find.text('重新获取'));
    for (int i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(calls, 3, reason: '重新获取要逐首重查');

    LyricsBatchPage.debugLyricFetcher = null;
    // 卸掉页面，让 TaskBar 的周期定时器随 dispose 取消；
    // 再把时间推过 SnackBar 的存活期，避免测试结束时还挂着定时器
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 12));
    dir.deleteSync(recursive: true);
  });
}
