import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/match/batch_memory.dart';
import 'package:musicorganizer/core/match/match_queue.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('mo_mq_');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// 一条随手可用的匹配字段。
  Map<String, String> fields([String title = '示例标题']) =>
      <String, String>{'title': title, 'artist': '示例歌手', '@conf': '0.92'};

  test('指纹一致才能命中：size / lastModified 变了要重来', () {
    final MatchQueue q = MatchQueue.open(dir, 'fp');
    q.put('a.mp3', 100, 1000, fields());
    final MatchItem? hit = q.take('a.mp3', 100, 1000);
    expect(hit, isNotNull);
    expect(hit!.field('title', ''), '示例标题');
    expect(hit.field('@conf', ''), '0.92');
    expect(hit.isPending(), isTrue);

    // 取回的是副本：改它不污染队列
    hit.fields['title'] = '被改掉';
    expect(q.take('a.mp3', 100, 1000)!.field('title', ''), '示例标题');

    expect(q.take('a.mp3', 101, 1000), isNull, reason: '大小变了不算同一文件');
    expect(q.countPending(), 0, reason: '指纹对不上就地剔除');

    q.put('b.mp3', 200, 2000, fields());
    expect(q.take('b.mp3', 200, 2001), isNull, reason: '时间变了不算同一文件');

    // mtime 取不到（0）时只比大小
    q.put('c.mp3', 300, 0, fields());
    expect(q.take('c.mp3', 300, 9999), isNotNull);
  });

  test('四态流转：take → put → mark written', () {
    final MatchQueue q = MatchQueue.open(dir, 'st');
    q.put('d.mp3', 400, 4000, fields());
    q.mark('d.mp3', MatchQueue.written);
    expect(q.take('d.mp3', 400, 4000), isNull, reason: '已写入不再取回');
    expect(q.countPending(), 0);
    expect(q.countOf(MatchQueue.written), 1);

    q.put('e.mp3', 500, 5000, fields());
    q.mark('e.mp3', MatchQueue.skipped);
    expect(q.take('e.mp3', 500, 5000), isNull);

    q.put('g.mp3', 700, 7000, fields());
    q.mark('g.mp3', MatchQueue.failed);
    expect(q.take('g.mp3', 700, 7000), isNull);
    expect(q.countOf(MatchQueue.failed), 1);

    // 重新 put 会把状态刷回 pending（失败后重来）
    q.put('g.mp3', 700, 7000, fields('新标题'));
    expect(q.take('g.mp3', 700, 7000)!.field('title', ''), '新标题');
  });

  test('落盘后重开（模拟进程重启）仍在工作', () {
    final MatchQueue q = MatchQueue.open(dir, 'persist');
    q.put('x.mp3', 10, 20, <String, String>{'@content': '第一行\n第二行'});
    expect(q.save(), isTrue);

    final MatchQueue reload = MatchQueue.open(dir, 'persist');
    expect(reload.countPending(), 1);
    expect(reload.take('x.mp3', 10, 20)!.field('@content', ''), '第一行\n第二行');
    expect(MatchQueue.open(dir, 'other').countPending(), 0, reason: '不同 kind 互不干扰');
    expect(reload.file.path.endsWith('queue-persist.json'), isTrue);

    // 每 30 条自动落盘一次：不显式 save 也不会全丢
    final MatchQueue auto = MatchQueue.open(dir, 'auto');
    for (int i = 0; i < 30; i++) {
      auto.put('auto$i.mp3', i, i, fields());
    }
    expect(MatchQueue.open(dir, 'auto').countPending(), 30);
  });

  test('过期条目被清理（14 天）', () {
    final int old = DateTime.now().millisecondsSinceEpoch - 20 * 24 * 3600 * 1000;
    File('${dir.path}/queue-old.json').writeAsStringSync(
        '{"version":1,"kind":"old","items":[{"k":"z.mp3","s":1,"m":1,'
        '"st":"pending","t":$old,"f":{"title":"旧结果"}}]}');

    final MatchQueue q = MatchQueue.open(dir, 'old');
    expect(q.take('z.mp3', 1, 1), isNull);
    expect(q.countPending(), 0);

    // 没过期但字段为空的中间态同样丢弃（留着只会白跑一次 take）
    final int now = DateTime.now().millisecondsSinceEpoch;
    File('${dir.path}/queue-empty.json').writeAsStringSync(
        '{"version":1,"kind":"empty","items":[{"k":"y.mp3","s":1,"m":1,'
        '"st":"pending","t":$now,"f":{}}]}');
    expect(MatchQueue.open(dir, 'empty').countPending(), 0);
  });

  test('超过上限：先淘汰已收尾的，再淘汰最旧的', () {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final StringBuffer sb = StringBuffer('{"version":1,"kind":"limit","items":[');
    for (int i = 0; i < 6100; i++) {
      if (i > 0) sb.write(',');
      // 最旧的 50 条是已收尾的，其余都是 pending
      final String st = i < 50 ? MatchQueue.written : MatchQueue.pending;
      sb.write('{"k":"k$i","s":1,"m":1,"st":"$st","t":$now,"f":{"title":"t"}}');
    }
    sb.write(']}');
    File('${dir.path}/queue-limit.json').writeAsStringSync(sb.toString());

    final MatchQueue q = MatchQueue.open(dir, 'limit');
    expect(q.countOf(MatchQueue.written), 50);
    q.put('new.mp3', 9, 9, fields());

    expect(q.countOf(MatchQueue.written), 0, reason: '先淘汰已收尾的');
    expect(q.countPending(), MatchQueue.maxEntries);
    expect(q.take('k50', 1, 1), isNull, reason: '最旧的 pending 接着被淘汰');
    expect(q.take('k101', 1, 1), isNotNull);
    expect(q.take('new.mp3', 9, 9), isNotNull, reason: '新条目不会被自己挤掉');
  });

  test('clearFinished 只清已完成的', () {
    final MatchQueue q = MatchQueue.open(dir, 'fin');
    q.put('p1', 1, 1, fields());
    q.put('p2', 1, 1, fields());
    q.put('p3', 1, 1, fields());
    q.mark('p1', MatchQueue.written);
    q.mark('p2', MatchQueue.skipped);
    q.clearFinished();

    expect(q.countPending(), 1);
    expect(q.pendingKeys(), <String>['p3']);
    expect(q.pendingItems().single.field('title', ''), '示例标题');
    expect(q.summary().contains('待写入'), isTrue);

    q.clear();
    expect(q.countPending(), 0);
    expect(q.summary().contains('无待写入'), isTrue);
  });

  test('BatchMemory 记忆命中与过期（指纹变了就作废）', () {
    final BatchMemory mem = BatchMemory.open(dir, 'm1');
    expect(mem.shouldSkip('a.mp3', 100, 1000), isFalse);
    mem.record('a.mp3', 100, 1000, BatchMemory.noHit);
    expect(mem.shouldSkip('a.mp3', 100, 1000), isTrue);
    expect(mem.statusOf('a.mp3', 100, 1000), BatchMemory.noHit);
    expect(mem.skipCount(), 1);

    expect(mem.shouldSkip('a.mp3', 101, 1000), isFalse, reason: '大小变了要重查');
    expect(mem.shouldSkip('a.mp3', 100, 1001), isFalse, reason: '时间变了要重查');
    expect(mem.statusOf('a.mp3', 101, 1000), '');

    mem.markDone('b.mp3', 200, 2000);
    expect(mem.shouldSkip('b.mp3', 200, 2000), isTrue);
    mem.record('', 1, 1, BatchMemory.noHit);
    expect(mem.size(), 2, reason: '空键不记录');
    expect(mem.countOf(BatchMemory.done), 1);
    expect(mem.forget('b.mp3'), isTrue);
    expect(mem.shouldSkip('b.mp3', 200, 2000), isFalse);

    // 落盘后重开（模拟进程重启）结论还在
    expect(mem.save(), isTrue);
    final BatchMemory re = BatchMemory.open(dir, 'm1');
    expect(re.shouldSkip('a.mp3', 100, 1000), isTrue);
    expect(BatchMemory.open(dir, 'm2').size(), 0, reason: '不同 kind 互不干扰');
    expect(re.summary().contains('记忆 1 首'), isTrue);
  });

  test('JSON 损坏时降级为空队列，不抛异常', () {
    File('${dir.path}/queue-bad.json').writeAsStringSync('{ this is not json ');
    final MatchQueue q = MatchQueue.open(dir, 'bad');
    expect(q.countPending(), 0);
    q.put('a.mp3', 1, 1, fields());
    expect(q.countPending(), 1, reason: '坏文件之后仍能记录');

    File('${dir.path}/broken.json').writeAsStringSync('{ this is not json ');
    final BatchMemory mem = BatchMemory.open(dir, 'broken');
    expect(mem.size(), 0);
    mem.record('a.mp3', 1, 1, BatchMemory.noHit);
    expect(mem.shouldSkip('a.mp3', 1, 1), isTrue);

    // 空键被忽略；文件不存在 / 空文件同样当作没有续跑
    q.put('', 1, 1, fields());
    expect(q.countPending(), 1);
    expect(MatchQueue.open(dir, 'none').countPending(), 0);
    expect(BatchMemory.open(dir, 'none').size(), 0);
  });
}
