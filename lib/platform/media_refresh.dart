/// 媒体库刷新 —— 写完标签后通知系统媒体库（v0.1.80）。
///
/// - 桌面：无需刷新（文件系统直读），no-op 实现统一上层调用；
/// - 安卓：MediaScannerConnection.scanFile（等价旧 MediaRefresh.scan）。
library;

import '../core/model/vfile.dart';
import 'saf_channel.dart';

/// 媒体库刷新接口。
abstract class MediaRefresh {
  /// 通知系统媒体库：这个文件变了。失败静默。
  Future<void> scan(VFile f);

  /// 批量刷新。
  Future<void> scanAll(List<VFile> files);

  /// document id → 文件路径（安卓 MediaScanner 用）；还原不出来返回 null。
  static String? pathOf(VFile f) {
    final String docId = f.docId;
    final int colon = docId.indexOf(':');
    if (colon <= 0 || colon == docId.length - 1) return null;
    final String volume = docId.substring(0, colon);
    String rel = docId.substring(colon + 1);
    if (rel.startsWith('/')) rel = rel.substring(1);
    if (volume.isEmpty || rel.isEmpty) return null;
    if (volume.toLowerCase() == 'primary') return '/storage/emulated/0/$rel';
    return '/storage/$volume/$rel';
  }
}

/// 桌面 no-op 实现。
class DesktopMediaRefresh implements MediaRefresh {
  @override
  Future<void> scan(VFile f) async {}

  @override
  Future<void> scanAll(List<VFile> files) async {}
}

/// 安卓实现（经 SAF 通道通知 MediaScannerConnection）。
class AndroidMediaRefresh implements MediaRefresh {
  @override
  Future<void> scan(VFile f) async {
    final String? path = MediaRefresh.pathOf(f);
    if (path == null) return;
    await SafChannel().mediaScan(<String>[path]);
  }

  @override
  Future<void> scanAll(List<VFile> files) async {
    final List<String> paths = <String>[];
    for (final VFile f in files) {
      final String? p = MediaRefresh.pathOf(f);
      if (p != null) paths.add(p);
    }
    if (paths.isEmpty) return;
    await SafChannel().mediaScan(paths);
  }
}
