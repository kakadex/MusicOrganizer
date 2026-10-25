/// 设置备份 / 恢复 —— 移植自旧 core/SettingsBackup.java。
///
/// 三条设计原则（继承旧版）：
/// 1. 白名单：只导出认识键；设备相关键（tree_uri / notif_asked 等）必须排除；
/// 2. 逐项容错：越界数字 clamp、失效地址丢弃、陌生键记 warnings/ignored；
/// 3. 纯 Dart：零 Flutter 依赖，可离线回归。
library;

import '../json/json.dart';
import '../match/name_weight.dart';
import '../match/tag_fill.dart';
import '../net/net_tuning.dart';
import '../source/endpoints.dart';

/// 键的类别（决定校验方式与写回类型）。
enum SettingsKind { boolKey, intKey, stringKey, fieldMode, endpointUrl, sourceOn }

/// 导入结果：values 可直接逐项写回；warnings/ignored 用来告诉用户「哪些没生效」。
class SettingsImport {
  bool ok = false;
  String? error;
  int version = 1;

  /// 校验通过、可以直接写回的设置（bool / int / String）。
  final Map<String, Object> values = <String, Object>{};

  /// 不认识的键（多半来自别的版本或手工加的）。
  final List<String> ignored = <String>[];

  /// 被修正或丢弃的项说明。
  final List<String> warnings = <String>[];

  int get count => values.length;

  /// 一句话摘要（导入确认框里用）。
  String summary() {
    if (!ok) return error ?? '无法读取';
    int ep = 0;
    int on = 0;
    int fp = 0;
    int other = 0;
    for (final String key in values.keys) {
      final SettingsKind k = SettingsBackup.kindOf(key)!;
      if (k == SettingsKind.endpointUrl) {
        ep++;
      } else if (k == SettingsKind.sourceOn) {
        on++;
      } else if (k == SettingsKind.fieldMode) {
        fp++;
      } else {
        other++;
      }
    }
    final StringBuffer sb = StringBuffer();
    sb.write('可用设置 ${values.length} 项：常规 $other，接口地址 $ep，'
        '数据源开关 $on，字段策略 $fp');
    if (warnings.isNotEmpty) {
      sb.write('\n\n已修正 / 丢弃 ${warnings.length} 项：');
      _appendLimited(sb, warnings, 8);
    }
    if (ignored.isNotEmpty) {
      sb.write('\n\n忽略不认识的键 ${ignored.length} 个：');
      _appendLimited(sb, ignored, 8);
    }
    return sb.toString();
  }

  static void _appendLimited(StringBuffer sb, List<String> items, int max) {
    for (int i = 0; i < items.length && i < max; i++) {
      sb.write('\n· ${items[i]}');
    }
    if (items.length > max) {
      sb.write('\n· …还有 ${items.length - max} 项');
    }
  }
}

/// 设置备份 / 恢复（纯 Dart）。
abstract final class SettingsBackup {
  /// 备份文件里的应用标识，用来挡住「导入别人的 JSON」。
  static const String appTag = 'MusicOrganizer';

  /// 备份格式版本；结构变了就 +1，导入时向下兼容。
  static const int version = 1;

  /// 常规布尔开关。
  static const List<String> boolKeys = <String>[
    'recursive', 'skip_artist', 'fast', 'net', 'cn', 'dry',
    'lrc_overwrite', 'lrc_plain', 'lrc_embed', 'lyrics_simplify', 'tag_overwrite',
    'update_auto', 'theme_dark', 'move_unrec',
  ];

  static const String keyLayout = 'layout_id';
  static const String keyWeight = 'fn_weight';
  static const String keyThemeId = 'theme_id';
  static const String keyNetFiles = 'net_files';
  static const String keyNetTimeout = 'net_timeout';
  static const String keyProxyMode = 'proxy_mode';
  static const String keyProxyHost = 'proxy_host';
  static const String keyProxyPort = 'proxy_port';

  static const String prefixEndpoint = 'ep:';
  static const String prefixSourceOn = 'ep_on:';
  static const String prefixFieldMode = 'fp:';

  // 等价旧 Theme.NAMES.length（主题枚举在 app/theme 层，core 不依赖 UI）。
  static const int _themeCount = 3;

