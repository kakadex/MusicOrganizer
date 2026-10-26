/// 酷狗 KRC 歌词：解密 + 转 LRC。
///
/// 服务器下发的 `fmt=krc` 内容是加密的：base64 解码后是 `krc1` 魔数 + 用 16 字节
/// 密钥 XOR 过的 zlib 流。解密步骤：
///   1. 宽容地 base64 解码；
///   2. 去掉前 4 字节的 `krc1` 魔数；
///   3. 余下字节与 16 字节密钥循环异或（[key]）；
///   4. zlib 解压，得到明文 KRC。
/// 明文 KRC 每行形如 `[0,1000]<0,300,0>故<300,300,0>事`：行首 `[行开始毫秒,行时长]`，
/// 后面是逐字三元组 `<字开始,时长,0>字`。
///
/// 密钥**别改成网上流传的 8 字节版本**（40 47 61 38 3B 39 3B 39）：它与正确密钥只有
/// 前 3 个字节相同，解出来头两字节碰巧仍是 78 9C（zlib 魔数），后面的流从第 4 字节
/// 起整体错位，inflate 必然失败。
///
/// 解不出来不算异常，返回空串由调用方降级到 `fmt=lrc` 的明文歌词（见
/// `LyricSources.kugou` 的降级分支）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// KRC 解密 / 转写工具（纯 Dart，无 Flutter 依赖）。
abstract final class Krc {
  /// XOR 密钥，16 字节：`@Gaw^2tGQ61-` + CE D2 6E 69。
  static const List<int> key = <int>[
    0x40, 0x47, 0x61, 0x77, 0x5E, 0x32, 0x74, 0x47, //
    0x51, 0x36, 0x31, 0x2D, 0xCE, 0xD2, 0x6E, 0x69,
  ];

  /// 密文头 4 字节的魔数 `krc1`（k r c 1）。
  static const List<int> magic = <int>[0x6B, 0x72, 0x63, 0x31];

  /// 逐字三元组 `<...>`，转 LRC 时整段丢弃。
  static final RegExp _wordRe = RegExp(r'<[^>]*>');

  /// 是否像 KRC 密文（`krc` 的 base64 前缀 `a3Jj`，或明文 `krc1` 头）。
  static bool looksEncoded(String? source) {
    if (source == null) return false;
    final String s = source.trim();
    return s.startsWith('a3Jj') || s.startsWith('krc1');
  }

  /// 解密 + 解压；失败返回空串（调用方据此降级）。
  static String decode(String? source) {
    final Uint8List? body = decodeBase64(source);
    if (body == null || body.length < 8) return '';
    int offset = 0;
    if (_startsWithMagic(body)) offset = magic.length;
    final Uint8List payload = Uint8List(body.length - offset);
    for (int i = 0; i < payload.length; i++) {
      payload[i] = body[offset + i] ^ key[i % key.length];
    }
    String text = _inflate(payload);
    if (text.isEmpty && payload.length > 8) {
      // 少数样本在 zlib 流前多 4 字节长度：给一次容错机会
      text = _inflate(payload.sublist(4));
    }
    return text;
  }

  /// 明文 KRC → 普通 LRC：只保留每行的起始时间轴，逐字时长整段丢弃。
  ///
  /// 行首元信息（`[ar:]` / `[ti:]` / `[offset:]` 等）原样保留。
  static String toLrc(String? krcText) {
    if (krcText == null || krcText.trim().isEmpty) return '';
    final StringBuffer out = StringBuffer();
    final String norm = krcText.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    for (final String raw in norm.split('\n')) {
      final String line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('[') && !_isTimedLine(line)) {
        out.writeln(line);
        continue;
      }
      final String? converted = _convertLine(line);
      if (converted != null) out.writeln(converted);
    }
    return out.toString().trim();
  }

  /// 宽容的 base64 解码：忽略空白，支持无填充与 urlsafe 字符；失败返回 null。
  static Uint8List? decodeBase64(String? text) {
    if (text == null) return null;
    final String s =
        text.replaceAll(RegExp(r'\s+'), '').replaceAll('-', '+').replaceAll('_', '/');
    if (s.isEmpty) return null;
    final int pad = s.length % 4;
    final String padded = pad == 0 ? s : s + '=' * (4 - pad);
    try {
      return Uint8List.fromList(base64.decode(padded));
    } on FormatException {
      return null;
    }
  }

  static bool _startsWithMagic(Uint8List body) {
    for (int i = 0; i < magic.length; i++) {
      if (body[i] != magic[i]) return false;
    }
    return true;
  }

  /// zlib 解压；异常一律吞掉，返回空串。
  static String _inflate(List<int> data) {
    if (data.isEmpty) return '';
    try {
      return utf8.decode(zlib.decode(data), allowMalformed: true);
    } on Object {
      return '';
    }
  }

  /// `[0,1000]…` 这种行头才算时间轴行；`[ar:xxx]` 是元信息。
  static bool _isTimedLine(String line) {
    final int close = line.indexOf(']');
    if (close <= 0) return false;
    final String head = line.substring(1, close);
    final int comma = head.indexOf(',');
    return comma > 0 && head.codeUnitAt(0) >= 0x30 && head.codeUnitAt(0) <= 0x39;
  }

  /// 一行 KRC → `[mm:ss.cc]文本`；没有时间轴或文本为空返回 null。
  static String? _convertLine(String line) {
    final int close = line.indexOf(']');
    if (close <= 0) return null;
    final String head = line.substring(1, close);
    final int comma = head.indexOf(',');
    final int? start = int.tryParse((comma > 0 ? head.substring(0, comma) : head).trim());
    if (start == null) return null;
    final String plain = line.substring(close + 1).replaceAll(_wordRe, '');
    if (plain.trim().isEmpty) return null;
    return _stamp(start) + plain;
  }

  /// 毫秒 → `[mm:ss.cc]`（百分秒，与 LRC 时间轴一致）。
  static String _stamp(int ms) {
    final int t = ms < 0 ? 0 : ms;
    final int totalSec = t ~/ 1000;
    return '[${_two(totalSec ~/ 60)}:${_two(totalSec % 60)}'
        '.${_two((t % 1000) ~/ 10)}]';
  }

  static String _two(int v) => v.toString().padLeft(2, '0');
}
