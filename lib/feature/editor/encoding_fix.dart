/// 乱码修正：把「按单字节读进来的文本」按候选编码重解。
///
/// 判定口径（与旧版编辑器一致）：**每个字符都 ≤ U+00FF 且含非 ASCII**，
/// 说明这串文本其实是一段字节被当成 Latin-1 显示了。此时把码点还原成字节，
/// 再分别按 UTF-8 / GBK / Big5 重解，挑用户确认的那一份写回。
///
/// 本文件是纯函数，不碰 UI、不读盘；页面只负责把候选展示出来。
library;

import 'dart:typed_data';

import '../../core/tag/tag_text.dart';

/// 一种候选编码的重解结果。
class EncodingCandidate {
  const EncodingCandidate(this.charset, this.text);

  /// 编码名（UTF-8 / GBK / Big5）。
  final String charset;

  /// 重解后的文本。
  final String text;

  @override
  String toString() => '$charset：$text';
}

/// 乱码检测与重解（纯函数）。
abstract final class EncodingFix {
  /// 可选的编码，顺序即界面展示顺序。
  static const List<String> charsets = <String>['UTF-8', 'GBK', 'Big5'];

  /// 是否像「字节被当成单字节字符」的乱码。
  static bool looksMojibake(String text) {
    if (text.isEmpty) return false;
    bool nonAscii = false;
    for (final int c in text.codeUnits) {
      if (c > 0xFF) return false;
      if (c >= 0x80) nonAscii = true;
    }
    return nonAscii;
  }

  /// 按 [charset] 重解（入参的码点必须都 ≤ 0xFF）。
  static String decode(String text, String charset) {
    final Uint8List bytes = Uint8List.fromList(text.codeUnits);
    switch (charset) {
      case 'UTF-8':
        return TagText.strictUtf8(bytes) ?? '';
      case 'GBK':
        return TagText.decodeGbk(bytes);
      case 'Big5':
        return TagText.decodeBig5(bytes);
      default:
        return '';
    }
  }

  /// 所有「解得出可读文本」的候选；解不出或与原串相同的不返回。
  static List<EncodingCandidate> candidates(String text) {
    if (!looksMojibake(text)) return <EncodingCandidate>[];
    final List<EncodingCandidate> out = <EncodingCandidate>[];
    for (final String charset in charsets) {
      final String decoded = decode(text, charset);
      if (decoded.isEmpty || decoded == text) continue;
      if (!_readable(decoded, charset)) continue;
      out.add(EncodingCandidate(charset, decoded));
    }
    return out;
  }

  /// 解出来的文本是否值得给用户看。
  ///
  /// GBK / Big5 双字节区几乎覆盖全部汉字，随便一段字节都能「解出」汉字，
  /// 所以额外要求有汉字；UTF-8 结构严格，能解通即可（西欧重音字符也能修）。
  static bool _readable(String text, String charset) {
    if (text.contains('\uFFFD')) return false;
    for (final int c in text.codeUnits) {
      if (c >= 0x80 && c <= 0x9F) return false;
    }
    if (charset == 'UTF-8') return true;
    return TagText.containsCjk(text);
  }
}
