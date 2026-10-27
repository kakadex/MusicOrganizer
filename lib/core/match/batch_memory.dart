/// 批量任务的「记忆」。
///
/// 记住每首歌上次查到什么，下一批直接跳过没戏的、已写完的，解决两个痛点：库里
/// 根本没有的歌，上一批查了 4 家源全是空，下一批还要再查 4 家（一批 500 首里
/// 这种能占三成，白烧时间和配额）；任务被杀或用户点停止后也不必全部重新匹配，
/// 有了记忆就只补剩下的。
///
/// 判定键是 docId，附带 size + mtime 指纹：文件被替换 / 重新编码后指纹变了，旧
/// 结论自动失效 —— 这是本类唯一的「过期」策略（结论不随
/// 源站变化而失真，按时间清掉只会白白重查一遍）。
///
/// 落盘是一份 JSON（`<dir>/batches/<kind>.json`），不引数据库：条目只是「键 +
/// 三个数字 + 一个状态」，几千条也就几百 KB；原子写 + 每 40 条落盘一次，
/// 读写异常一律吞掉（记忆坏了就当没有增量）。
library;

import 'dart:io';

import '../json/json.dart';

/// 落盘文件的 updatedAt（yyyy-MM-dd HH:mm:ss）。
String batchTimestamp() {
  final DateTime n = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${n.year}-${two(n.month)}-${two(n.day)} '
      '${two(n.hour)}:${two(n.minute)}:${two(n.second)}';
}

/// JSON 取值：缺失转空串。
String jsonText(Object? v) => v == null ? '' : v.toString();

/// JSON 取整数：字符串 / 小数都能读（备份文件里可能有 "123"）。
int jsonInt(Object? v) {
  if (v is num) return v.toInt(); // 自己解析出来的数字一律是 double
  return (v == null ? null : double.tryParse(v.toString().trim()))?.toInt() ?? 0;
}

/// 读整个文件；读不出来（不存在 / 损坏 / 无权限）返回 null。
String? readQuietly(File f) {
  try {
    return f.readAsStringSync();
  } catch (_) {} // 不存在 / 损坏 / 无权限都当读不到
  return null;
}

/// 指纹比对：size 必须相同，mtime 取不到（0）时只比大小。
bool sameFingerprint(int size1, int mtime1, int size2, int mtime2) =>
    size1 == size2 && (mtime1 == 0 || mtime2 == 0 || mtime1 == mtime2);

/// 一条记忆（某首歌上次的结论）；比对走 [sameFingerprint]。
class MemoryEntry {
  int size = 0;
  int mtime = 0;
  String status = BatchMemory.noHit;
  int ts = 0; // 记录时间（毫秒）
}

/// 增量匹配记忆（内存 + 一份 JSON 落盘）。
class BatchMemory {
  /// 三种结论：所有源都没结果 / 有结果但被拦下 / 已成功写入（都不必再查）。
  static const String noHit = 'nohit';
  static const String rejected = 'reject';
  static const String done = 'done';

  /// 查到了候选但还没写盘：**不算已处理**，下次仍要重新匹配/重试。
  static const String matched = 'matched';
  /// 条目上限 / 落盘间隔（超出按插入顺序淘汰最旧）。
  static const int maxEntries = 20000;
  static const int saveEvery = 40;

  BatchMemory(this.file, this.kind) {
    _load();
  }

  /// 打开（或创建）某类任务的记忆；[dir] 不存在时创建。
  factory BatchMemory.open(Directory dir, String kind) {
    try {
      dir.createSync(recursive: true); // 已存在是空操作；建不了就当读不到、写不下
    } catch (_) {}
    return BatchMemory(File('${dir.path}/$kind.json'), kind);
  }

  final File file; // 路径由调用方注入，库里不写死常量
  final String kind;
  final Map<String, MemoryEntry> _entries = <String, MemoryEntry>{};
  int _unsaved = 0;
  int _savedSkips = 0;
  /// 「忽略已有记忆，这一轮全部重新联网查询」（设置页开关）。
  bool ignoreExisting = false;

