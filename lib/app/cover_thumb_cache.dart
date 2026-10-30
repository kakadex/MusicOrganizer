/// 封面缩略图的磁盘缓存（0.2.59）。
///
/// 背景：曲库列表给每首取封面，只能读音频文件头（512KB → 2MB）再从标签里
/// 解析图片。进程一退内存缓存就没了，于是**每次启动、每一首被滚到的歌**都要
/// 重新读一次文件头再解码一次。900 首的库，滚一遍就是几百 MB 读盘。
///
/// 这里把解析出来的封面缩到 [maxWidth] 像素、编成 PNG 落盘（约 20–40KB）。
/// 下次启动列表直接读小图，省掉读文件头与解码大图两笔开销。
///
/// 三条纪律：
/// 1. **键带大小 + 修改时间**：换封面 / 重打标签 / 换文件后自动失效（见 [ThumbPolicy.keyOf]）；
/// 2. **写盘走临时名 + 改名**：中途被杀不会留下半张图被当成有效缓存；
/// 3. **有上限**：条数与体积双限，超了按最旧优先淘汰（[ThumbPolicy.prunePlan]）。
///
/// 缓存可随时删：删光了最坏也只是回到「读文件头」的老路，不影响正确性。
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/cover/thumb_policy.dart';
import '../core/model/vfile.dart';

/// 封面缩略图磁盘缓存（单例）。
class CoverThumbCache {
  CoverThumbCache._();

  static final CoverThumbCache instance = CoverThumbCache._();

  /// 缩略图宽度：列表封面最大显示 46dp，160px 在高分屏上也不糊，
  /// 再大只是白占磁盘。
  static const int maxWidth = 160;

  /// 小于这个字节数的一律当坏文件（一张 160px PNG 不可能这么小）。
  static const int _minBytes = 64;

  Directory? _dir;
  bool _pruned = false;

  /// 目录拿不到（插件不可用 / 权限问题）就别每次再试：整轮运行直接走老路。
  bool _unavailable = false;

  /// 单测注入：缓存目录（不传时用应用支持目录）。返回 null 表示禁用。
  @visibleForTesting
  static Future<Directory?> Function()? dirOverride;

  /// 单测注入：编码器（不传时用 dart:ui 解码 + PNG 编码）。
  @visibleForTesting
  static Future<Uint8List?> Function(Uint8List src, int width)? encoderOverride;

  /// 当前缓存目录（测试用；没初始化过返回 null）。
  @visibleForTesting
  Directory? get directory => _dir;

  /// 单测之间复位（缓存目录与「已清理过」标记都要清）。
  @visibleForTesting
  void resetForTest() {
    _dir = null;
    _pruned = false;
    _unavailable = false;
  }

