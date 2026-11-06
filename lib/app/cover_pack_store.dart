/// 封面缩略图的打包存储（0.2.93）。
///
/// ## 为什么换掉「一歌一文件」
///
/// 旧实现（0.2.59–0.2.92）一个缩略图一个文件，在安卓 SAF 上每读一张都是一次
/// 跨进程调用——920 首就是 920 次。实测单张 37.8KB，读盘开销远大于数据本身，
/// 这是「快速滑动来不及出图」的物理原因，调缓存策略治不了。
///
/// ## 新设计
///
/// - 所有缩略图存进**一个** `cover_pack.bin`（约 30MB / 900 首）；
/// - **启动时顺序读一次**进内存，建 `docId → 字节` 索引；
/// - 之后取任意一张都是**纯内存**操作（[peekOf]），零 IO；
/// - 文件布局见 [ThumbPackCodec]（纯逻辑，已有单测）。
///
/// 写入策略：内存里改了之后**防抖落盘**（默认 3 秒），用临时文件 + 改名保证
/// 原子性；进程被杀最多丢最近几秒的补图，不会写出半个坏文件。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/cover/thumb_pack.dart';
import '../core/log/log.dart';
import '../core/model/vfile.dart';

/// 打包版封面缩略图缓存（单例）。
class CoverPackStore {
  CoverPackStore._();

  static final CoverPackStore instance = CoverPackStore._();

  /// 单张缩略图最小字节数（小于它一律当坏图）。
  static const int _minBytes = 64;

  /// 防抖落盘间隔：连续补图时不要每张都重写 30MB 文件。
  static const Duration saveDebounce = Duration(seconds: 3);

  /// 内存索引：docId → 缩略图字节（全部缩略图常驻内存，约 30MB）。
  final Map<String, Uint8List> _blobs = <String, Uint8List>{};

  /// docId → 键（docId + size + mtime），判断新鲜度用。
  final Map<String, String> _keys = <String, String>{};

  /// 是否已经从磁盘加载过（避免重复读 30MB）。
  bool _loaded = false;

  /// 目录拿不到时的**已失败次数**（0.2.94）。
  ///
  /// 旧版一旦失败就置 `_unavailable = true` 永久禁用——而 `Repo.init` 调
  /// `ensureLoaded()` 时机很早，`path_provider` 可能还没就绪，于是一次失败
  /// 就让**整个进程再也没有封面缓存**：重启后快滑全空白，慢滑一遍才补进内存。
  /// 现在改成「失败可重试」：只有连续失败 [maxDirFailures] 次才放弃。
  int _dirFailures = 0;

  static const int maxDirFailures = 3;

  File? _file;
  Timer? _saveTimer;
  bool _saving = false;
  bool _dirty = false;

  /// 当前内存里有多少张（界面 / 测试用）。
  int get entryCount => _blobs.length;

  /// 估算内存占用（测试用）。
  @visibleForTesting
  int get bytesUsed =>
      _blobs.values.fold<int>(0, (int s, Uint8List b) => s + b.lengthInBytes);

  /// 单测注入：缓存目录。null 表示禁用。
  @visibleForTesting
  static Future<Directory?> Function()? dirOverride;

  /// 单测之间复位。
  @visibleForTesting
  void resetForTest() {
    _saveTimer?.cancel();
    _saveTimer = null;
    _blobs.clear();
    _keys.clear();
    _loaded = false;
    _dirFailures = 0;
    _file = null;
    _saving = false;
    _dirty = false;
  }

  Future<File?> _ensureFile() async {
    if (_file != null) return _file;
    if (_dirFailures >= maxDirFailures) return null;
    try {
      final Directory? base = dirOverride != null
          ? await dirOverride!()
          : await getApplicationSupportDirectory();
      if (base == null) {
        _dirFailures++;
        return null;
      }
      final Directory d =
          Directory('${base.path}${Platform.pathSeparator}cover_pack');
      if (!await d.exists()) await d.create(recursive: true);
      _file = File('${d.path}${Platform.pathSeparator}cover_pack.bin');
      _dirFailures = 0;
      Log.info('[CoverPack] 目录就绪 file=${_file!.path}');
      return _file;
    } catch (e) {
      _dirFailures++;
      Log.warn('[CoverPack] 目录获取失败($_dirFailures/$maxDirFailures) $e');
      return null;
    }
  }

