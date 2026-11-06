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

  /// 目录拿不到时置位，整个缓存静默关闭（退回旧逻辑）。
  bool _unavailable = false;

  File? _file;
  Timer? _saveTimer;
  bool _saving = false;
  bool _dirty = false;

  /// 当前内存里有多少张（测试与排查用）。
  @visibleForTesting
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
    _unavailable = false;
    _file = null;
    _saving = false;
    _dirty = false;
  }

  Future<File?> _ensureFile() async {
    if (_file != null) return _file;
    if (_unavailable) return null;
    try {
      final Directory? base = dirOverride != null
          ? await dirOverride!()
          : await getApplicationSupportDirectory();
      if (base == null) {
        _unavailable = true;
        return null;
      }
      final Directory d =
          Directory('${base.path}${Platform.pathSeparator}cover_pack');
      if (!await d.exists()) await d.create(recursive: true);
      _file = File('${d.path}${Platform.pathSeparator}cover_pack.bin');
      return _file;
    } catch (_) {
      _unavailable = true;
      return null;
    }
  }

  /// 加载整个打包文件进内存（幂等，只做一次）。
  ///
  /// 这是新方案的关键：**一次顺序读**换掉过去 920 次小文件读。
  /// 返回加载到的条目数；文件不存在 / 损坏返回 0（不抛异常）。
  Future<int> ensureLoaded() async {
    if (_loaded) return _blobs.length;
    final File? f = await _ensureFile();
    if (f == null) return 0;
    _loaded = true;
    try {
      if (!await f.exists()) return 0;
      final Uint8List bytes = await f.readAsBytes();
      final ThumbPack? pack = ThumbPackCodec.decode(bytes);
      if (pack == null) {
        // 格式不认识（老版本 / 损坏）：直接重建，别让用户卡在坏缓存上
        try {
          await f.delete();
        } catch (_) {}
        return 0;
      }
      for (final MapEntry<String, Uint8List> e in pack.entries.entries) {
        if (e.value.lengthInBytes < _minBytes) continue;
        _blobs[e.key] = e.value;
        _keys[e.key] = pack.keys[e.key] ?? '';
      }
      return _blobs.length;
    } catch (_) {
      return 0;
    }
  }

  /// 取一张缩略图（**纯内存，零 IO**）；没有或已过期返回 null。
  Uint8List? peekOf(VFile f) {
    final Uint8List? b = _blobs[f.docId];
    if (b == null) return null;
    if (_keys[f.docId] != ThumbPackCodec.keyOf(f)) {
      // 文件变了：这条作废（下次补图会重做）
      _blobs.remove(f.docId);
      _keys.remove(f.docId);
      _markDirty();
      return null;
    }
    return b;
  }

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
  /// 供「退出前」「补图完成后」显式调用；平时由防抖计时器触发。
  Future<void> flush() async {
    if (_saving || !_dirty) return;
    final File? f = await _ensureFile();
    if (f == null) return;
    _saving = true;
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
