/// 封面批量的纯逻辑：候选里挑哪个 URL、下载回来的是不是图片。
///
/// 来源顺序由 [Aggregator] 决定（高分在前），这里只做两件可离线回归的事：
/// 跳过空地址与非 http(s) 地址；按文件头判断图片类型，挡掉 CDN 返回的 HTML。
library;

import 'dart:typed_data';

import '../../core/model/candidate.dart';

/// 封面 URL 与图片内容判定（纯函数）。
abstract final class CoverPick {
  /// 候选列表里第一条可用的封面地址；没有返回空串。
  static String urlOf(Iterable<Candidate> candidates) {
    for (final Candidate c in candidates) {
      final String url = c.coverUrl.trim();
      if (url.isEmpty) continue;
      final Uri? uri = Uri.tryParse(url);
      if (uri == null || uri.host.isEmpty) continue;
      if (uri.scheme != 'http' && uri.scheme != 'https') continue;
      return url;
    }
    return '';
  }

  /// 字节头是否是常见图片格式（JPEG / PNG / WebP / GIF / BMP）。
  static bool looksLikeImage(Uint8List bytes) {
    if (bytes.length < 12) return false;
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) return true;
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return true;
    }
    if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) return true;
    if (bytes[0] == 0x42 && bytes[1] == 0x4D) return true;
    if (bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return true;
    }
    return false;
  }
}
