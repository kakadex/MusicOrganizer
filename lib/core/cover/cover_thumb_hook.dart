/// 封面缩略图缓存的平台钩子（core 层用）。
///
/// 为什么要这层：`core/` 不许 import `app/`（架构硬规则），但旁挂图 / 目录
/// 封面的小图缓存就实现在 `app/cover_thumb_cache.dart`。这里只留函数位，
/// 由 `app` 层在启动时挂上真实实现——和 [TaskCenter.onStart] 同一套路。
///
/// 三个钩子都可为 null（未挂载时整个优化静默关闭，行为退回旧版）：
/// - [peek]：按文件身份（docId+size+mtime）取磁盘小图，没有返回 null；
/// - [save]：把原图缩成列表尺寸后落盘（后台，调用方不 await）；
/// - [shrink]：把原图缩成列表尺寸给内存缓存用（失败返回 null）。
library;

import 'dart:typed_data';

import '../model/vfile.dart';

/// 封面缩略图钩子（函数指针，可空）。
abstract final class CoverThumbHook {
  /// 按文件身份取磁盘小图；没有返回 null。
  static Future<Uint8List?> Function(VFile file)? peek;

  /// 把原图缩成列表尺寸并落盘；失败无所谓。
  static Future<void> Function(VFile file, Uint8List original)? save;

  /// 把原图缩成列表尺寸（给内存缓存用）；失败返回 null。
  static Future<Uint8List?> Function(Uint8List original)? shrink;

  /// 是否有可用的磁盘缓存（未挂载时为 false）。
  static bool get enabled => peek != null;

  /// 测试用：全部清空。
  static void reset() {
    peek = null;
    save = null;
    shrink = null;
  }
}
