/// 扫描过滤：路径关键字黑名单 + 忽略视频文件。
///
/// 曲库目录里常有「录音 / 铃声 / 网盘缓存 / 视频」这类目录，混进来会污染
/// 查重与整理结果。过滤在遍历阶段就做掉，后面所有环节（扫描 / 垃圾清理 / 查重）
/// 看到的就是同一份干净列表。
///
/// 纯 Dart：不读盘、不联网，便于离线回归。
library;

import '../model/vfile.dart';

/// 扫描过滤规则。
class ScanFilter {
  ScanFilter({List<String>? keywords, this.ignoreVideo = false})
      : keywords = <String>[
          for (final String k in keywords ?? const <String>[])
            if (k.trim().isNotEmpty) k.trim().toLowerCase()
        ];

  /// 路径关键字（小写）；命中任意一个就不收这个文件。
  final List<String> keywords;

  /// 忽略视频文件（垃圾清理 / 全量遍历里也不把视频当候选）。
  final bool ignoreVideo;

  static const Set<String> videoExts = <String>{
    '.mp4', '.mkv', '.avi', '.mov', '.webm', '.flv', '.wmv', '.m4v',
    '.mpg', '.mpeg', '.ts', '.rmvb', '.3gp',
  };

  /// 没有规则时走这条（避免每次都建对象）。
  bool get isEmpty => keywords.isEmpty && !ignoreVideo;

  /// 从「用户填的一坨文本」解析：逗号 / 分号 / 换行都当分隔符。
  static ScanFilter parse(String? text, {bool ignoreVideo = false}) {
    if (text == null || text.trim().isEmpty) {
      return ScanFilter(ignoreVideo: ignoreVideo);
    }
    final List<String> parts = text
        .split(RegExp(r'[,，;；\n\r]+'))
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .toList();
    return ScanFilter(keywords: parts, ignoreVideo: ignoreVideo);
  }

  /// 序列化回文本（存设置用）。
  String keywordsText() => keywords.join(', ');

  /// 这个文件要不要跳过。
  bool skip(VFile f) {
    if (isEmpty) return false;
    if (ignoreVideo && videoExts.contains(f.ext())) return true;
    if (keywords.isEmpty) return false;
    final String path = f.docId.toLowerCase();
    for (final String k in keywords) {
      if (path.contains(k)) return true;
    }
    return false;
  }

  /// 这个目录要不要整棵跳过（目录名命中就不再往下走，省掉大量 provider 查询）。
  bool skipDir(VFile dir) {
    if (keywords.isEmpty) return false;
    final String path = dir.docId.toLowerCase();
    for (final String k in keywords) {
      if (path.contains(k)) return true;
    }
    return false;
  }
}