  /// 判断一个偏好键属于哪类；返回 null 表示「不是可备份的设置」。
  static SettingsKind? kindOf(String? key) {
    if (key == null || key.isEmpty) return null;
    for (final String k in boolKeys) {
      if (k == key) return SettingsKind.boolKey;
    }
    if (key == keyWeight ||
        key == keyThemeId ||
        key == keyLayout ||
        key == keyNetFiles ||
        key == keyNetTimeout ||
        key == keyProxyMode ||
        key == keyProxyPort) {
      return SettingsKind.intKey;
    }
    if (key == keyProxyHost) {
      return SettingsKind.stringKey;
    }
    if (key.startsWith(prefixFieldMode)) {
      final String field = key.substring(prefixFieldMode.length);
      return _isField(field) ? SettingsKind.fieldMode : null;
    }
    if (key.startsWith(prefixSourceOn)) {
      final String src = key.substring(prefixSourceOn.length);
      return Endpoints.find(src) != null ? SettingsKind.sourceOn : null;
    }
    if (key.startsWith(prefixEndpoint)) {
      final String ep = key.substring(prefixEndpoint.length);
      return Endpoints.isEndpointKey(ep) ? SettingsKind.endpointUrl : null;
    }
    return null;
  }

  /// 内置默认值（「恢复默认设置」与回归测试共用）。
  static Map<String, Object> defaults() {
    return <String, Object>{
      'recursive': true,
      'skip_artist': true,
      'fast': true,
      'net': true,
      'cn': true,
      'dry': false,
      'move_unrec': false,
      'lrc_overwrite': false,
      'lrc_plain': false,
      'lrc_embed': true,
      'lyrics_simplify': true,
      'tag_overwrite': false,
      'update_auto': true,
      'theme_dark': false,
      keyThemeId: 1,
      keyWeight: 20,
      keyLayout: 0,
      keyNetFiles: NetTuning.defaultFileConcurrency,
      keyNetTimeout: NetTuning.defaultTimeoutPercent,
    };
  }

  /// 与默认值不同的设置项（键名列表，排序后返回）。
  static List<String> diffFromDefaults(Map<String, Object?>? current) {
    final List<String> out = <String>[];
    if (current == null) return out;
    for (final MapEntry<String, Object> e in defaults().entries) {
      final Object? now = current[e.key];
      if (now == null) continue;
      if ('$now' != '${e.value}') out.add(e.key);
    }
    out.sort();
    return out;
  }

  /// 是否是可备份的键（导出时按它过滤）。
  static bool isKnownKey(String key) => kindOf(key) != null;

  static bool _isField(String field) => TagFill.candidateFields.contains(field);

  /// 把设置写成 JSON（排序输出，方便用户 diff 两份备份）。
  static String toJson(Map<String, Object?>? values, String? stamp) {
    final StringBuffer sb = StringBuffer();
    sb.write('{\n');
    sb.write('  "app": ${Json.quote(appTag)},\n');
    sb.write('  "version": $version,\n');
    sb.write('  "exportedAt": ${Json.quote(stamp ?? '')},\n');
    sb.write('  "settings": {');
    bool first = true;
    final List<String> keys = <String>[];
    if (values != null) {
      for (final String k in values.keys) {
        if (isKnownKey(k) && values[k] != null) keys.add(k);
      }
    }
    keys.sort();
    for (final String k in keys) {
      sb.write(first ? '\n' : ',\n');
      first = false;
      sb.write('    ${Json.quote(k)}: ${Json.value(values![k])}');
    }
    sb.write(first ? '}\n' : '\n  }\n');
    sb.write('}\n');
    return sb.toString();
  }

