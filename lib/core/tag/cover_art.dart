/// 封面图片小工具（纯字节处理，不依赖解码器）。
library;

import 'dart:typed_data';

/// 封面图片格式 / 尺寸工具（纯 Dart）。
abstract final class CoverArt {
  /// 单张封面的大小上限。
  static const int maxBytes = 4 * 1024 * 1024;

  static bool isJpeg(Uint8List? b) =>
      b != null && b.length > 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF;

  static bool isPng(Uint8List? b) =>
      b != null &&
      b.length > 8 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47;

  /// WebP：RIFF....WEBP。
  static bool isWebp(Uint8List? b) {
    if (b == null || b.length < 12) return false;
    return b[0] == 0x52 &&
        b[1] == 0x49 &&
        b[2] == 0x46 &&
        b[3] == 0x46 &&
        b[8] == 0x57 &&
        b[9] == 0x45 &&
        b[10] == 0x42 &&
        b[11] == 0x50;
  }

  /// GIF：`GIF87a` / `GIF89a`。
  static bool isGif(Uint8List? b) {
    if (b == null || b.length < 6) return false;
    return b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38 &&
        (b[4] == 0x37 || b[4] == 0x39) && b[5] == 0x61;
  }

  /// BMP：`BM` 魔数。
  static bool isBmp(Uint8List? b) {
    if (b == null || b.length < 2) return false;
    return b[0] == 0x42 && b[1] == 0x4D;
  }

  /// 是不是引擎能解的图片（JPEG / PNG / WebP / GIF / BMP）。
  static bool isImage(Uint8List? b) =>
      isJpeg(b) || isPng(b) || isWebp(b) || isGif(b) || isBmp(b);

  /// 这张图**是不是完整的**（不是被截断的前半段）。
  ///
  /// 用途：读封面时先只读文件头 256KB，能解出完整图就不用再读后面的 2MB。
  /// 被截断的图同样能解出一半像素（显示成灰块 / 破图），所以必须按格式校验
  /// 「结尾标记在不在」：
  /// - JPEG 以 `FFD9` 结束；
  /// - PNG 以 `IEND` 块结束（倒数第 8~4 字节）；
  /// - WebP 的 RIFF 长度字段覆盖整个文件；
  /// - GIF 以 `0x3B` 结束；
  /// - BMP 头里的文件长度字段与实际长度一致。
  ///
  /// 不认识或校验不了的格式返回 false（调用方走「多读一点」的老路，宁可慢也不出错）。
  static bool isComplete(Uint8List? b) {
    if (b == null || b.length < 16) return false;
    if (isJpeg(b)) {
      // 允许尾部有极少量填充：取最后 4 字节里找 EOI
      final int from = b.length > 4 ? b.length - 4 : b.length - 2;
      for (int i = b.length - 2; i >= from; i--) {
        if (b[i] == 0xFF && b[i + 1] == 0xD9) return true;
      }
      return false;
    }
    if (isPng(b)) {
      if (b.length < 12) return false;
      final int at = b.length - 8;
      return b[at] == 0x49 && // I
          b[at + 1] == 0x45 && // E
          b[at + 2] == 0x4E && // N
          b[at + 3] == 0x44; // D
    }
    if (isWebp(b)) {
      final int riff = b[4] | (b[5] << 8) | (b[6] << 16) | (b[7] << 24);
      return riff + 8 == b.length;
    }
    if (isGif(b)) return b[b.length - 1] == 0x3B;
    if (isBmp(b) && b.length >= 6) {
      final int size = b[2] | (b[3] << 8) | (b[4] << 16) | (b[5] << 24);
      return size > 0 && size == b.length;
    }
    return false;
  }

  /// MIME；不认识的返回空串。
  static String mimeOf(Uint8List? b) {
    if (isJpeg(b)) return 'image/jpeg';
    if (isPng(b)) return 'image/png';
    if (isWebp(b)) return 'image/webp';
    if (isGif(b)) return 'image/gif';
    if (isBmp(b)) return 'image/bmp';
    return '';
  }

  /// {宽, 高}；解析不出返回 {0, 0}。
  static List<int> dimensions(Uint8List? b) {
    if (isPng(b)) return _pngSize(b!);
    if (isJpeg(b)) return _jpegSize(b!);
    return <int>[0, 0];
  }

  /// 字节数转「120 KB」可读写法。
  static String sizeText(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${bytes ~/ 1024} KB';
    return '${(bytes / 1024.0 / 1024.0).toStringAsFixed(1)} MB';
  }

  /// 「JPEG 800×800 · 120 KB」，预览与日志里用。
  static String describe(Uint8List? b) {
    if (b == null || b.isEmpty) return '无图片';
    final String mime = mimeOf(b);
    final String kind = mime == 'image/png'
        ? 'PNG'
        : (mime.isEmpty ? '未知格式' : 'JPEG');
    final List<int> size = dimensions(b);
    final StringBuffer sb = StringBuffer(kind);
    if (size[0] > 0 && size[1] > 0) sb.write(' ${size[0]}×${size[1]}');
    sb.write(' · ${sizeText(b.length)}');
    return sb.toString();
  }

  static List<int> _pngSize(Uint8List b) {
    if (b.length < 24) return <int>[0, 0];
    final int w = (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19];
    final int h = (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23];
    return <int>[w, h];
  }

  static List<int> _jpegSize(Uint8List b) {
    int pos = 2;
    while (pos + 3 < b.length) {
      if (b[pos] != 0xFF) {
        pos++;
        continue;
      }
      final int marker = b[pos + 1];
      if (marker == 0xD8 ||
          marker == 0xD9 ||
          (marker >= 0xD0 && marker <= 0xD7) ||
          marker == 0x01) {
        pos += 2;
        continue;
      }
      final int len = (b[pos + 2] << 8) | b[pos + 3];
      final bool sof = marker >= 0xC0 &&
          marker <= 0xCF &&
          marker != 0xC4 &&
          marker != 0xC8 &&
          marker != 0xCC;
      if (sof && pos + 9 < b.length) {
        final int h = (b[pos + 5] << 8) | b[pos + 6];
        final int w = (b[pos + 7] << 8) | b[pos + 8];
        return <int>[w, h];
      }
      if (len <= 0) break;
      pos += 2 + len;
    }
    return <int>[0, 0];
  }
}
