/// 封面缩略图磁盘缓存的「命名与清理策略」（纯 Dart，便于离线单测）。
///
/// 为什么要有这一层：曲库列表每行只画一个 46dp 的封面，但取封面的唯一办法
/// 是读音频文件头（0.5–2MB）再解析标签里的图片，冷启动滚一遍 900 首就是
/// 几百 MB 的读盘量。缩略图把这一步的结果缩小存盘（160px PNG，约 20–40KB），
/// 下次启动直接读小图。
///
/// 这里只放纯逻辑：键怎么算、文件名怎么取、超预算该删谁。真正的编码与落盘
/// 在 app 层（要 dart:ui 解码），方便单测不碰 Flutter。
library;

import 'dart:convert';

import '../model/vfile.dart';

/// 一条缓存条目（清理时用到的全部信息）。
class ThumbEntry {
  const ThumbEntry(this.name, this.bytes, this.modifiedMs);

  /// 文件名（含扩展名）。
  final String name;

  /// 文件大小（字节）。
  final int bytes;

  /// 最后写入时间（毫秒时间戳）；越旧越先删。
  final int modifiedMs;
}

/// 缩略图缓存的命名与容量策略。
abstract final class ThumbPolicy {
  /// 统一用 PNG 落盘：引擎一定解得开，不必再装图片编码库。
  static const String extension = '.png';

  /// 条目上限：900 首的曲库也够用；超了按最旧优先淘汰。
  static const int maxFiles = 4000;

  /// 体积上限：160px PNG 平均 20–40KB，96MB 可放两千多张。
  static const int maxBytes = 96 * 1024 * 1024;

  /// 缓存键：**必须**带大小与修改时间——换封面 / 重打标签后键就变了，
  /// 自然失效，不用维护「谁改了封面」的失效名单。
  static String keyOf(VFile f) => '${f.docId}|${f.size}|${f.lastModified}';

  /// 键 → 文件名：FNV-1a 64 位哈希的 16 位十六进制（固定长度、无非法字符）。
  ///
  /// 高低 32 位分开转再拼：Dart 的 int 是有符号 64 位，直接 `toRadixString`
  /// 遇上最高位为 1 的哈希会输出带负号的串（文件名里多一个 `-`，虽然还能用，
  /// 但风格不一致、也不好排查）。
  static String fileName(String key) {
    final int h = fnv1a64(key);
    final String hi = ((h >> 32) & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
    final String lo = (h & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
    return '$hi$lo$extension';
  }

  /// FNV-1a 64 位（按 UTF-8 字节算，docId 含中文也稳定）。
  static int fnv1a64(String text) {
    int hash = 0xcbf29ce484222325;
    for (final int b in utf8.encode(text)) {
      hash ^= b;
      hash *= 0x100000001b3;
    }
    return hash;
  }

  /// 该删掉哪些文件：超条数或超体积时按「最旧优先」删，一次删到预算的 75%，
  /// 免得每加一张都要再扫一遍目录。
  static List<String> prunePlan(
    List<ThumbEntry> entries, {
    int maxFiles = ThumbPolicy.maxFiles,
    int maxBytes = ThumbPolicy.maxBytes,
  }) {
    int count = entries.length;
    int total = 0;
    for (final ThumbEntry e in entries) {
      total += e.bytes;
    }
    if (count <= maxFiles && total <= maxBytes) return const <String>[];

    final List<ThumbEntry> byAge = List<ThumbEntry>.of(entries)
      ..sort((ThumbEntry a, ThumbEntry b) => a.modifiedMs.compareTo(b.modifiedMs));
    final int targetCount = (maxFiles * 3) ~/ 4;
    final int targetBytes = (maxBytes * 3) ~/ 4;
    final List<String> out = <String>[];
    for (final ThumbEntry e in byAge) {
      if (count <= targetCount && total <= targetBytes) break;
      out.add(e.name);
      count--;
      total -= e.bytes;
    }
    return out;
  }
}