  /// 解析备份 JSON 并逐项校验。
  ///
  /// 兼容两种结构：标准格式（带 app/version/settings）与「扁平 map」
  /// （直接是键值对），后者方便用户手写一份最小备份。
  static SettingsImport fromJson(String? text) {
    final SettingsImport out = SettingsImport();
    if (text == null || text.trim().isEmpty) {
      out.error = '文件是空的';
      return out;
    }
    Object? root;
    try {
      root = Json.parse(text);
    } catch (e) {
      out.error = '不是合法的 JSON：$e';
      return out;
    }
    if (root is! Map) {
      out.error = '备份文件的顶层必须是 JSON 对象';
      return out;
    }
    final Map<String, Object?> top = root.cast<String, Object?>();
    final Object? app = top['app'];
    if (app != null && appTag != '$app') {
      out.error = '这不是「音乐整理」的设置备份（app=$app）';
      return out;
    }
    final Object? ver = top['version'];
    out.version = ver is num ? ver.toInt() : version;
    if (out.version > version) {
      out.warnings.add('备份来自更高版本（v${out.version}），部分项可能被忽略');
    }
    final Object? settings = top['settings'];
    Map<dynamic, dynamic>? map;
    if (settings is Map) {
      map = settings;
    } else if (settings == null) {
      map = top; // 扁平格式
    } else {
      out.error = 'settings 字段必须是对象';
      return out;
    }
    for (final MapEntry<dynamic, dynamic> e in map.entries) {
      final String key = '${e.key}';
      if (key == 'app' || key == 'version' || key == 'exportedAt' || key == 'settings') {
        continue; // 扁平格式里会撞到元数据
      }
      final SettingsKind? kind = kindOf(key);
      if (kind == null) {
        out.ignored.add(key);
        continue;
      }
      final Object? clean = sanitize(key, e.value, out.warnings);
      if (clean != null) out.values[key] = clean;
    }
    out.ok = true;
    return out;
  }

  /// 逐类校验单个值；返回 null 表示这一项丢弃。
  static Object? sanitize(String key, Object? raw, List<String> warnings) {
    final SettingsKind kind = kindOf(key)!;
    if (kind == SettingsKind.boolKey || kind == SettingsKind.sourceOn) {
      final bool? b = _asBool(raw);
      if (b == null) _warn(warnings, key, '不是布尔值，已丢弃');
      return b;
    }
    if (kind == SettingsKind.intKey) {
      final int? v = _asInt(raw);
      if (v == null) {
        _warn(warnings, key, '不是整数，已丢弃');
        return null;
      }
      int max = key == keyThemeId ? _themeCount - 1 : NameWeight.maxPercent;
      int min = 0;
      if (key == keyNetFiles) {
        min = NetTuning.minFileConcurrency;
        max = NetTuning.maxFileConcurrency;
      } else if (key == keyNetTimeout) {
        min = NetTuning.minTimeoutPercent;
        max = NetTuning.maxTimeoutPercent;
      } else if (key == keyProxyPort) {
        min = 0;
        max = 65535;
      } else if (key == keyProxyMode) {
        min = 0;
        max = 2;
      }
      if (v < min || v > max) {
        final int fixed = v < min ? min : (v > max ? max : v);
        _warn(warnings, key, '越界 $v → $fixed');
        return fixed;
      }
      return v;
    }
    if (kind == SettingsKind.stringKey) {
      final String v = '${raw ?? ''}'.trim();
      if (v.length > 120) {
        _warn(warnings, key, '内容过长，已丢弃');
        return null;
      }
      return v;
    }
    if (kind == SettingsKind.fieldMode) {
      final int? v = _asInt(raw);
      if (v == null) {
        _warn(warnings, key, '不是整数，已丢弃');
        return null;
      }
      if (v < TagFill.disabled || v > TagFill.overwrite) {
        final int fixed = v < TagFill.disabled
            ? TagFill.disabled
            : (v > TagFill.overwrite ? TagFill.overwrite : v);
        _warn(warnings, key, '取值 $v 不在 0~2，已修正为 $fixed');
        return fixed;
      }
      return v;
    }
    // endpointUrl
    final String? url = raw == null ? null : '$raw'.trim();
    if (!Endpoints.isValidUrl(url)) {
      _warn(warnings, key, '不是 http/https 地址，已丢弃');
      return null;
    }
    return url;
  }

  static void _warn(List<String> warnings, String key, String why) {
    warnings.add('$key：$why');
  }

  static bool? _asBool(Object? raw) {
    if (raw is bool) return raw;
    if (raw is num) return raw.toInt() != 0;
    if (raw != null) {
      final String s = '$raw'.trim();
      if (s.toLowerCase() == 'true' || s == '1') return true;
      if (s.toLowerCase() == 'false' || s == '0') return false;
    }
    return null;
  }

  static int? _asInt(Object? raw) {
    if (raw is num) return raw.round();
    if (raw != null) {
      final double? d = double.tryParse('$raw'.trim());
      if (d != null) return d.round();
    }
    return null;
  }
}
