/// 统一标签结构 —— 移植自旧 core/Tags.java。
///
/// 固定键集 [keys] 刻意不含 lyrics（见 [lyrics]）；year 写盘前截断 4 位（架构设计 §2.1）。
class Tags {
  /// 常规标签字段。
  static const List<String> keys = <String>[
    'title', 'artist', 'album', 'year', 'track', 'genre', 'comment',
  ];

  /// 歌词（MP3 的 USLT 帧 / FLAC 的 LYRICS 字段）。
  ///
  /// 刻意不进 [keys]：歌词可能几 KB，若进 KEYS 会被编辑器当成普通输入框、
  /// 也会被 journal 逐条快照，既撑大界面也撑大撤销日志。
  static const String lyrics = 'lyrics';

  /// 字段中文标签。
  static const Map<String, String> labels = <String, String>{
    'title': '标题',
    'artist': '艺术家',
    'album': '专辑',
    'year': '年份',
    'track': '音轨',
    'genre': '流派',
    'comment': '注释',
    'lyrics': '歌词',
  };

  final Map<String, String> _values = <String, String>{};

  Tags() {
    for (final String k in keys) {
      _values[k] = '';
    }
  }

  /// 读取；键不存在返回空串。
  String get(String key) => _values[key] ?? '';

  /// 写入；null 记为空串，value 去首尾空白，year 截断 4 位。
  void put(String? key, String? value) {
    if (key == null) return;
    String v = value == null ? '' : value.trim();
    if (key == 'year' && v.length > 4) {
      v = v.substring(0, 4);
    }
    _values[key] = v;
  }

  /// 是否任一字段非空。
  bool anyValue() {
    for (final String k in keys) {
      if (_values[k]!.isNotEmpty) return true;
    }
    return false;
  }

  /// 拷贝成独立 Map。
  Map<String, String> toMap() => Map<String, String>.of(_values);

  /// 深拷贝（多个 VFile 间不共享同一个可变对象）。
  Tags copy() {
    final Tags t = Tags();
    _values.forEach((String k, String v) => t._values[k] = v);
    return t;
  }

  @override
  String toString() => _values.toString();
}