  /// 加载整个打包文件进内存（幂等；**失败可重试**）。
  ///
  /// 这是新方案的关键：**一次顺序读**换掉过去 920 次小文件读。
  /// 返回加载到的条目数；文件不存在 / 损坏返回 0（不抛异常）。
  ///
  /// 0.2.94：只有「真正读成功了（或确认文件不存在）」才把 `_loaded` 置位。
  /// 旧版一进来就置 `_loaded = true`，导致启动早期拿不到目录时永久失败——
  /// 用户感受到的就是「重启后必须慢滑一遍才有封面」。
  Future<int> ensureLoaded() async {
    if (_loaded) return _blobs.length;
    final File? f = await _ensureFile();
    if (f == null) return 0; // 目录没就绪：不置 _loaded，下次还能重试
    try {
      if (!await f.exists()) {
        _loaded = true; // 确实没有缓存文件，之后 put 会逐步写入
        return 0;
      }
      final Uint8List bytes = await f.readAsBytes();
      final ThumbPack? pack = ThumbPackCodec.decode(bytes);
      if (pack == null) {
        // 格式不认识（老版本 / 损坏）：删掉重建，别让用户卡在坏缓存上
        try {
          await f.delete();
        } catch (_) {}
        _loaded = true;
        return 0;
      }
      for (final MapEntry<String, Uint8List> e in pack.entries.entries) {
        if (e.value.lengthInBytes < _minBytes) continue;
        _blobs[e.key] = e.value;
        _keys[e.key] = pack.keys[e.key] ?? '';
      }
      _loaded = true;
      return _blobs.length;
    } catch (_) {
      // 读失败（IO 抖动）：同样不置 _loaded，下次再试
      return 0;
    }
  }

  /// 取一张缩略图（**纯内存，零 IO**）；没有或已过期返回 null。
  ///
  /// 0.2.96：**不再因为一次失配就删除条目**（旧版自杀式逻辑：失配→删内存→
  /// 标脏→把空表写回磁盘，35MB 缓存被自己清空）。现在失配只返回 null，
  /// 条目保留；真正的清理交给下一次 `put` 覆盖。
  /// 失配原因记进诊断计数，方便真机核对。
  Uint8List? peekOf(VFile f) {
    final Uint8List? b = _blobs[f.docId];
    if (b == null) {
      _diagNoEntry++;
      return null;
    }
    if (_keys[f.docId] != ThumbPackCodec.keyOf(f)) {
      _diagStale++;
      if (_diagStale == 1) {
        // 只记第一条失配的细节，避免刷屏；用来判断是 size 还是 mtime 变了
        Log.warn('[CoverPack] 首个失配 docId=${_short(f.docId)} '
            '存=${_keys[f.docId]} 现=${ThumbPackCodec.keyOf(f)}');
      }
      return null;
    }
    return b;
  }

  int _diagNoEntry = 0;
  int _diagStale = 0;

  /// 诊断快照（界面 / 日志用）。
  String diagSummary() =>
      '包内 ${_blobs.length} 条；无条目 $_diagNoEntry 次，失配 $_diagStale 次';

  /// 排查用：某首歌当前的查找键、以及包里存的键（可能没有）。
  String debugKeyOf(VFile f) {
    final String now = ThumbPackCodec.keyOf(f);
    final String? stored = _keys[f.docId];
    return 'now=$now stored=${stored ?? '(无此docId)'}';
  }

  static String _short(String s) =>
      s.length <= 12 ? s : '${s.substring(0, 12)}…';

  /// 有没有这张（不看新鲜度，仅判断是否存过）。
  bool has(String docId) => _blobs.containsKey(docId);

  /// 放入一张缩略图（内存），并安排防抖落盘。
  void put(VFile f, Uint8List bytes) {
    if (bytes.lengthInBytes < _minBytes) return;
    _blobs[f.docId] = bytes;
    _keys[f.docId] = ThumbPackCodec.keyOf(f);
    _markDirty();
  }

  /// 删掉一张（换封面时用）。
  void remove(VFile f) {
    if (_blobs.remove(f.docId) != null) {
      _keys.remove(f.docId);
      _markDirty();
    }
  }

  /// 清空全部（设置里的「清理缓存」）。
  Future<void> clear() async {
    _blobs.clear();
    _keys.clear();
    _markDirty();
    await flush();
  }

  void _markDirty() {
    _dirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(saveDebounce, () {
      unawaited(flush());
    });
  }

  /// 立刻把内存内容写盘（原子：临时文件 → 改名）。
  ///
  /// 供「补图完成后」「退出前」显式调用；平时由防抖计时器触发。
  ///
  /// 0.2.94：写完再检查一次 `_dirty`——flush 期间如果又有 `put`，那批改动
  /// 不能等到下一次防抖（用户可能随时杀进程）。改成循环直到不再脏。
  Future<void> flush() async {
    if (_saving) return;
    _saving = true;
    try {
      while (_dirty) {
        final File? f = await _ensureFile();
        if (f == null) return; // 目录不可用：保留 _dirty，下次再试
        _dirty = false;
        File? tmp;
        try {
          final Uint8List packed =
              ThumbPackCodec.encode(keys: _keys, blobs: _blobs);
          tmp = File('${f.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
          await tmp.writeAsBytes(packed, flush: true);
          await tmp.rename(f.path);
        } catch (_) {
          _dirty = true; // 下次再试
          try {
            await tmp?.delete();
          } catch (_) {}
          return;
        }
      }
    } finally {
      _saving = false;
    }
  }

  /// 打包文件当前大小（排查用；未落盘返回 -1）。
  Future<int> packFileSize() async {
    final File? f = await _ensureFile();
    if (f == null) return -1;
    try {
      return await f.exists() ? await f.length() : 0;
    } catch (_) {
      return -1;
    }
  }
}
