/// 设置存储（Phase 0 纯 Dart 内存实现，零 Flutter 依赖）。
///
/// 后续落位：
/// - SharedPreferences 持久化后端（`shared_preferences` 在白名单内）；
/// - 类型化访问器：主题 id / 夜间模式 / 端点覆盖 / 文件级并发度 /
///   补全策略（disabled / supplement / overwrite）等；
/// - `settings_backup.dart`：设置导入导出。
class SettingsStore {
  final Map<String, Object?> _values = <String, Object?>{};

  /// 读取；键不存在或类型不匹配时返回 [fallback]。
  T? get<T>(String key, {T? fallback}) {
    final Object? value = _values[key];
    if (value is T) return value;
    return fallback;
  }

  /// 写入。
  void set(String key, Object? value) => _values[key] = value;

  /// 移除键。
  void remove(String key) => _values.remove(key);

  /// 是否包含键。
  bool containsKey(String key) => _values.containsKey(key);

  /// 当前全部键（调试 / 备份用）。
  Iterable<String> get keys => _values.keys;
}
