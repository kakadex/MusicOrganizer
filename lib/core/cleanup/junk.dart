/// 垃圾文件识别 —— 移植自旧 core/Junk.java。
///
/// 曲库整理久了会攒下一堆东西：`示例歌名.lrc.bak`（歌词偏移留的备份）、没下完的
/// `.crdownload`、Windows 拷来的 `Thumbs.db`、以及从别处带来的 `.tmp`。留着既占
/// 地方，也让「扫描到 N 个文件」的数字虚高。
///
/// 只做**识别**，不删：把候选列出来让用户勾，删不删由人决定。判定刻意保守 ——
/// 目录、隐藏的未知文件、正常的音频 / 歌词一律不进清单。
library;

import '../match/text_util.dart';
import '../model/vfile.dart';

/// 垃圾类型（界面按它分组展示）。
enum JunkKind {
  /// 系统垃圾：Thumbs.db / desktop.ini / .DS_Store 等。
  system('系统垃圾文件'),

  /// 歌词 / 标签备份：`.lrc.bak` / `.bak`。
  backup('备份文件'),

  /// 未完成的临时文件：`.tmp` / `.part` / `.crdownload`。
  temp('未完成的临时文件'),

  /// 0 字节（创建失败）。
  empty('0 字节（创建失败）'),

  /// 音频不足 1KB，基本是坏文件。
  tiny('音频不足 1KB（疑似损坏）');

  const JunkKind(this.label);

  /// 中文说明（界面直接显示）。
  final String label;
}

/// 一条待清理项。
class JunkItem {
  JunkItem(this.file, this.kind);

  final VFile file;
  final JunkKind kind;

  /// 为什么判定为垃圾（界面显示；同 [JunkKind.label]，个别文件可更具体）。
  String get reason => kind.label;

  int get size => file.size;
}

abstract final class Junk {
  /// 小于这个体积的音频基本是「创建失败」的产物。
  static const int tinyAudioBytes = 1024;

  /// 明确的系统 / 隐藏文件名（小写比较）。
  static const Set<String> _systemNames = <String>{
    '.ds_store', 'thumbs.db', 'desktop.ini', '.directory',
  };

  /// 临时文件扩展名。
  static const Set<String> _tempExts = <String>{
    '.tmp', '.temp', '.part', '.download', '.crdownload', '.partial',
  };

  /// 是否垃圾文件（目录、空名条目、正常音视频一律 false）。
  static bool isJunk(VFile f) => kindOf(f) != null;

  /// 垃圾类型；不是垃圾返回 null。
  static JunkKind? kindOf(VFile f) {
    if (f.dir) return null;
    final String name = f.name.trim();
    if (name.isEmpty) return JunkKind.empty;
    final String lower = name.toLowerCase();
    if (_systemNames.contains(lower)) return JunkKind.system;
    if (lower.endsWith('.lrc.bak') ||
        lower.endsWith('.lrc.bak.txt') ||
        lower.endsWith('.bak') ||
        lower.endsWith('.bak.txt')) {
      return JunkKind.backup;
    }
    // 旧版按扩展名判定；这里补一条按名字判定的规则，覆盖「xxx.tmp.mp3」这类
    // 被临时工具改过扩展名的残留。
    if (_tempExts.contains(f.ext()) || lower.contains('.tmp.')) {
      return JunkKind.temp;
    }
    if (f.size <= 0 && (f.audio() || f.lyric())) return JunkKind.empty;
    if (f.audio() && f.size < tinyAudioBytes) return JunkKind.tiny;
    return null;
  }

  /// 判定原因；不是垃圾返回空串。
  static String reasonOf(VFile f) {
    final JunkKind? kind = kindOf(f);
    return kind == null ? '' : kind.label;
  }

  /// 从扫描结果里挑出垃圾候选（保持输入顺序）。
  static List<JunkItem> plan(List<VFile> files) {
    final List<JunkItem> out = <JunkItem>[];
    for (final VFile f in files) {
      final JunkKind? kind = kindOf(f);
      if (kind != null) out.add(JunkItem(f, kind));
    }
    return out;
  }

  /// 按类型归类（顺序按类型声明先后，空类型不出现），便于界面分组。
  static Map<JunkKind, List<JunkItem>> groupByKind(List<JunkItem> items) {
    final Map<JunkKind, List<JunkItem>> out = <JunkKind, List<JunkItem>>{};
    for (final JunkKind k in JunkKind.values) {
      final List<JunkItem> one =
          items.where((JunkItem it) => it.kind == k).toList();
      if (one.isNotEmpty) out[k] = one;
    }
    return out;
  }

  /// 可释放的总字节。
  static int totalSize(List<JunkItem> items) {
    int sum = 0;
    for (final JunkItem it in items) {
      sum += it.size;
    }
    return sum;
  }

  /// 「12 个文件 · 可释放 1.2 MB」这种摘要。
  static String summary(List<JunkItem> items) {
    if (items.isEmpty) return '没有发现垃圾文件';
    return '${items.length} 个文件 · 可释放 ${TextUtil.formatSize(totalSize(items))}';
  }
}
