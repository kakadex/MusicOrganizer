/// 启动时的静默更新检查：每天最多一次，可在设置里关掉。
///
/// 与界面里的「检查更新」共用 [UpdateCheck]；这里只是把「什么时候问、问完怎么提示」
/// 定下来：查到新版本就在底栏提示一句，不打断正在做的事。
library;

import '../core/task/task_center.dart';
import '../core/update/app_update.dart';
import '../core/update/update_check.dart';
import '../core/version.dart';
import 'repo.dart';

/// 静默检查。
abstract final class SilentUpdate {
  /// 最短间隔（24 小时）。
  static const int intervalMs = 24 * 3600 * 1000;

  /// 设置项名。
  static const String enabledKey = 'update_silent';
  static const String lastCheckKey = 'update_last_check';

  /// 到点了就查一次；查到新版本返回它，否则返回 null。
  ///
  /// 「查不到」「没网」「已是最新」都算正常，不打扰用户。
  static Future<Release?> checkIfDue() async {
    final Repo repo = Repo.instance;
    final bool enabled =
        repo.settings.get<bool>(enabledKey, fallback: true) ?? true;
    if (!enabled) return null;
    final int now = DateTime.now().millisecondsSinceEpoch;
    final int last = repo.settings.get<int>(lastCheckKey, fallback: 0) ?? 0;
    if (now - last < intervalMs) return null;
    // 先记时间：即使这次没网，也不至于每次启动都去试
    await repo.setSetting(lastCheckKey, now);
    if (TaskCenter.isBusy()) return null;
    try {
      final UpdateOutcome out = await UpdateCheck.fetch();
      final Release? r = out.release;
      if (r == null) return null;
      if (!AppUpdate.isNewer(kAppVersionFull, r.version)) return null;
      return r;
    } catch (_) {
      return null;
    }
  }
}
