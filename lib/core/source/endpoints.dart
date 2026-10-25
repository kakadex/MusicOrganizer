/// 接口地址注册表 —— 移植自旧 net/Endpoints.java。
///
/// 所有联网接口的地址都在这里登记，**不在业务代码里写死**：国内音乐站匿名接口
/// 换得勤，地址集中登记后用户可在「数据源设置」里自行改地址或关掉某个源。
/// 纯 Dart，无 Flutter 依赖（配置读写由上层实现 [EndpointsConfig] 后注入）。
library;

/// 一个数据源（可以有多个端点，例如「搜索」+「取详情」）。
class EndpointSource {
  const EndpointSource(
      this.key, this.label, this.group, this.names, this.defaults);

  /// 源标识，也是启用开关的键，如 netease。
  final String key;

  /// 界面上显示的名字。
  final String label;

  /// 分组：标签 / 歌词 / 更新。
  final String group;

  /// 各端点的短名，与 [defaults] 一一对应。
  final List<String> names;

  /// 各端点的默认地址。
  final List<String> defaults;

  int get count => defaults.length;

  /// 端点的完整键，如 `netease.0`。
  String endpointKey(int index) => '$key.$index';

  String name(int index) => index >= 0 && index < names.length ? names[index] : '';

  String defaultUrl(int index) =>
      index >= 0 && index < defaults.length ? defaults[index] : '';
}

/// 读写用户设置。由 UI 层实现（SharedPreferences），未注入时全部用默认值。
abstract class EndpointsConfig {
  /// 用户改过的地址；返回 null 或空串表示没改过。
  ///
  /// 注意：方法名避免用 `override`——它会遮蔽 Dart 内置的 `@override` 注解。
  String? overrideUrl(String endpointKey);

  /// 该源是否启用；默认 true。
  bool enabled(String sourceKey);

  /// 记下用户改的地址；传 null 表示恢复默认。
  void setOverride(String endpointKey, String? url);

  /// 设置源启用状态。
  void setEnabled(String sourceKey, bool enabled);
}

/// 接口地址注册表（纯 Dart）。
abstract final class Endpoints {
  static EndpointsConfig? _config;

  /// 注入配置实现。
  static void install(EndpointsConfig? c) => _config = c;

  /// 恢复到「没装任何配置」的状态（测试用）。
  static void uninstall() => _config = null;

  static EndpointsConfig? get config => _config;

  /// 注册表：新增数据源只要在这里加一行。
  static const List<EndpointSource> sources = <EndpointSource>[
    EndpointSource('netease', '网易云音乐', '标签', <String>['搜索'],
        <String>['https://music.163.com/api/search/get']),
    EndpointSource('qqmusic', 'QQ 音乐', '标签', <String>['搜索'],
        <String>['https://u.y.qq.com/cgi-bin/musicu.fcg']),
    EndpointSource('kugou', '酷狗音乐', '标签', <String>['搜索'],
        <String>['https://mobiles.kugou.com/api/v3/search/song']),
    EndpointSource('kuwo', '酷我音乐', '标签', <String>['搜索'],
        <String>['https://search.kuwo.cn/r.s']),
    EndpointSource('migu', '咪咕音乐', '标签', <String>['搜索'],
        <String>['https://app.c.nf.migu.cn/MIGUM2.0/v1.0/content/search_all.do']),
    EndpointSource('musicbrainz', 'MusicBrainz', '标签', <String>['搜索'],
        <String>['https://musicbrainz.org/ws/2/recording/']),
    EndpointSource('deezer', 'Deezer', '标签', <String>['搜索'],
        <String>['https://api.deezer.com/search']),
    EndpointSource('itunes', 'iTunes', '标签', <String>['搜索'],
        <String>['https://itunes.apple.com/search']),
    EndpointSource('lrclib', 'LRCLIB', '歌词', <String>['精确查询', '模糊搜索'],
        <String>['https://lrclib.net/api/get', 'https://lrclib.net/api/search']),
    EndpointSource('lyric_netease', '网易云（歌词）', '歌词',
        <String>['搜索', '取歌词'],
        <String>['https://music.163.com/api/search/get',
            'https://music.163.com/api/song/lyric']),
    EndpointSource('lyric_qq', 'QQ 音乐（歌词）', '歌词', <String>['搜索', '取歌词'],
        <String>['https://u.y.qq.com/cgi-bin/musicu.fcg',
            'https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg']),
    EndpointSource('lyric_ovh', 'lyrics.ovh', '歌词', <String>['按艺人/歌名取词'],
        <String>['https://api.lyrics.ovh/v1']),
    EndpointSource('lyric_kugou', '酷狗（歌词）', '歌词', <String>['搜索', '取歌词'],
        <String>['https://krcs.kugou.com/search',
            'https://lyrics.kugou.com/download']),
    EndpointSource('gitee', 'Gitee 更新（国内优先）', '更新',
        <String>['版本清单', '发布页', '仓库主页', '备用接口'],
        <String>[
          'https://gitee.com/kakadex/MusicOrganizer/raw/main/dist/latest.txt',
          'https://gitee.com/kakadex/MusicOrganizer/releases',
          'https://gitee.com/kakadex/MusicOrganizer',
          'https://gitee.com/api/v5/repos/kakadex/MusicOrganizer/releases/latest'
        ]),
    EndpointSource('update', 'GitHub 更新（兜底）', '更新',
        <String>['最新版本接口', '发布页', '仓库主页', '版本清单'],
        <String>[
          'https://api.github.com/repos/kakadex/MusicOrganizer/releases/latest',
          'https://github.com/kakadex/MusicOrganizer/releases/latest',
          'https://github.com/kakadex/MusicOrganizer',
          'https://raw.githubusercontent.com/kakadex/MusicOrganizer/main/dist/latest.txt'
        ]),
  ];

