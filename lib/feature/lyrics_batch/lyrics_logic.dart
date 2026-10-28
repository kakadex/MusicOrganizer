/// 歌词批量的纯逻辑：多源命中 → `offerScore` 打分 → 取最高分的一条。
///
/// 纪律：**只有 `offerScore` 能判断「是不是同一首歌」**。这里不额外加权、
/// 不按来源插队；聚合器给什么就按统一口径打分，分高的排前面。
library;

import '../../core/model/lyric_hit.dart';
import '../../core/model/lyrics_doc.dart';
import '../../core/model/query.dart';
import '../../core/model/vfile.dart';
import '../../core/lyrics/zh.dart';
import '../../core/match/local_query.dart';
import '../../core/source/offer_score.dart';

/// 一首歌选中的歌词。
class LyricChoice {
  LyricChoice({required this.hit, required this.score});

  final LyricHit hit;

  /// [offerScore] 的综合分（负数已在选取时淘汰）。
  final double score;

  /// 是否参与本次写入；低置信默认不勾选。
  bool selected = true;

  /// 是否把歌词转成简体（时间轴 / 标点 / 译文原样保留，日文歌词自动跳过）。
  bool simplify = false;

  /// 是否合成双语：把译文按时间轴就近插到原文行后面。
  bool bilingual = false;

  /// 低于 [LyricPick.lowThreshold]。
  bool get low => score < LyricPick.lowThreshold;

  /// 命中带时间轴（写内嵌时优先用它）。
  bool get hasTiming => hit.synced.trim().isNotEmpty;

  /// 源的中文名。
  String get sourceLabel {
    final String label = LyricHit.label(hit.source).trim();
    return label.isEmpty ? '未知来源' : label;
  }

  /// 有没有译文（译文来自网易 tlyric / QQ trans 这类翻译轨）。
  bool get hasTranslation => hit.translation.trim().isNotEmpty;

  /// 供写入的歌词文本：有时间轴用时间轴版，否则用纯文本；
  /// 开了双语就把译文按时间轴并进去。
  String get text {
    final String raw = hasTiming ? hit.synced.trim() : hit.plain.trim();
    final String merged = (bilingual && hasTranslation)
        ? LyricsDoc.mergeTranslation(raw, hit.translation)
        : raw;
    return simplify ? Zh.toSimplified(merged) : merged;
  }

  /// 一行说明：来源 / 时间轴 / 置信度。
  String get note {
    final String timing = hasTiming ? '带时间轴' : '无时间轴';
    final int pct = (score * 100).round();
    final String trans = hasTranslation ? ' · 有译文' : '';
    return '$sourceLabel · $timing · 置信度 $pct%$trans';
  }
}

/// 歌词选取（纯函数）。
abstract final class LyricPick {
  /// 低置信门槛：与预览面板保持一致。
  static const double lowThreshold = 0.5;

  /// 对一组命中打分并排序（淘汰项不返回）。
  static List<LyricChoice> rank(Query q, Iterable<LyricHit> hits) {
    final String title = LocalQuery.title(q);
    final String artist = LocalQuery.artist(q);
    final bool chinese = LocalQuery.chinese(q);
    final List<LyricChoice> out = <LyricChoice>[];
    for (final LyricHit h in hits) {
      if (!h.hasLyrics()) continue;
      final bool timing = h.synced.trim().isNotEmpty;
      final double score = offerScore(
        localTitle: title,
        localArtist: artist,
        localDuration: q.localDuration,
        candidateTitle: h.title,
        candidateArtist: h.artist,
        candidateDuration: h.duration,
        source: h.source,
        chinese: chinese,
        hasTiming: timing,
      );
      if (score < 0) continue;
      out.add(LyricChoice(hit: h, score: score)..selected = score >= lowThreshold);
    }
    out.sort((LyricChoice a, LyricChoice b) => b.score.compareTo(a.score));
    return out;
  }

  /// 第一条合格（分数最高）的命中；一条都没有返回 null。
  static LyricChoice? best(Query q, Iterable<LyricHit> hits) {
    final List<LyricChoice> ranked = rank(q, hits);
    return ranked.isEmpty ? null : ranked.first;
  }

  /// 同名歌词文件名（与音频同目录、同主名）。
  static String lrcName(VFile f) => '${f.stem()}.lrc';

  /// 预览用的短摘要：前 [maxLines] 行 + 总行数。
  ///
  /// 确认面板与候选列表都只给「够判断是不是这首歌」的信息，不铺整篇歌词。
  static String brief(String text, {int maxLines = 2}) {
    final String t = text.trim();
    if (t.isEmpty) return '';
    final List<String> lines =
        t.split('\n').map((String s) => s.trim()).where((String s) => s.isNotEmpty).toList();
    if (lines.isEmpty) return '';
    final List<String> head = lines.take(maxLines).toList();
    final String joined = head.join(' / ');
    return lines.length <= maxLines ? joined : '$joined …（共 ${lines.length} 行）';
  }
}

/// 一首歌 + 选中的歌词（确认面板与写盘队列共用）。
class LyricPlan {
  const LyricPlan({required this.file, required this.choice});

  final VFile file;
  final LyricChoice choice;
}
