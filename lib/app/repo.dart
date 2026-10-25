import '../core/settings/settings.dart';

/// 全局仓库（Phase 0 骨架）：集中持有跨 feature 的单例槽位。
///
/// 槽位规划（按任务表落位，当前均为注释占位）：
/// - `FileStore? fileStore` —— T03/T08 文件系统抽象（SAF / dart:io 双实现）；
/// - `Endpoints? endpoints` —— T10 数据源注册表；
/// - `TaskCenter? taskCenter` —— T11 任务引擎；
/// - [settings] —— core/settings 设置存储（当前为纯 Dart 内存实现）。
class Repo {
  Repo._();

  /// 进程内全局单例。
  static final Repo instance = Repo._();

  final SettingsStore _settings = SettingsStore();
  bool _initialized = false;

  /// 是否已完成初始化。
  bool get isInitialized => _initialized;

  /// 设置存储槽位。
  SettingsStore get settings => _settings;

  /// 初始化仓库；幂等。持久化组件（SharedPreferences 等）在此接入。
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
  }
}