  static final Map<String, String> _defaults = _buildDefaults();
  static final Map<String, EndpointSource> _byKey = _buildByKey();

  static Map<String, String> _buildDefaults() {
    final Map<String, String> m = <String, String>{};
    for (final EndpointSource s in sources) {
      for (int i = 0; i < s.count; i++) {
        m[s.endpointKey(i)] = s.defaultUrl(i);
      }
    }
    return m;
  }

  static Map<String, EndpointSource> _buildByKey() {
    final Map<String, EndpointSource> m = <String, EndpointSource>{};
    for (final EndpointSource s in sources) {
      m[s.key] = s;
    }
    return m;
  }

  /// 端点当前生效的地址（用户改过就用用户的）。
  static String url(String endpointKey) {
    final EndpointsConfig? c = _config;
    if (c != null) {
      String? custom = c.overrideUrl(endpointKey);
      if (custom != null) {
        custom = custom.trim();
        if (custom.isNotEmpty) return custom;
      }
    }
    return _defaults[endpointKey] ?? '';
  }

  /// 便捷写法：url(sourceKey, index)。
  static String urlOf(String sourceKey, int index) => url('$sourceKey.$index');

  /// 端点是否被用户改过（界面上标「已修改」）。
  static bool customized(String endpointKey) {
    final EndpointsConfig? c = _config;
    if (c == null) return false;
    final String? custom = c.overrideUrl(endpointKey);
    return custom != null && custom.trim().isNotEmpty;
  }

  static String defaultUrl(String endpointKey) => _defaults[endpointKey] ?? '';

  /// 源是否启用（未注入配置时一律启用）。
  static bool enabled(String sourceKey) {
    final EndpointsConfig? c = _config;
    return c == null || c.enabled(sourceKey);
  }

  static EndpointSource? find(String sourceKey) => _byKey[sourceKey];

  /// 是否是已登记的端点键（如 `netease.0`）——导入设置时挡住乱写的键。
  static bool isEndpointKey(String? endpointKey) =>
      endpointKey != null && _defaults.containsKey(endpointKey);

  /// 所有已登记的端点键（导出 / 文档用）。
  static List<String> endpointKeys() => _defaults.keys.toList();

  /// 只接受 http/https，且不能带空格 —— 用户手输时最常见的两类错误。
  static bool isValidUrl(String? url) {
    if (url == null) return false;
    final String s = url.trim();
    if (s.isEmpty || s.contains(' ')) return false;
    final String lower = s.toLowerCase();
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      return false;
    }
    final int start = lower.startsWith('https://') ? 8 : 7;
    if (s.length <= start) return false;
    final String first = s[start];
    return first != '/' && first != '?';
  }

  /// 恢复所有端点的默认地址（不动启用开关）。
  static void resetAll() {
    final EndpointsConfig? c = _config;
    if (c == null) return;
    for (final String key in _defaults.keys) {
      c.setOverride(key, null);
    }
  }
}
