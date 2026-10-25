/// 曲库体检规则（纯计算，不碰文件）。
///
/// 页面负责读出「有没有标题 / 歌手 / 专辑 / 封面 / 歌词 / 时长」，这里只做
/// 判定与计数；这样规则可以用固定样本单独回归，不依赖真实曲库。
library;

/// 体检问题分类（顺序即展示顺序）。
enum HealthIssue {
  noTitle('缺标题'),
  noArtist('缺歌手'),
  noAlbum('缺专辑'),
  noCover('缺封面'),
  noLyrics('缺歌词'),
  badDuration('时长异常'),
  oddName('文件名可疑');

  const HealthIssue(this.label);

  final String label;
}

/// 一首歌的体检事实（由页面从 VFile 映射而来）。
class HealthInput {
  const HealthInput({
    required this.docId,
    required this.name,
    this.size = 0,
    this.durationMs = 0,
    this.title = false,
    this.artist = false,
    this.album = false,
    this.cover = false,
    this.lyrics = false,
  });

  final String docId;
  final String name;
  final int size;

  /// 时长（毫秒）；0 表示未知，不参与「时长异常」判定。
  final int durationMs;
  final bool title;
  final bool artist;
  final bool album;
  final bool cover;
  final bool lyrics;
}

/// 一首歌的体检结论。
class HealthTrack {
  HealthTrack(this.input, this.issues);

  final HealthInput input;
  final Set<HealthIssue> issues;

  bool get clean => issues.isEmpty;

  /// 标签五维是否齐全（时长 / 文件名不影响这一项）。
  bool get tagsComplete =>
      !issues.contains(HealthIssue.noTitle) &&
      !issues.contains(HealthIssue.noArtist) &&
      !issues.contains(HealthIssue.noAlbum) &&
      !issues.contains(HealthIssue.noCover) &&
      !issues.contains(HealthIssue.noLyrics);

  /// 问题短标签；齐全时为「五维齐全」。
  String detail() {
    if (issues.isEmpty) return '五维齐全';
    return HealthIssue.values
        .where((HealthIssue i) => issues.contains(i))
        .map((HealthIssue i) => i.label)
        .join('/');
  }
}

/// 一次体检的汇总。
class HealthResult {
  HealthResult(this.tracks);

  final List<HealthTrack> tracks;

  int get audio => tracks.length;

  /// 五个标签维度全部满足的首数。
  int get complete => tracks.where((HealthTrack t) => t.tagsComplete).length;

  /// 有问题的曲目（默认列表）。
  List<HealthTrack> get problems =>
      tracks.where((HealthTrack t) => !t.clean).toList();

  int countOf(HealthIssue issue) =>
      tracks.where((HealthTrack t) => t.issues.contains(issue)).length;

  /// 筛出命中某一项的曲目（一键筛选）。
  List<HealthTrack> withIssue(HealthIssue issue) => tracks
      .where((HealthTrack t) => t.issues.contains(issue))
      .toList();

  /// 完整度（0~100）：只按标签五维平均，时长 / 文件名不算在内。
  int completeness() {
    if (audio == 0) return 0;
    final int bad = countOf(HealthIssue.noTitle) +
        countOf(HealthIssue.noArtist) +
        countOf(HealthIssue.noAlbum) +
        countOf(HealthIssue.noCover) +
        countOf(HealthIssue.noLyrics);
    final int satisfied = audio * 5 - bad;
    if (satisfied <= 0) return 0;
    return (satisfied * 100.0 / (audio * 5.0)).round();
  }

  /// 一句话结论。
  String headline() {
    if (audio == 0) return '还没有扫描到音频文件';
    final int bad = problems.length;
    return '完整度 ${completeness()}% · 共 $audio 首'
        '${bad > 0 ? ' · 待处理 $bad 首' : ' · 全部齐全'}';
  }

  /// 逐项统计（跳过 0），如「缺标题 3 首」。
  List<String> lines() {
    final List<String> out = <String>[];
    for (final HealthIssue issue in HealthIssue.values) {
      final int n = countOf(issue);
      if (n > 0) out.add('${issue.label} $n 首');
    }
    return out;
  }
}

/// 体检规则（纯 Dart）。
abstract final class HealthAudit {
  /// 短于 10 秒视为可疑（多半是读错了时长或截断文件）。
  static const int minDurationMs = 10 * 1000;

  /// 长于 30 分钟视为可疑（单曲极少有这种时长）。
  static const int maxDurationMs = 30 * 60 * 1000;

  /// 时长是否可疑；0 表示未知，放行。
  static bool badDuration(int ms) =>
      ms > 0 && (ms < minDurationMs || ms > maxDurationMs);

  /// 文件名是否可疑：纯数字、track01 这类占位名、带「未命名/副本」，
  /// 以及首尾空格、连续空格、Windows 非法字符。
  static bool suspiciousName(String name) {
    final int dot = name.lastIndexOf('.');
    final String base = dot > 0 ? name.substring(0, dot) : name;
    final String stem = base.trim();
    if (stem.isEmpty || stem != base) return true;
    if (RegExp(r'^\d+$').hasMatch(stem)) return true;
    if (RegExp(r'^track\s*\d+$', caseSensitive: false).hasMatch(stem)) {
      return true;
    }
    final String lower = stem.toLowerCase();
    for (final String bad in <String>[
      '未命名', 'untitled', 'unknown', '副本', 'copy', '新建',
    ]) {
      if (lower.contains(bad)) return true;
    }
    return stem.contains('  ') || stem.contains('?') || stem.contains('*');
  }

  /// 计算一首歌命中的问题。
  static Set<HealthIssue> issuesOf(HealthInput i) {
    final Set<HealthIssue> out = <HealthIssue>{};
    if (!i.title) out.add(HealthIssue.noTitle);
    if (!i.artist) out.add(HealthIssue.noArtist);
    if (!i.album) out.add(HealthIssue.noAlbum);
    if (!i.cover) out.add(HealthIssue.noCover);
    if (!i.lyrics) out.add(HealthIssue.noLyrics);
    if (badDuration(i.durationMs)) out.add(HealthIssue.badDuration);
    if (suspiciousName(i.name)) out.add(HealthIssue.oddName);
    return out;
  }

  /// 批量体检。
  static HealthResult run(Iterable<HealthInput> inputs) {
    final List<HealthTrack> tracks = <HealthTrack>[
      for (final HealthInput i in inputs) HealthTrack(i, issuesOf(i)),
    ];
    return HealthResult(tracks);
  }
}
