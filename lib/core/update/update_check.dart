/// 更新检查：双站并行查询，取版本号更高的那个（0.3.4 起改为竞速式比对）。
///
/// 为什么不「谁先成功用谁」：两个站内容应一致，但发版漏推一侧时（真实发生：
/// Gitee 忘推导致检查更新停在旧版），先成功的站会掩盖另一侧的新版本。
/// 所以两边各查一轮（清单 → 接口），各自拿到版本后比一比，新的说了算。
/// 界面里的「检查更新」与启动时的静默检查共用这一份逻辑。
library;

import 'dart:async';

import '../model/../net/http_client.dart';
import '../source/endpoints.dart';
import 'app_update.dart';

/// 检查结果（版本信息 + 过程说明）。
class UpdateOutcome {
  UpdateOutcome({
    required this.release,
    required this.source,
    required this.failures,
  });

  /// 查到的最新版本；所有来源全失败时为 null。
  final Release? release;

  /// 命中的来源名（清单 / 接口；取较高版本时标注两侧来源）。
  final String source;

  /// 各来源的失败原因（给界面显示）。
  final List<String> failures;
}

/// 更新检查（纯网络，不碰设置）。
abstract final class UpdateCheck {
  /// Gitee 与 GitHub 各查一轮（清单 → 接口），并行发出；任何一侧拿到版本
  /// 都作数，两侧都有时取版本号更高的那个（相同取先完成的一侧）。
  static Future<UpdateOutcome> fetch({
    void Function(String step)? onStep,
  }) async {
    final Future<UpdateOutcome> cn = _fetchOne(
      'Gitee',
      manifestUrl: Endpoints.urlOf('gitee', 0),
      manifestTimeout: Http.readTimeoutCnMs,
      apiUrl: Endpoints.urlOf('gitee', 3),
      onStep: onStep,
    );
    final Future<UpdateOutcome> gh = _fetchOne(
      'GitHub',
      manifestUrl: Endpoints.urlOf('update', 3),
      manifestTimeout: Http.readTimeoutOverseasMs,
      apiUrl: Endpoints.urlOf('update', 0),
      onStep: onStep,
    );
    final List<UpdateOutcome> both =
        await Future.wait(<Future<UpdateOutcome>>[cn, gh]);
    final UpdateOutcome a = both[0], b = both[1];

    // 两侧都有版本：版本号高的赢；相同取先完成的一侧（Gitee 在前）。
    // 一侧失败：另一侧直接用，失败原因照记（界面能看到哪边没查到）。
    final Release? ra = a.release, rb = b.release;
    Release? win;
    String source;
    if (ra != null && rb != null) {
      final int cmp = AppUpdate.compare(rb.version, ra.version);
      win = cmp > 0 ? rb : ra;
      source = cmp > 0 ? b.source : a.source;
      // 任一侧有失败原因都标出来：典型场景是「一边忘了更新清单」，用户能
      // 在来源里直接看到哪边不对劲，而不是只看到干巴巴的来源名。
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
    final List<String> failures = <String>[...a.failures, ...b.failures];
    if (win == null) {
      failures.add('所有来源都没拿到版本信息');
    }
    return UpdateOutcome(
        release: win, source: source, failures: failures);
  }

  /// 查一个站：清单 → 接口，失败自动退到接口。
  static Future<UpdateOutcome> _fetchOne(
    String label, {
    required String manifestUrl,
    required int manifestTimeout,
    required String apiUrl,
    void Function(String step)? onStep,
  }) async {
    final List<String> failures = <String>[];
    String source = '';

    Future<Release?> manifest(String url, int timeout) async {
      if (url.isEmpty) {
        failures.add('$label 清单：没有登记地址');
        return null;
      }
      onStep?.call('正在读取$label版本清单…');
      // ignoreBreaker：检查更新是用户手动触发的低频动作，被屏蔽的 host
      // （典型：hosts 屏蔽了 GitHub 全家）失败两次就冷却 45 秒，用户立刻
      // 点「重试」会白等——这里永远真发请求（0.3.8）。
      final String? text =
          await Http.getText(url, null, null, timeout, ignoreBreaker: true);
      if (text == null) {
        final String why = Http.lastError.isEmpty ? '无响应' : Http.lastError;
        failures.add('$label 清单：无法访问或超时（$why）');
        return null;
      }
      final Release? r = AppUpdate.parseManifest(text, url);
      if (r == null) {
        failures.add('$label 清单：返回内容不是有效的版本清单');
        return null;
      }
      source = '$label 版本清单';
      return r;
    }

    Future<Release?> api(String url) async {
      if (url.isEmpty) {
        failures.add('$label 接口：没有登记地址');
        return null;
      }
      onStep?.call('正在读取$label Release 接口…');
      final Object? json = await Http.getJson(
        url,
        null,
        <String, String>{'Accept': 'application/vnd.github+json'},
        Http.readTimeoutOverseasMs,
        ignoreBreaker: true,
      );
      if (json == null) {
        final String why = Http.lastError.isEmpty ? '无响应' : Http.lastError;
        failures.add('$label 接口：无法访问、超时或返回为空（$why）');
        return null;
      }
      final Release? r = AppUpdate.parseRelease(json);
      if (r == null) {
        failures.add('$label 接口：响应里没有 tag_name（可能被限流）');
        return null;
      }
      source = '$label Release 接口';
      return r;
    }

    Release? r = await manifest(manifestUrl, manifestTimeout);
    r ??= await api(apiUrl);
    return UpdateOutcome(
        release: r, source: source, failures: failures);
  }
}