  Future<Directory?> _ensureDir() async {
    final Directory? ready = _dir;
    if (ready != null) return ready;
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
          Directory('${base.path}${Platform.pathSeparator}cover_thumbs');
      if (!await d.exists()) await d.create(recursive: true);
      _dir = d;
      return d;
    } catch (_) {
      // 拿不到目录（权限 / 插件不可用）：整个缓存静默关闭，走老路
      _unavailable = true;
      return null;
    }
  }

  /// 读缓存的缩略图；没有返回 null（不代表「这首没有封面」）。
  ///
  /// 只做一次本地小文件读取，几十 KB，不占并发名额。
  Future<Uint8List?> peek(VFile f) async {
    final Directory? dir = await _ensureDir();
    if (dir == null) return null;
    final File file = File(
        '${dir.path}${Platform.pathSeparator}${ThumbPolicy.fileName(ThumbPolicy.keyOf(f))}');
    try {
      if (!await file.exists()) return null;
      final Uint8List bytes = await file.readAsBytes();
      return bytes.length < _minBytes ? null : bytes;
    } catch (_) {
      return null;
    }
  }

  /// 把一张原图缩成缩略图并落盘（调用方不需要 await，失败无所谓）。
  Future<void> save(VFile f, Uint8List original) async {
    final Directory? dir = await _ensureDir();
    if (dir == null || original.isEmpty) return;
    Uint8List? thumb;
    try {
      thumb = encoderOverride != null
          ? await encoderOverride!(original, maxWidth)
          : await _encodePng(original, maxWidth);
    } catch (_) {
      thumb = null;
    }
    if (thumb == null || thumb.length < _minBytes) return;
    final File target = File(
        '${dir.path}${Platform.pathSeparator}${ThumbPolicy.fileName(ThumbPolicy.keyOf(f))}');
    File? tmp;
    try {
      tmp = File('${target.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
      await tmp.writeAsBytes(thumb, flush: true);
      await tmp.rename(target.path);
    } catch (_) {
      try {
        await tmp?.delete();
      } catch (_) {
        // 临时文件清不掉就算了，下次覆盖同名
      }
    }
    unawaited(_pruneIfNeeded());
  }

  /// 删掉一首歌的缩略图（换封面 / 清标签时顺手调一下，别等淘汰）。
  Future<void> remove(VFile f) async {
    final Directory? dir = await _ensureDir();
    if (dir == null) return;
    try {
      await File(
              '${dir.path}${Platform.pathSeparator}${ThumbPolicy.fileName(ThumbPolicy.keyOf(f))}')
          .delete();
    } catch (_) {
      // 本来就没有
    }
  }

  /// 清空整个缩略图目录（设置里的「清理缓存」或换曲库时用）。
  Future<void> clear() async {
    final Directory? dir = await _ensureDir();
    if (dir == null) return;
    try {
      await for (final FileSystemEntity e in dir.list()) {
        if (e is File) await e.delete();
      }
    } catch (_) {
      // 删不干净不影响正确性
    }
    _pruned = false;
  }

  /// 进程内只扫一次目录；之后每次写入只判断「该不该清理」，不重复列目录。
  Future<void> _pruneIfNeeded() async {
    if (_pruned) return;
    final Directory? dir = await _ensureDir();
    if (dir == null) return;
    _pruned = true;
    try {
      final List<ThumbEntry> entries = <ThumbEntry>[];
      await for (final FileSystemEntity e in dir.list()) {
        if (e is! File || !e.path.endsWith(ThumbPolicy.extension)) continue;
        final FileStat st = await e.stat();
        entries.add(ThumbEntry(
          e.path.split(Platform.pathSeparator).last,
          st.size,
          st.modified.millisecondsSinceEpoch,
        ));
      }
      for (final String name in ThumbPolicy.prunePlan(entries)) {
        try {
          await File('${dir.path}${Platform.pathSeparator}$name').delete();
        } catch (_) {
          // 并发删掉了
        }
      }
    } catch (_) {
      // 清理失败不影响读缓存
    }
  }

  /// 解码 + 缩放到 [width] + 编 PNG。
  ///
  /// 用 `getTargetSize` 让解码器直接按目标尺寸解（JPEG 走整数倍降采样，
  /// 不会先把 1000px 全解进内存再缩）；原图本来就小于 [width] 时不放大。
  static Future<Uint8List?> _encodePng(Uint8List src, int width) async {
    ui.Codec? codec;
    ui.Image? image;
    try {
      // 注意：InstantiateImageCodecWithSize 会接管这个 ImmutableBuffer，
      // 自己不要再去 dispose（会触发断言）；跟着 codec 一起释放即可。
      final ui.ImmutableBuffer buffer =
          await ui.ImmutableBuffer.fromUint8List(src);
      codec = await ui.instantiateImageCodecWithSize(
        buffer,
        getTargetSize: (int w, int h) {
          if (w <= width || h <= 0) return const ui.TargetImageSize();
          final int outH = (h * width / w).round();
          return ui.TargetImageSize(width: width, height: outH < 1 ? 1 : outH);
        },
      );
      final ui.FrameInfo frame = await codec.getNextFrame();
      image = frame.image;
      final ByteData? data =
          await image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } catch (_) {
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }
}
