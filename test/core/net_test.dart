import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/model/task_control.dart';
import 'package:musicorganizer/core/net/http_client.dart';
import 'package:musicorganizer/core/net/net.dart';
import 'package:musicorganizer/core/net/net_tuning.dart';
import 'package:musicorganizer/core/net/ticket_limiter.dart';
import 'package:musicorganizer/core/settings/settings_backup.dart';

void main() {
  group('Net.map', () {
    test('结果顺序与输入一致', () async {
      final List<int> items = List<int>.generate(12, (int i) => i);
      final List<int?> out = await Net.map<int, int>(items, 4, null, (int item) async {
        await Future<void>.delayed(Duration(milliseconds: (12 - item) * 8));
        return item * 2;
      });
      expect(out.length, items.length);
      for (int i = 0; i < out.length; i++) {
        expect(out[i], i * 2);
      }
    });

    test('确实并发', () async {
      final List<int> items = List<int>.generate(10, (int i) => i);
      final Stopwatch sw = Stopwatch()..start();
      await Net.map<int, int>(items, 5, null, (int item) async {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        return item;
      });
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(1000));
    });

    test('已取消则不开工', () async {
      final TaskControl tc = TaskControl()..cancel();
      int ran = 0;
      final List<int> items = List<int>.generate(6, (int i) => i);
      final List<int?> out = await Net.map<int, int>(items, 3, tc, (int item) async {
        ran++;
        return item;
      });
      expect(ran, 0);
      expect(out.every((int? v) => v == null), isTrue);
      expect(out.length, items.length);
    });

    test('全部完成不丢结果', () async {
      final List<int> items = List<int>.generate(12, (int i) => i);
      final List<int?> out =
          await Net.mapIndexed<int, int>(items, 3, null, (int i, int item) async {
        await Future<void>.delayed(const Duration(milliseconds: 60));
        return item * 3;
      });
      int nonNull = 0;
      bool ordered = true;
      for (int i = 0; i < out.length; i++) {
        if (out[i] == null) {
          ordered = false;
        } else {
          nonNull++;
          if (out[i] != i * 3) ordered = false;
        }
      }
      expect(nonNull, 12);
      expect(ordered, isTrue);
    });

    test('取消后及时收工', () async {
      final TaskControl tc = TaskControl();
      final List<int> items = List<int>.generate(40, (int i) => i);
      int ran = 0;
      final Stopwatch sw = Stopwatch()..start();
      await Net.mapIndexed<int, int>(items, 3, tc, (int i, int item) async {
        ran++;
        tc.cancel();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return item;
      });
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(1500));
      expect(ran, lessThan(40));
    });
  });

  group('Net.gather', () {
    test('总预算生效', () async {
      final List<Future<String> Function()> tasks = <Future<String> Function()>[
        () async {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          return 'fast';
        },
        () async {
          await Future<void>.delayed(const Duration(milliseconds: 3000));
          return 'slow-1';
        },
        () async {
          await Future<void>.delayed(const Duration(milliseconds: 3000));
          return 'slow-2';
        },
      ];
      final Stopwatch sw = Stopwatch()..start();
      final List<String> out = await Net.gather<String>(tasks, 400, null);
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(1500));
      expect(out, contains('fast'));
      expect(out.length, lessThan(3));
    });

    test('单任务异常不影响其它结果', () async {
      final List<Future<String> Function()> tasks = <Future<String> Function()>[
        () async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return 'ok-1';
        },
        () async => throw StateError('模拟源故障'),
        () async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return 'ok-2';
        },
      ];
      final List<String> out = await Net.gather<String>(tasks, 3000, null);
      expect(out, containsAll(<String>['ok-1', 'ok-2']));
    });
  });

  group('NetTuning', () {
    test('取值区间与越界收缩', () {
      NetTuning.apply(3, 100);
      expect(NetTuning.fileConcurrency(), 3);
      expect(NetTuning.timeoutPercent(), 100);
      NetTuning.apply(0, 100);
      expect(NetTuning.fileConcurrency(), 1);
      NetTuning.apply(99, 100);
      expect(NetTuning.fileConcurrency(), 5);
      NetTuning.apply(-7, 100);
      expect(NetTuning.fileConcurrency(), 1);
      NetTuning.apply(3, 0);
      expect(NetTuning.timeoutPercent(), 50);
      NetTuning.apply(3, 9999);
      expect(NetTuning.timeoutPercent(), 300);
      NetTuning.apply(3, 100);
      expect(NetTuning.fileConcurrency(), 3);
      expect(NetTuning.timeoutPercent(), 100);
    });

    test('超时缩放', () {
      NetTuning.apply(3, 100);
      expect(NetTuning.scale(12000), 12000);
      expect(NetTuning.scale(3500), 3500);
      NetTuning.apply(3, 200);
      expect(NetTuning.scale(12000), 24000);
      NetTuning.apply(3, 50);
      expect(NetTuning.scale(12000), 6000);
      expect(NetTuning.scale(200), 300);
      NetTuning.apply(3, 300);
      expect(NetTuning.scale(1000), 3000);
      expect(NetTuning.scale(9000), 27000);
      NetTuning.apply(3, 100);
    });

    test('单源预算联动', () {
      NetTuning.apply(3, 100);
      expect(Net.sourceBudget(), Net.sourceBudgetMs);
      NetTuning.apply(3, 200);
      expect(Net.sourceBudget(), (Net.sourceBudgetMs * 2.0).round());
      NetTuning.apply(3, 50);
      expect(Net.sourceBudget(), (Net.sourceBudgetMs * 0.5).round());
      expect(Net.fileConcurrency(), NetTuning.fileConcurrency());
      NetTuning.apply(3, 100);
    });

    test('与设置备份接线', () {
      expect(SettingsBackup.defaults()['net_files'], NetTuning.defaultFileConcurrency);
      expect(SettingsBackup.defaults()['net_timeout'], NetTuning.defaultTimeoutPercent);
      expect(SettingsBackup.isKnownKey('net_files'), isTrue);
      expect(SettingsBackup.isKnownKey('net_timeout'), isTrue);

      final List<String> warns = <String>[];
      expect(SettingsBackup.sanitize('net_files', 9, warns), 5);
      expect(warns, isNotEmpty);

      warns.clear();
      expect(SettingsBackup.sanitize('net_timeout', 10, warns), 50);
      warns.clear();
      expect(SettingsBackup.sanitize('net_timeout', 150, warns), 150);
    });

    test('档位文案', () {
      expect(NetTuning.timeoutLabel(200), '2×');
      expect(NetTuning.timeoutLabel(150), '1.5×');
      NetTuning.apply(1, 100);
      expect(NetTuning.describe().contains('逐首'), isTrue);
      NetTuning.apply(5, 200);
      expect(NetTuning.describe().contains('激进'), isTrue);
      expect(NetTuning.describe().contains('2×'), isTrue);
      NetTuning.apply(3, 100);
      expect(NetTuning.describe().contains('推荐'), isTrue);
    });
  });

  group('Http', () {
    test('buildUrl 查询串', () {
      expect(Http.buildUrl('https://a.com/x', null), 'https://a.com/x');
      expect(Http.buildUrl('https://a.com/x', <String, String>{'a': '1', 'b': '2'}),
          'https://a.com/x?a=1&b=2');
      expect(Http.buildUrl('https://a.com/x?k=v', <String, String>{'a': '1'}),
          'https://a.com/x?k=v&a=1');
    });

    test('熔断：连续失败两次后冷却', () {
      final HostBreaker b = HostBreaker();
      expect(b.isCoolingDown('example.com'), isFalse);
      b.noteFail('example.com', 'timeout');
      expect(b.isCoolingDown('example.com'), isFalse);
      b.noteFail('example.com', 'timeout');
      expect(b.isCoolingDown('example.com'), isTrue);
      expect(b.cooldownSecondsLeft('example.com'), greaterThan(0));
      b.noteOk('example.com');
      expect(b.isCoolingDown('example.com'), isFalse);
    });

    test('熔断：限流冷却更久', () {
      final HostBreaker b = HostBreaker();
      b.noteFail('example.com', 'HTTP 429', cooldown: HostBreaker.rateLimitCooldownMs);
      b.noteFail('example.com', 'HTTP 429', cooldown: HostBreaker.rateLimitCooldownMs);
      expect(b.isCoolingDown('example.com'), isTrue);
    });
  });

  group('TicketLimiter', () {
    test('预约间隔', () {
      final TicketLimiter limiter =
          TicketLimiter(interval: const Duration(milliseconds: 100));
      final Duration w1 = limiter.reserve();
      final Duration w2 = limiter.reserve();
      expect(w1, Duration.zero);
      expect(w2, greaterThan(Duration.zero));
    });

    test('acquire 可等待', () async {
      final TicketLimiter limiter =
          TicketLimiter(interval: const Duration(milliseconds: 5));
      await limiter.acquire();
      await limiter.acquire();
    });
  });
}
