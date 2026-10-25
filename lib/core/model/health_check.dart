/// 曲库体检 —— 移植自旧 core/HealthCheck.java。
///
/// 把逐个文件的事实（有无标题/歌手/专辑/封面/歌词）累加成分数 + 分类计数 + 问题清单。
/// 纯计算，不碰文件。
library;

/// 一个文件的体检事实。
class HealthItem {
  HealthItem([this.name = '', String? ext, this.size = 0])
      : ext = (ext ?? '').toLowerCase();

  String name;
  String ext;
  int size;
  bool title = false;
  bool artist = false;
  bool album = false;
  bool cover = false;
  bool lyrics = false;

  /// 缺失项的短标签，如「缺歌手/缺封面」；齐全时为空串。
  String missing() {
    final StringBuffer sb = StringBuffer();
    _append(sb, !title, '缺标题');
    _append(sb, !artist, '缺歌手');
    _append(sb, !album, '缺专辑');
    _append(sb, !cover, '缺封面');
    _append(sb, !lyrics, '缺歌词');
    return sb.toString();
  }

  /// 五个维度里满足几个（0~5）。
  int score() {
    int n = 0;
    if (title) n++;
    if (artist) n++;
    if (album) n++;
    if (cover) n++;
    if (lyrics) n++;
    return n;
  }

  static void _append(StringBuffer sb, bool cond, String label) {
    if (!cond) return;
    if (sb.isNotEmpty) sb.write('/');
    sb.write(label);
  }
}

/// 体检结果。
class HealthReport {
  int audio = 0;
  int lyricFiles = 0;
  int bytes = 0;
  int noTitle = 0;
  int noArtist = 0;
  int noAlbum = 0;
  int noCover = 0;
  int noLyrics = 0;
  int _complete = 0;

  /// 扩展名 → 首数（按首数倒序输出）。
  final Map<String, int> byExt = <String, int>{};

  /// 有问题的最多保留 200 条。
  final List<HealthItem> issues = <HealthItem>[];

  void add(HealthItem? it) {
    if (it == null) return;
    audio++;
    bytes += it.size;
    if (!it.title) noTitle++;
    if (!it.artist) noArtist++;
    if (!it.album) noAlbum++;
    if (!it.cover) noCover++;
    if (!it.lyrics) noLyrics++;
    final String ext = it.ext.isEmpty ? '其它' : it.ext;
    byExt[ext] = (byExt[ext] ?? 0) + 1;
    if (it.score() >= 5) {
      _complete++;
    } else if (issues.length < 200) {
      issues.add(it);
    }
  }

  /// 完整度（0~100）：五个维度逐首平均。
  int completeness() {
    if (audio == 0) return 0;
    int satisfied =
        audio * 5 - (noTitle + noArtist + noAlbum + noCover + noLyrics);
    if (satisfied < 0) satisfied = 0;
    return (satisfied * 100.0 / (audio * 5.0)).round();
  }

  /// 齐全（五个维度都满足）的首数。
  int complete() => _complete;

  /// 一句话结论。
  String headline() {
    if (audio == 0) return '还没有扫描到音频文件';
    return '完整度 ${completeness()}% · 共 $audio 首';
  }

  /// 缺失项汇总（跳过 0）。
  List<String> lines() {
    final List<String> out = <String>[];
    _addLine(out, noTitle, '缺标题');
    _addLine(out, noArtist, '缺歌手');
    _addLine(out, noAlbum, '缺专辑');
    _addLine(out, noCover, '缺封面');
    _addLine(out, noLyrics, '缺歌词');
    return out;
  }

  /// 「mp3 620 首 · flac 88 首」，按首数倒序。
  String extLine() {
    final List<MapEntry<String, int>> list = byExt.entries.toList()
      ..sort((MapEntry<String, int> a, MapEntry<String, int> b) =>
          b.value.compareTo(a.value));
    final StringBuffer sb = StringBuffer();
    for (final MapEntry<String, int> e in list) {
      if (sb.isNotEmpty) sb.write(' · ');
      String key = e.key;
      if (key.startsWith('.')) key = key.substring(1);
      sb.write('$key ${e.value} 首');
    }
    return sb.toString();
  }

  static void _addLine(List<String> out, int n, String label) {
    if (n > 0) out.add('$label $n 首');
  }
}

/// 体检工具（纯 Dart）。
abstract final class HealthCheck {
  /// 大小格式化（1024 进制，保留一位小数）。
  static String size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final double kb = bytes / 1024.0;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final double mb = kb / 1024.0;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    return '${(mb / 1024.0).toStringAsFixed(2)} GB';
  }
}
