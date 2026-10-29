/// 候选与本地曲目的匹配打分 的 offerScore（**唯一取舍点**）。
///
/// 纪律：**只有这里能决定「算不算同一首歌」**。各数据源只负责取候选，
/// 不许各自加权重、各自定义「像不像」。改阈值只改这一个文件。
///
/// 三道门槛（任一不过直接淘汰，返回 -1）：
/// 1. 标题相似度 ≥ 0.60；
/// 2. 艺人相似度 ≥ 0.50（任一方缺艺人时给 0.55，既不满分也不当证据）；
/// 3. 时长差 ≤ 6 秒（本地与候选都读到时长才算，缺一方给中间值）。
library;

import '../match/text_util.dart';

/// 变体词：候选标题里有、本地标题里没有 → 判为不同版本（伴奏 / 现场 / remix …）。
const List<String> variantWords = <String>[
  '伴奏', '纯音乐', 'instrumental', 'karaoke', 'ktv', 'remix', '现场', 'live',
  'cover', '翻唱', '片段', '铃声', '试听', '串烧', '抖音', '女声版', '男声版',
];

/// 打分结果。
class OfferScore {
  OfferScore(this.score, {this.reason = ''});

  /// 综合分；负数表示淘汰。
  final double score;

  /// 淘汰原因（空串表示通过）。
  final String reason;

  bool get rejected => score < 0;
}

/// 对一条候选打分：返回负数表示不是同一首歌。
///
/// [chinese] 为曲目语种，决定国内源加成（中文曲目偏国内源、外文曲目偏 LRCLIB）。
double offerScore({
  required String localTitle,
  required String localArtist,
  required double? localDuration,
  required String candidateTitle,
  required String candidateArtist,
  required double? candidateDuration,
  required String source,
  required bool chinese,
  bool hasTiming = false,
}) =>
    scoreDetail(
      localTitle: localTitle,
      localArtist: localArtist,
      localDuration: localDuration,
      candidateTitle: candidateTitle,
      candidateArtist: candidateArtist,
      candidateDuration: candidateDuration,
      source: source,
      chinese: chinese,
      hasTiming: hasTiming,
    ).score;

/// 同 [offerScore]，额外给出淘汰原因（界面提示用）。
OfferScore scoreDetail({
  required String localTitle,
  required String localArtist,
  required double? localDuration,
  required String candidateTitle,
  required String candidateArtist,
  required double? candidateDuration,
  required String source,
  required bool chinese,
  bool hasTiming = false,
  bool strictDuration = true,
}) {
  if (isVariant(candidateTitle, localTitle)) {
    return OfferScore(-1, reason: '候选是另一个版本（伴奏 / 现场 / remix …）');
  }
  final double ts = TextUtil.textSimilarity(TextUtil.safeStr(localTitle), candidateTitle);
  if (ts < 0.60) {
    return OfferScore(-1, reason: '标题差异过大');
  }
  final double as;
  final String a = TextUtil.safeStr(localArtist);
  final String b = TextUtil.safeStr(candidateArtist);
  if (a.isEmpty || b.isEmpty) {
    as = 0.55; // 缺一方信息：不给满分，也不当作反证
  } else {
    as = TextUtil.bestArtistSimilarity(a, b);
    if (as < 0.50) return OfferScore(-1, reason: '艺人对不上');
  }
  final double ds;
  if (localDuration == null || localDuration <= 0) {
    ds = 0.5;
  } else if (candidateDuration == null || candidateDuration <= 0) {
    ds = 0.4;
  } else {
    final double diff = (localDuration - candidateDuration).abs();
    if (diff > 6) {
      // 严格模式：时长是「同一录音」的硬约束，差太多一律不算同一首。
      // 宽松模式（在线匹配 / 批量兜底）：标题与艺人都高度一致时放行 ——
      // 同一首歌的现场版、合辑剪辑版、转码被截断的版本能差几十秒，卡死
      // 时长会让这类文件一首也匹配不到（实测：4:17 的《一无所有》对 5:43
      // 的专辑版差 86 秒）。此时把时长分压到最低，只靠标题 / 艺人认歌。
      if (strictDuration || ts < 0.90 || as < 0.85) {
        return OfferScore(-1, reason: '时长差超过 6 秒');
      }
      ds = 0.05;
    } else {
      ds = diff <= 2 ? 1.0 : 1.0 - (diff - 2) / 8.0;
    }
  }
  double score = 0.45 * ts + 0.25 * as + 0.25 * ds + sourceBonus(source, chinese);
  if (hasTiming) score += 0.05;
  return OfferScore(score);
}

/// 源加成：中文曲目偏国内源（LRCLIB 也小幅加分），外文曲目偏 LRCLIB。
double sourceBonus(String source, bool chinese) {
  if (source == 'lrclib') return chinese ? 0.04 : 0.06;
  if (!chinese) return 0;
  if (source == 'netease' || source == 'kugou') return 0.06;
  if (source == 'qqmusic') return 0.05;
  return 0;
}

/// 候选标题含变体词、本地标题不含 → 不是同一版本。
bool isVariant(String candidate, String local) {
  final String c = TextUtil.normCompare(candidate);
  if (c.isEmpty) return true;
  final String l = TextUtil.normCompare(local);
  for (final String w in variantWords) {
    if (c.contains(TextUtil.normCompare(w)) && !l.contains(TextUtil.normCompare(w))) {
      return true;
    }
  }
  return false;
}
