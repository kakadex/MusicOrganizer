/// 并发闸门与有界缓存（T-10 的底座）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/concurrency.dart';

void main() {
  group('ConcurrencyGate', () {
    test('同时执行数不超过上限，全部任务仍然都跑到', () async {
      final ConcurrencyGate gate = ConcurrencyGate(2);
      int active = 0;
      int peak = 0;
      final List<Future<int>> jobs = <Future<int>>[
        for (int i = 0; i < 6; i++)
          gate.run(() async {
            active++;
            if (active > peak) peak = active;
            await Future<void>.delayed(const Duration(milliseconds: 5));
            active--;
            return i;
          }),
      ];
      expect(await Future.wait(jobs), <int>[0, 1, 2, 3, 4, 5]);
      expect(peak, 2);
      expect(gate.active, 0);
      expect(gate.waiting, 0);
    });

    test('任务抛异常也释放名额', () async {
      final ConcurrencyGate gate = ConcurrencyGate(1);
      await expectLater(
          gate.run<void>(() async => throw StateError('boom')), throwsStateError);
      expect(gate.active, 0);
      // 名额确实回来了：再进一个不会被卡住
      expect(await gate.run<int>(() async => 7), 7);
    });
  });

  group('BoundedMap', () {
    test('超过条目数淘汰最早插入的', () {
      final BoundedMap<String, int> m = BoundedMap<String, int>(
          maxEntries: 3, maxBytes: 1 << 20, sizeOf: (int _) => 1);
      for (final String k in <String>['a', 'b', 'c', 'd']) {
        m.put(k, 1);
      }
      expect(m['a'], isNull);
      expect(m['b'], 1);
      expect(m.length, 3);
    });

    test('超过字节上限继续淘汰，占用不会失控', () {
      final BoundedMap<String, String> m = BoundedMap<String, String>(
        maxEntries: 100,
        maxBytes: 100,
        sizeOf: (String v) => v.length,
      );
      for (int i = 0; i < 30; i++) {
        m.put('k$i', 'x' * 10);
      }
      expect(m.bytes, lessThanOrEqualTo(100));
      expect(m.length, 10);
    });

    test('removeWhere 同步扣减字节计数', () {
      final BoundedMap<String, String> m = BoundedMap<String, String>(
        maxEntries: 10,
        maxBytes: 1000,
        sizeOf: (String v) => v.length,
      );
      m.put('a.mp3', 'x' * 10);
      m.put('b.mp3', 'y' * 20);
      expect(m.bytes, 30);
      m.removeWhere((String k, String _) => k.startsWith('a'));
      expect(m.bytes, 20);
      expect(m['a.mp3'], isNull);
    });
  });
}
