/// 更新检查：国内优先（清单 → 接口），失败自动退到下一个来源。
///
/// 四个来源依次尝试：Gitee 清单 → Gitee 接口 → GitHub 清单 → GitHub 接口。
/// 界面里的「检查更新」与启动时的静默检查共用这一份逻辑。
library;

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

  /// 查到的最新版本；四个来源全失败时为 null。
  final Release? release;

  /// 命中的来源名（清单 / 接口）。
  final String source;

  /// 各来源的失败原因（给界面显示）。
  final List<String> failures;
}

/// 更新检查（纯网络，不碰设置）。
abstract final class UpdateCheck {
  /// 依次尝试四个来源；全失败返回 release 为 null 的结果。
  static Future<UpdateOutcome> fetch({
    void Function(String step)? onStep,
  }) async {
    final List<String> failures = <String>[];
    String source = '';

    Future<Release?> manifest(String label, String url, int timeout) async {
      if (url.isEmpty) {
        failures.add('$label：没有登记地址');
        return null;
      }
      onStep?.call('正在读取$label…');
      final String? text = await Http.getText(url, null, null, timeout);
      if (text == null) {
        final String why = Http.lastError.isEmpty ? '无响应' : Http.lastError;
        failures.add('$label：无法访问或超时（$why）');
        return null;
      }
      final Release? r = AppUpdate.parseManifest(text, url);
      if (r == null) {
        failures.add('$label：返回内容不是有效的版本清单');
        return null;
      }
      source = label;
      return r;
    }

    Future<Release?> api(String label, String url) async {
      if (url.isEmpty) {
        failures.add('$label：没有登记地址');
        return null;
      }
      onStep?.call('正在读取$label…');
      final Object? json = await Http.getJson(
        url,
        null,
        <String, String>{'Accept': 'application/vnd.github+json'},
        Http.readTimeoutOverseasMs,
      );
      if (json == null) {
        final String why = Http.lastError.isEmpty ? '无响应' : Http.lastError;
        failures.add('$label：无法访问、超时或返回为空（$why）');
        return null;
      }
      final Release? r = AppUpdate.parseRelease(json);
      if (r == null) {
        failures.add('$label：响应里没有 tag_name（可能被限流）');
        return null;
      }
      source = label;
      return r;
    }

    Release? r = await manifest(
        'Gitee 版本清单', Endpoints.urlOf('gitee', 0), Http.readTimeoutCnMs);
    r ??= await api('Gitee Release 接口', Endpoints.urlOf('gitee', 3));
    r ??= await manifest(
        'GitHub 版本清单', Endpoints.urlOf('update', 3), Http.readTimeoutOverseasMs);
    r ??= await api('GitHub Release 接口', Endpoints.urlOf('update', 0));
    if (r == null) {
      failures.add('四个来源都没拿到版本信息');
    }
    return UpdateOutcome(release: r, source: source, failures: failures);
  }
}
