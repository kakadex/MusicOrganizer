/// 批量匹配的中间态落库（断点续跑）—— 移植自旧 core/MatchQueue.java。
///
/// 和 `batch_memory.dart` 分工不同：BatchMemory 记**结论**（查不到 / 被拦 / 已写入），
/// 下次整批直接跳过；MatchQueue 记**待办**（已匹配好、字段是这些、还没写进文件），
/// 进程被杀或用户停止后可以直接接着写 —— 一次 500 首的批量匹配要好几分钟，
/// 写盘前被回收时用户看到的就是「跑完了但文件没变」，最坏只需再点一次写入。
///
/// 指纹（size + mtime）与 BatchMemory 同语义：文件被替换后旧结果自动作废，mtime
/// 取不到时退化为只比大小；存储是一份 JSON（`<dir>/batches/queue-<kind>.json`，
/// 带 queue- 前缀是为了不和同目录 BatchMemory 的 `<kind>.json` 撞名）。
/// 每 30 条落盘、上限 6000 条（先淘汰已收尾的，再淘汰最旧的）、14 天过期；读写异常
/// 一律吞掉：队列坏了就当没有续跑，绝不阻塞主流程。
library;

import 'dart:io';

import '../json/json.dart';
import 'batch_memory.dart';

/// 一条中间态（已匹配、待写入）；键与 BatchMemory 同为 docId（无 docId 用文件名）。
class MatchItem {
  String key = '';
  int size = 0;
  int mtime = 0;
  String status = MatchQueue.pending;
  int ts = 0; // 记录时间（毫秒）；超过 14 天的在加载时作废
  /// 匹配到的字段（标签 / 歌词正文 / 封面地址，按 kind 不同而不同）。
  final Map<String, String> fields = <String, String>{};
  /// 是否还是同一个文件；mtime 为 0（provider 取不到）时只比大小。
  bool sameFile(int size, int mtime) =>
      sameFingerprint(this.size, this.mtime, size, mtime);
  String field(String name, String def) => fields[name] ?? def;
  bool isPending() => status == MatchQueue.pending;

  /// 副本：调用方随便改都不污染队列（要更新走 [MatchQueue.put]）。
  MatchItem copy() => MatchItem()
    ..key = key
    ..size = size
    ..mtime = mtime
    ..status = status
    ..ts = ts
    ..fields.addAll(fields);
}

/// 批量匹配的中间态队列（内存 + 一份 JSON 落盘）。
class MatchQueue {
  /// 四态：落盘是字符串，改枚举会让旧文件读不出来。
  static const String pending = 'pending';
  static const String written = 'written';
  static const String skipped = 'skipped';
  static const String failed = 'failed';
  /// 条目上限 / 落盘间隔 / 过期时间（14 天）。
  static const int maxEntries = 6000;
  static const int saveEvery = 30;
  static const int expireMs = 14 * 24 * 3600 * 1000;

  MatchQueue(this.file, this.kind) {
    _load();
  }

  /// 打开某类任务的队列；[dir] 不存在时创建（通常是 filesDir/batches）。
  factory MatchQueue.open(Directory dir, String kind) {
    final String safe = kind.isEmpty ? 'misc' : kind;
    try {
      dir.createSync(recursive: true); // 已存在是空操作；建不了就当读不到、写不下
    } catch (_) {}
    return MatchQueue(File('${dir.path}/queue-$safe.json'), safe);
  }

  final File file; // 路径由调用方注入，库里不写死常量
  final String kind;
  final Map<String, MatchItem> _items = <String, MatchItem>{};
  int _unsaved = 0;

  /// 取一条可续跑的中间态：指纹一致、状态还是 pending 才给，且返回副本；
  /// 指纹对不上就地删掉 —— 文件已经换了，旧字段留着只会误导下一次批量。
  MatchItem? take(String key, int size, int mtime) {
    final MatchItem? e = key.isEmpty ? null : _items[key];
    if (e == null) return null;
    if (!e.sameFile(size, mtime)) {
      _items.remove(key);
      _unsaved++;
      return null;
    }
    return e.isPending() ? e.copy() : null;
  }

