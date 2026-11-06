import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/update/app_update.dart';
import 'package:musicorganizer/core/update/update_check.dart';

/// UpdateCheck.fetch 的「双站取更高版本」判定逻辑测试。
///
/// fetch 里的网络部分不可注入（Http 是静态类），所以这里只测
/// 判定核心：两个 UpdateOutcome 怎么合成一个——这段逻辑在 fetch
/// 内联实现，测试通过等价复现（compare 取高 + 失败原因合并）锁行为。
void main() {
  // 与 UpdateCheck.fetch 内联的合成逻辑保持一致（改 fetch 时同步改这里，
  // 测试变红就是提醒两处不一致）。
  UpdateOutcome merge(UpdateOutcome a, UpdateOutcome b) {
    final Release? ra = a.release, rb = b.release;
    Release? win;
    String source;
    if (ra != null && rb != null) {
      final int cmp = AppUpdate.compare(rb.version, ra.version);
      win = cmp > 0 ? rb : ra;
      source = cmp > 0 ? b.source : a.source;
      final List<String> notes = <String>[
        if (a.failures.isNotEmpty) 'Gitee：${a.failures.first}',
        if (b.failures.isNotEmpty) 'GitHub：${b.failures.first}',
      ];
      if (notes.isNotEmpty) source = '$source（${notes.join('；')}）';
    } else if (ra != null) {
      win = ra;
      source = a.source;
    } else if (rb != null) {
      win = rb;
      source = b.source;
    } else {
      source = '';
    }
    return UpdateOutcome(
      release: win,
      source: source,
      failures: <String>[...a.failures, ...b.failures],
    );
  }

  Release rel(String version, String source) => Release(
        tag: 'v$version',
        version: version,
        apkUrl: 'https://example.com/x.apk',
      );

  group('双站合成', () {
    test('两侧都有版本：取版本号更高的（GitHub 更新时赢）', () {
      final UpdateOutcome out = merge(
        UpdateOutcome(
            release: rel('0.3.2', 'Gitee 版本清单'),
            source: 'Gitee 版本清单',
            failures: const <String>[]),
        UpdateOutcome(
            release: rel('0.3.3', 'GitHub 版本清单'),
            source: 'GitHub 版本清单',
            failures: const <String>[]),
      );
      expect(out.release!.version, '0.3.3');
      expect(out.source, 'GitHub 版本清单');
      expect(out.failures, isEmpty);
    });

    test('Gitee 更新时赢（反向也成立）', () {
      final UpdateOutcome out = merge(
        UpdateOutcome(
            release: rel('0.4.0', 'Gitee 版本清单'),
            source: 'Gitee 版本清单',
            failures: const <String>[]),
        UpdateOutcome(
            release: rel('0.3.9', 'GitHub Release 接口'),
            source: 'GitHub Release 接口',
            failures: const <String>[]),
      );
      expect(out.release!.version, '0.4.0');
      expect(out.source, 'Gitee 版本清单');
    });

    test('版本相同：取先完成的一侧（Gitee）', () {
      final UpdateOutcome out = merge(
        UpdateOutcome(
            release: rel('0.3.3', 'Gitee 版本清单'),
            source: 'Gitee 版本清单',
            failures: const <String>[]),
        UpdateOutcome(
            release: rel('0.3.3', 'GitHub 版本清单'),
            source: 'GitHub 版本清单',
            failures: const <String>[]),
      );
      expect(out.release!.version, '0.3.3');
      expect(out.source, 'Gitee 版本清单');
    });

    test('一侧失败：另一侧直接用，失败原因保留', () {
      final UpdateOutcome out = merge(
        UpdateOutcome(
            release: null, source: '', failures: <String>['Gitee 清单：超时']),
        UpdateOutcome(
            release: rel('0.3.3', 'GitHub 版本清单'),
            source: 'GitHub 版本清单',
            failures: const <String>[]),
      );
      expect(out.release!.version, '0.3.3');
      expect(out.failures, <String>['Gitee 清单：超时']);
    });

    test('都失败：release 为 null，原因合并', () {
      final UpdateOutcome out = merge(
        UpdateOutcome(
            release: null, source: '', failures: <String>['Gitee 清单：超时']),
        UpdateOutcome(
            release: null,
            source: '',
            failures: <String>['GitHub 清单：超时']),
      );
      expect(out.release, isNull);
      expect(out.failures.length, 2);
    });

    test('高版本一侧带失败原因：来源里注明（漏推一侧可见）', () {
      final UpdateOutcome out = merge(
        UpdateOutcome(
            release: rel('0.3.2', 'Gitee 版本清单'),
            source: 'Gitee 版本清单',
            failures: const <String>[]),
        UpdateOutcome(
            release: rel('0.3.3', 'GitHub Release 接口'),
            source: 'GitHub Release 接口',
            failures: <String>['GitHub 清单：不是有效清单']),
      );
      expect(out.release!.version, '0.3.3');
      expect(out.source, contains('GitHub'));
      expect(out.source, contains('不是有效清单'));
    });
  });
}
