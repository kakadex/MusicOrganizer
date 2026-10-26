/// 标签文本解码的公共容错层。
///
/// ID3 / Vorbis Comment / MP4 atom 都规定文本用 UTF-8，但国产工具链实际写出的
/// 常常不是 UTF-8。这里兜住三类：GBK 冒充 UTF-8、双重编码、真 UTF-8 标 enc=0。
/// 判断依据是「严格 UTF-8 能否解码」+「解出来有没有汉字」，不是靠猜。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'big5_table.dart';
import 'gbk_table.dart';

/// 标签文本解码容错层（纯 Dart）。
abstract final class TagText {
  /// `encoding=3`（UTF-8）的解码，带 GBK 回退与双重编码反解。
  static String decodeUtf8(Uint8List? payload) {
    if (payload == null || payload.isEmpty) return '';
    final String? strict = strictUtf8(payload);
    if (strict != null) {
      final String? fixed = undoDoubleEncoding(strict);
      return stripNul(fixed ?? strict);
    }
    // 非法 UTF-8：多半是 GBK 冒充
    final String? gbk = tryGbk(payload);
    if (gbk != null) return stripNul(gbk);
    return stripNul(utf8.decode(payload, allowMalformed: true));
  }

  /// `encoding=0`（ISO-8859-1）的解码。
  static String decodeLatin1OrGbk(Uint8List? payload) {
    if (payload == null || payload.isEmpty) return '';
    // ① 有的工具把 UTF-8 中文写成 enc=0：能严格解出汉字就信它
    final String? strict = strictUtf8(payload);
    if (strict != null && containsCjk(strict)) return stripNul(strict);
    final String latin = String.fromCharCodes(payload);
    if (!looksLikeGbk(payload)) return stripNul(latin);
    final String? gbk = tryGbk(payload);
    if (gbk != null) return stripNul(gbk);
    return stripNul(latin);
  }

  /// 反解「GBK → 当成 Latin-1 → 再编码成 UTF-8」这一层错；不像时返回 null。
  static String? undoDoubleEncoding(String s) {
    if (s.isEmpty || containsCjk(s)) return null;
    int high = 0;
    for (final int c in s.codeUnits) {
      if (c < 0x80) continue;
      if (c > 0xFF) return null;
      high++;
    }
    if (high < 2) return null;
    final Uint8List bytes = Uint8List.fromList(s.codeUnits);
    return tryGbk(bytes);
  }

  /// 严格 UTF-8 解码；非法返回 null。
  static String? strictUtf8(Uint8List payload) {
    try {
      return utf8.decode(payload, allowMalformed: false);
    } catch (_) {
      return null;
    }
  }

  /// 按 GBK 解码；结果没有汉字、或含替换字符时返回 null。
  static String? tryGbk(Uint8List payload) {
    if (payload.isEmpty) return null;
    final String gbk = decodeGbk(payload);
    if (containsCjk(gbk) && !gbk.contains('\uFFFD')) return gbk;
    return null;
  }

  /// GBK 字节 → Unicode（单字节 ASCII + 双字节区查表）。
  static String decodeGbk(Uint8List payload) {
    final StringBuffer sb = StringBuffer();
    int i = 0;
    while (i < payload.length) {
      final int b = payload[i];
      if (b < 0x80) {
        sb.writeCharCode(b);
        i++;
      } else if (i + 1 < payload.length &&
          b >= 0x81 &&
          b <= 0xFE &&
          payload[i + 1] >= 0x40 &&
          payload[i + 1] <= 0xFE &&
          payload[i + 1] != 0x7F) {
        final int trail = payload[i + 1];
        final int trailOff = trail - 0x40 - (trail > 0x7F ? 1 : 0);
        final int idx = (b - 0x81) * 190 + trailOff;
        sb.writeCharCode(gbkTable.codeUnitAt(idx));
        i += 2;
      } else {
        sb.writeCharCode(0xFFFD);
        i++;
      }
    }
    return sb.toString();
  }

  /// 按 Big5 解码（繁体中文旧工具链常用）；未映射位置给 U+FFFD。
  static String decodeBig5(Uint8List payload) {
    final StringBuffer sb = StringBuffer();
    int i = 0;
    while (i < payload.length) {
      final int b = payload[i];
      if (b < 0x80) {
        sb.writeCharCode(b);
        i++;
      } else if (i + 1 < payload.length &&
          b >= 0xA1 &&
          b <= 0xF9 &&
          ((payload[i + 1] >= 0x40 && payload[i + 1] <= 0x7E) ||
              payload[i + 1] >= 0xA1)) {
        final int trail = payload[i + 1];
        final int trailOff =
            trail <= 0x7E ? trail - 0x40 : trail - 0xA1 + 63;
        final int idx = (b - 0xA1) * 157 + trailOff;
        sb.writeCharCode(big5Table.codeUnitAt(idx));
        i += 2;
      } else {
        sb.writeCharCode(0xFFFD);
        i++;
      }
    }
    return sb.toString();
  }

  /// 按 Big5 解码；结果没有汉字、或含替换字符时返回 null。
  static String? tryBig5(Uint8List payload) {
    if (payload.isEmpty) return null;
    final String big5 = decodeBig5(payload);
    if (containsCjk(big5) && !big5.contains('\uFFFD')) return big5;
    return null;
  }

  static bool looksLikeGbk(Uint8List b) {
    for (int i = 0; i + 1 < b.length; i++) {
      final int h = b[i];
      final int l = b[i + 1];
      if (h >= 0x81 && h <= 0xFE && l >= 0x40 && l <= 0xFE && l != 0x7F) {
        return true;
      }
    }
    return false;
  }

  /// 是否含汉字（基本区）。
  static bool containsCjk(String? s) {
    if (s == null) return false;
    for (final int c in s.codeUnits) {
      if (c >= 0x4E00 && c <= 0x9FFF) return true;
    }
    return false;
  }

  /// 截断到第一个 NUL。
  static String stripNul(String? s) {
    if (s == null) return '';
    final int i = s.indexOf('\u0000');
    return i < 0 ? s : s.substring(0, i);
  }
}