  /// 记下一条刚匹配好的结果（同键覆盖），每 [saveEvery] 条落盘一次。
  void put(String key, int size, int mtime, Map<String, String> fields) {
    if (key.isEmpty) return;
    final MatchItem e = MatchItem()
      ..key = key
      ..size = size
      ..mtime = mtime
      ..ts = DateTime.now().millisecondsSinceEpoch
      ..fields.addAll(fields);
    _items[key] = e;
    _trimLocked();
    if (++_unsaved >= saveEvery) {
      _unsaved = 0;
      save();
    }
  }

  /// 改状态（[written] / [skipped] / [failed]）；每条都即时落盘。
  void mark(String key, String status) {
    final MatchItem? e = _items[key];
    if (e == null) return;
    e.status = status;
    e.ts = DateTime.now().millisecondsSinceEpoch;
    save();
  }

  /// 还等着写入的条数。
  int countPending() => countOf(pending);

  int countOf(String status) =>
      _items.values.where((MatchItem e) => e.status == status).length;

  /// 还等着写入的条目（续跑时按原顺序恢复）。
  List<MatchItem> pendingItems() =>
      _items.values.where((MatchItem e) => e.isPending()).toList();

  /// 清掉已收尾的条目（写入成功 / 跳过 / 失败），只留 pending。
  void clearFinished() {
    _items.removeWhere((String _, MatchItem e) => !e.isPending());
    save();
  }

  /// 清空（文件保留）。
  void clear() {
    _items.clear();
    _unsaved = 0;
    save();
  }

  /// 界面摘要（「N 首待写入（可从中断处继续）」）。
  String summary() =>
      countPending() == 0 ? '无待写入' : '${countPending()} 首待写入（可从中断处继续）';

  /// 待写入的键列表（顺序即写入顺序）。
  List<String> pendingKeys() => _items.values
      .where((MatchItem e) => e.isPending())
      .map((MatchItem e) => e.key)
      .toList();

  /// 立即落盘（任务结束、或记满 [saveEvery] 条时调用）。
  bool save() {
    final StringBuffer sb = StringBuffer('{"version":1,"kind":${Json.quote(kind)},'
        '"updatedAt":${Json.quote(batchTimestamp())},"items":[');
    bool first = true;
    for (final MatchItem e in _items.values) {
      sb.write('${first ? '' : ','}{"k":${Json.quote(e.key)},"s":${e.size},'
          '"m":${e.mtime},"st":${Json.quote(e.status)},"t":${e.ts},"f":{');
      first = false;
      sb.write(e.fields.entries
          .map((MapEntry<String, String> f) =>
              '${Json.quote(f.key)}:${Json.quote(f.value)}')
          .join(','));
      sb.write('}}');
    }
    sb.write(']}\n');
    return BatchMemory.writeAtomic(file, sb.toString());
  }

  void _load() {
    final String? text = readQuietly(file);
    if (text == null) return;
    final Object? root = Json.parseOrNull(text);
    final Object? list = root is Map<String, Object?> ? root['items'] : null;
    if (list is! List<Object?>) return;
    final int now = DateTime.now().millisecondsSinceEpoch;
    for (final Object? o in list) {
      if (o is! Map<String, Object?>) continue;
      final MatchItem e = MatchItem()
        ..key = jsonText(o['k'])
        ..size = jsonInt(o['s'])
        ..mtime = jsonInt(o['m'])
        ..status = jsonText(o['st'])
        ..ts = jsonInt(o['t']);
      if (e.key.isEmpty) continue;
      if (e.status.isEmpty) e.status = pending;
      final Object? f = o['f'];
      if (f is Map<String, Object?>) f.forEach((String k, Object? v) => e.fields[k] = jsonText(v));
      // 过期 / 空字段直接丢：留着只会让下一次批量白跑一次 take()
      if (now - e.ts > expireMs || e.fields.isEmpty) continue;
      _items[e.key] = e;
    }
  }

  /// 超限时先扔已收尾的，再按插入顺序扔最旧的（迭代顺序即插入顺序）。
  void _trimLocked() {
    if (_items.length <= maxEntries) return;
    final List<String> order = _items.keys.toList(growable: false);
    for (final String k in order) {
      if (_items.length <= maxEntries) break;
      if (!(_items[k]?.isPending() ?? false)) _items.remove(k);
    }
    for (final String k in order) {
      if (_items.length <= maxEntries) break;
      _items.remove(k);
    }
  }
}
