/// 限流标记与「无命中记忆」的离线回归。
///
/// 背景：源被熔断冷却时 Http 直接返回空、**不抛异常**，看起来和「真的没有」
/// 一样。标签批量因此会把「被限流」记成「无命中」，下一轮永久跳过这首歌。
/// 这里锁住三件事：
/// 1. 聚合结果带 throttled 标记；
/// 2. 被限流时不写 noHit 记忆、并进 throttledIds；
/// 3. 正常应答但没有结果时照旧写 noHit（下一轮该跳过，别把这条也弄丢）。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/fs/desktop_file_store.dart';
import 'package:musicorganizer/core/match/batch_memory.dart';
import 'package:musicorganizer/core/match/tag_plan.dart';
import 'package:musicorganizer/core/model/query.dart';
import 'package:musicorganizer/core/model/vfile.dart';
import 'package:musicorganizer/core/net/http_client.dart';
import 'package:musicorganizer/core/scan/scanner.dart';
import 'package:musicorganizer/core/source/aggregator.dart';
import 'package:musicorganizer/core/source/lyric_source.dart';
import 'package:musicorganizer/core/tag/id3.dart';
import 'package:musicorganizer/core/task/match_runner.dart';
import 'package:musicorganizer/core/tx/journal.dart';
import 'package:musicorganizer/core/tx/tag_transaction.dart';

/// 所有源都「正常应答但没有结果」。
Future<Object?> emptyJson(String url, Map<String, String>? params) async =>
    <String, Object?>{};

/// 让某主机进入熔断冷却（连续失败 2 次即触发，见 HostBreaker.failThreshold）。
void trip(String host) {
  Http.breaker.noteFail(host, '测试限流');
  Http.breaker.noteFail(host, '测试限流');
}

void main() {
  late Directory dir;

  const List<String> touchedHosts = <String>[
    'music.163.com',
    'lrclib.net',
  ];

  setUp(() {
    for (final String h in touchedHosts) {
      Http.breaker.noteOk(h);
    }
    dir = Directory.systemTemp.createTempSync('mo_throttle_');
  });

  tearDown(() {
    for (final String h in touchedHosts) {
      Http.breaker.noteOk(h);
    }
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Query tagQuery() => Query()
    ..embeddedTags = <String, String>{'title': '晴天', 'artist': '周杰伦'}
    ..filenameCandidates = <List<String>>[
      <String>['周杰伦', '晴天'],
    ];

  group('Aggregator 限流标记', () {
    test('标签：有源在冷却时 throttled=true', () async {
      trip('music.163.com');
      final AggregateResult r =
          await Aggregator.tagCandidates(tagQuery(), fetch: emptyJson);
      expect(r.candidates, isEmpty);
      expect(r.throttled, isTrue);
    });

    test('标签：没有源冷却时 throttled=false', () async {
      final AggregateResult r =
          await Aggregator.tagCandidates(tagQuery(), fetch: emptyJson);
      expect(r.throttled, isFalse);
    });

    test('歌词：有源在冷却时 throttled=true', () async {
      trip('lrclib.net');
      final LyricAggregateResult r = await Aggregator.lyricCandidates(
        LyricQuery(title: '晴天', artist: '周杰伦'),
        json: (String url, Map<String, String>? params) async =>
            <String, Object?>{},
      );
      expect(r.hits, isEmpty);
      expect(r.throttled, isTrue);
    });
  });

  group('MatchRunner 与「无命中」记忆', () {
    Future<(MatchRunner, BatchMemory, VFile)> makeRunner() async {
      final DesktopFileStore store = DesktopFileStore();
      store.addRoot(dir.path);
      Uint8List data = Uint8List.fromList(List<int>.filled(2048, 0xFF));
      data = Id3.rewrite(data, <String, String>{
        'title': '晴天',
        'artist': '周杰伦',
      });
      await File('${dir.path}/a.mp3').writeAsBytes(data);
      final VFile rootDir = VFile(docId: dir.path, name: 'root', dir: true);
      final WalkResult walk = await Scanner.scanMusicFiles(store, rootDir);
      final VFile a = walk.files.single;
      final Journal journal = Journal(File('${dir.path}/journal.jsonl'));
      final TagTransaction tx = TagTransaction(store: store, journal: journal);
      final BatchMemory memory = BatchMemory.open(dir, 'tags');
      return (MatchRunner(store: store, tx: tx, memory: memory), memory, a);
    }

    test('被限流：不写 noHit 记忆，进 throttledIds', () async {
      final (MatchRunner runner, BatchMemory memory, VFile a) =
          await makeRunner();
      trip('music.163.com');
      final List<FilePlan> plans =
          await runner.match(<VFile>[a], fetch: emptyJson);
      expect(plans.single.note, contains('限流'));
      expect(runner.throttledIds, contains(a.docId));
      expect(memory.statusOf(a.docId, a.size, a.lastModified),
          isNot(BatchMemory.noHit),
          reason: '被限流不能记成「无命中」，否则下一轮永久跳过');
    });

    test('正常应答但无结果：照旧记 noHit（下一轮该跳过）', () async {
      final (MatchRunner runner, BatchMemory memory, VFile a) =
          await makeRunner();
      final List<FilePlan> plans =
          await runner.match(<VFile>[a], fetch: emptyJson);
      expect(plans.single.note, isNot(contains('限流')));
      expect(runner.throttledIds, isEmpty);
      expect(memory.statusOf(a.docId, a.size, a.lastModified),
          BatchMemory.noHit);
    });
  });
}
