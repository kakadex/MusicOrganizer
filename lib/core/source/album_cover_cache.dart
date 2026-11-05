/// 专辑封面查询的缓存：同一张专辑只问一次外网。
///
/// 为什么需要：907 首大约只有一两百张专辑，但「歌名搜不到图 → 专辑第二跳」
/// 是逐首触发的，同一张专辑会被问上几十次。Deezer / iTunes 都有明确的调用
/// 频率限制（iTunes 约 20 次/分钟），一轮跑下来从几百次请求骤降到几十次，
/// 限流概率大幅下降，两轮结果不一致的问题也随之消失。
///
/// 缓存分三态：
/// - 命中图：记下地址，长期有效（默认 90 天）；
/// - 确认没图：记空串，短期有效（默认 14 天）——太久会把后来才收录的专辑当没图；
/// - 被限流 / 联网失败：**不记**，下一轮自然重查。
///
/// 落盘是一份 JSON（`<dir>/album_covers.json`），原子写、每 20 条落盘一次，
/// 读写异常一律吞掉（缓存坏了就当没有，不影响补封面）。
library;

import 'dart:io';

import '../json/json.dart';

/// 命中图的有效期（90 天）。
const int albumHitTtlMs = 90 * 24 * 3600 * 1000;

/// 「确认没图」的有效期（14 天）。
const int albumMissTtlMs = 14 * 24 * 3600 * 1000;

/// 一条缓存。
class AlbumCoverEntry {
  AlbumCoverEntry(this.url, this.ts);

  /// 封面地址；空串表示「确认没有图」。
  final String url;

  /// 记录时间（毫秒）。
  final int ts;
}

/// 专辑图缓存（内存 + 一份 JSON 落盘）。
class AlbumCoverCache {
  // 具名参数不能带下划线，初始化形式（`this._clock`）在这里用不了。
  // ignore: prefer_initializing_formals
  AlbumCoverCache(this.file, {int Function()? clock}) : _clock = clock;

  /// 条目上限（超了按插入顺序淘汰最旧）。
  static const int maxEntries = 5000;

  /// 每记多少条落一次盘。
  static const int saveEvery = 20;

  final File file;
  final int Function()? _clock;
  final Map<String, AlbumCoverEntry> _entries = <String, AlbumCoverEntry>{};
  int _unsaved = 0;

  int _now() => _clock?.call() ?? DateTime.now().millisecondsSinceEpoch;

  /// 缓存键：专辑 + 艺人，忽略大小写与首尾空白。
  ///
  /// 艺人缺失时只用专辑名——宁可少量串味（同名专辑），也不要完全查不到。
  static String keyOf(String album, String artist) =>
      '${album.trim().toLowerCase()}|${artist.trim().toLowerCase()}';

  /// 读缓存：null = 不知道，空串 = 确认没图，否则是封面地址。
  ///
  /// 过期的条目当场丢掉（只改内存，等下一次落盘时自然消失）。
  String? lookup(String album, String artist) {
    final String key = keyOf(album, artist);
    final AlbumCoverEntry? e = _entries[key];
    if (e == null) return null;
    final int ttl = e.url.isEmpty ? albumMissTtlMs : albumHitTtlMs;
    if (_now() - e.ts > ttl) {
      _entries.remove(key);
      return null;
    }
    return e.url;
  }

  /// 记下结论（[url] 为空表示确认没图）。每 [saveEvery] 条落一次盘。
  void remember(String album, String artist, String url) {
    final String key = keyOf(album, artist);
    if (key == '|') return;
    _entries[key] = AlbumCoverEntry(url.trim(), _now());
    if (_entries.length > maxEntries) {
      // 迭代顺序即插入顺序：淘汰最旧的
      final int over = _entries.length - maxEntries;
      for (final String k in _entries.keys.take(over).toList(growable: false)) {
        _entries.remove(k);
      }
    }
    if (++_unsaved >= saveEvery) {
      _unsaved = 0;
      save();
    }
  }

  /// 立即落盘。返回是否写成功。
  bool save() {
    final StringBuffer sb = StringBuffer('{"v":1,"items":{');
    bool first = true;
    _entries.forEach((String k, AlbumCoverEntry e) {
      if (!first) sb.write(',');
      first = false;
      sb.write('${Json.quote(k)}:{"u":${Json.quote(e.url)},"t":${e.ts}}');
    });
    sb.write('}}');
    return writeAtomic(file, sb.toString());
  }

  /// 清空（用户点「清除全部缓存记忆」）。文件保留为空 JSON。
  void clear() {
    _entries.clear();
    _unsaved = 0;
    save();
  }

  /// 条目数（界面上显示缓存规模用）。
  int size() => _entries.length;

  void _load() {
    String? text;
    try {
      text = file.readAsStringSync();
    } catch (_) {
      return; // 不存在 / 损坏 / 无权限都当读不到
    }
    final Object? root = Json.parseOrNull(text);
    if (root is! Map) return;
    final Object? items = root['items'];
    if (items is! Map) return;
    items.forEach((Object? k, Object? v) {
      if (k is! String || v is! Map) return;
      final Object? u = v['u'];
      final Object? t = v['t'];
      _entries[k] = AlbumCoverEntry(
        u is String ? u : '',
        t is num ? t.toInt() : 0,
      );
    });
  }

  /// 原子写：先写 .tmp 再改名，避免写一半被杀留下半个 JSON。
  static bool writeAtomic(File target, String text) {
    final File tmp = File('${target.path}.tmp');
    try {
      tmp.parent.createSync(recursive: true);
      tmp.writeAsStringSync(text, flush: true);
      tmp.renameSync(target.path); // 已存在则覆盖
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        tmp.deleteSync(); // 已改名成功时删不到，忽略
      } catch (_) {}
    }
  }

  /// 打开（不存在也不报错，空缓存即可）。
  static AlbumCoverCache open(File file) {
    final AlbumCoverCache c = AlbumCoverCache(file);
    c._load();
    return c;
  }
}