  /// 上次的结论还能不能用：文件没变、状态是「查不到 / 被拦 / 已写入」才算数；
  /// 开着 [ignoreExisting] 时一律 false（新结论照常记录）。
  bool shouldSkip(String key, int size, int mtime) {
    if (key.isEmpty || ignoreExisting) return false;
    final MemoryEntry? e = _entries[key];
    if (e == null || !sameFingerprint(e.size, e.mtime, size, mtime)) return false;
    _savedSkips++;
    return e.status == noHit || e.status == rejected || e.status == done;
  }

  /// 上次的结论；指纹对不上返回空串。
  String statusOf(String key, int size, int mtime) {
    final MemoryEntry? e = _entries[key];
    return e != null && sameFingerprint(e.size, e.mtime, size, mtime) ? e.status : '';
  }

  /// 记下结论（同键覆盖），每 [saveEvery] 条落盘一次。
  void record(String key, int size, int mtime, String status) {
    if (key.isEmpty) return;
    _entries.putIfAbsent(key, MemoryEntry.new)
      ..size = size
      ..mtime = mtime
      ..status = status
      ..ts = DateTime.now().millisecondsSinceEpoch;
    _trimLocked();
    if (++_unsaved >= saveEvery) {
      _unsaved = 0;
      save();
    }
  }

  /// 这首歌已经写好了（下次整批跳过）。
  void markDone(String key, int size, int mtime) => record(key, size, mtime, done);

  /// 本次运行里「靠记忆省下来的查询次数」。
  int skipCount() => _savedSkips;
  int size() => _entries.length;
  int countOf(String status) =>
      _entries.values.where((MemoryEntry e) => e.status == status).length;

  /// 界面摘要（「记忆 N 首（无结果 x / 被拦 y / 已写入 z）」）。
  String summary() => size() == 0
      ? '还没有匹配记忆'
      : '记忆 ${size()} 首（无结果 ${countOf(noHit)} / 被拦 ${countOf(rejected)} / '
          '已写入 ${countOf(done)}）';
  /// 清空（文件保留）。
  void clear() {
    _entries.clear();
    _unsaved = 0;
    save();
  }

  /// 忘掉一首歌的结论（「重新联网查询」时逐首调用）：只删这一首，不必为了重查
  /// 几首清空整份记忆（那会让下一次批量重查几万首）。
  bool forget(String key) {
    if (key.isEmpty) return false;
    if (_entries.remove(key) == null) return false;
    _unsaved = 0;
    save();
    return true;
  }

  /// 超出上限就按插入顺序淘汰最旧的。
  void _trimLocked() {
    final int over = _entries.length - maxEntries;
    if (over <= 0) return;
    for (final String k in _entries.keys.take(over).toList(growable: false)) {
      _entries.remove(k);
    }
  }

  /// 立即落盘（任务结束、或记满 [saveEvery] 条时调用）。
  bool save() {
    final StringBuffer sb = StringBuffer('{"version":1,"kind":${Json.quote(kind)},'
        '"updatedAt":${Json.quote(batchTimestamp())},"entries":{');
    sb.write(_entries.entries
        .map((MapEntry<String, MemoryEntry> e) => '${Json.quote(e.key)}:{"s":'
            '${e.value.size},"m":${e.value.mtime},"st":'
            '${Json.quote(e.value.status)},"t":${e.value.ts}}')
        .join(','));
    sb.write('}}\n');
    return writeAtomic(file, sb.toString());
  }

  /// 原子写：先写 .tmp 再改名，避免写一半被杀留下半个 JSON。
  static bool writeAtomic(File target, String text) {
    final File tmp = File('${target.path}.tmp');
    try {
      tmp.writeAsStringSync(text, flush: true);
      tmp.renameSync(target.path); // 已存在则覆盖
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        tmp.deleteSync(); // 已经改名成功时这里删不到，忽略
      } catch (_) {}
    }
  }

  void _load() {
    final String? text = readQuietly(file);
    final Object? root = text == null ? null : Json.parseOrNull(text);
    final Object? raw = root is Map<String, Object?> ? root['entries'] : null;
    if (raw is! Map<String, Object?>) return;
    raw.forEach((String key, Object? v) {
      if (v is! Map<String, Object?>) return;
      _entries[key] = MemoryEntry()
        ..size = jsonInt(v['s'])
        ..mtime = jsonInt(v['m'])
        ..status = v['st'] == null ? noHit : jsonText(v['st'])
        ..ts = jsonInt(v['t']);
    });
  }
}
