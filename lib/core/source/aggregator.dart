/// 多源聚合：源级并发 → 时长交叉验证 → 去重 → 排序 → 截断。
///
/// 流程：**源级并发 → 时长交叉验证 → 多源去重 → 按 [SourceRank] 排序 → 截断**。
/// 时长容差 3 秒（超出基本可判定不是同一录音）；去重后最多留 10 条，
/// 再多用户也不会往下翻，反而拖慢渲染。
///
/// 注意顺序：**先去重、再排序**（代表条目必须是分数最高的那条，否则排序会把次优结果顶到最前）。
library;

import 'dart:async';

import '../model/candidate.dart';
import '../model/lyric_hit.dart';
import '../model/query.dart';
import '../match/artist_rules.dart';
import '../match/text_util.dart';
import 'endpoints.dart';
import 'mb_client.dart';
import 'offer_score.dart';
import 'tag_source.dart';
import 'lyric_source.dart';
import 'source_rank.dart';
import 'source_registry.dart';

/// 一个源的返回（需要知道是哪一家、有没有出错）。
class SourceResult {
  SourceResult(this.source, this.items, {this.error = ''});

  final String source;
  final List<Candidate> items;

  /// 出错原因；空串表示正常返回。
  final String error;
}

/// 聚合产出。
class AggregateResult {
  AggregateResult(this.candidates, this.errors, this.totalBeforeDedupe);

  final List<Candidate> candidates;
  /// 源 key → 错误原因。
  final Map<String, String> errors;

  /// 去重前的候选总数（日志里用来说明「合并掉多少」）。
  final int totalBeforeDedupe;
}

/// 歌词聚合产出：命中 + 每家失败原因（界面据此提示「是不是没联网」）。
class LyricAggregateResult {
  LyricAggregateResult(this.hits, this.errors);

  final List<LyricHit> hits;

  /// 源 key → 失败原因；空串条目不会出现。
  final Map<String, String> errors;
}

/// 多源聚合（纯编排，不含网络细节）。
abstract final class Aggregator {
  /// 聚合后最多返回多少条。
  static const int maxCandidates = 10;

  /// 时长容差（秒）。
  static const double durationTolerance = 3.0;

  /// 多源判同的时长容差（秒）。
  static const double mergeTolerance = 2.0;

  /// 合并两条候选的标题相似度门槛。
  static const double mergeTitleSimilarity = 0.90;

  /// 合并两条候选的艺人相似度门槛。
  static const double mergeArtistSimilarity = 0.82;

  /// 取标签候选：按 [SourceRank] 顺序并发问各家，再交叉验证 / 去重 / 截断。
  /// [verify] 为 true（默认）时按 [offerScore] 严格验证：标题 / 艺人 / 时长
  /// 任一不过就淘汰。批量写入必须用严格模式；「在线匹配」这类由用户逐条挑选的
  /// 场景可以传 false —— 只把不合格的排到后面，仍让人能选（修错标签时，本地
  /// 标签本身就是错的，严格模式会把正确答案一起筛掉）。
  static Future<AggregateResult> tagCandidates(
    Query q, {
    bool? chinese,
    MbClient? mbClient,
    JsonFetcher? fetch,
    Iterable<String>? only,
    bool verify = true,
  }) async {
    final bool isCn = chinese ?? TagQuery.isChineseTrack(q);
    final List<TagSource> sources = <TagSource>[];
    for (final String key in only ?? SourceRank.ordered(chinese: isCn)) {
      if (!Endpoints.enabled(key)) continue;
      final TagSource? s = SourceRegistry.get(key);
      if (s != null) sources.add(s);
    }
    if (sources.isEmpty) {
      return AggregateResult(<Candidate>[], <String, String>{}, 0);
    }

    final List<Future<SourceResult>> tasks = <Future<SourceResult>>[];
    for (final TagSource s in sources) {
      tasks.add(_ask(s, q, fetch));
    }
    final List<SourceResult> results = await Future.wait(tasks);

    // 文件名可能把歌手与歌名写反（「水手-郑智化」= 歌名-歌手），所以本地也有
    // 多组 (artist, title) 解释：逐个算分取最高的那组，只按第一组算会把标题
    // 当成歌手，相似度趋零，整批候选都被判低分丢掉。
    final List<List<String>> combos = TagQuery.localCombos(q);
    final Map<String, String> errors = <String, String>{};
    final List<Candidate> all = <Candidate>[];
    for (final SourceResult r in results) {
      if (r.error.isNotEmpty) errors[r.source] = r.error;
      for (final Candidate c in r.items) {
        if (!_durationOk(c, q.localDuration)) continue;
        // 歌手是 `yyyyyy` / `嘤嘤嘤` 这种用户上传的垃圾条目：标题与正版一模一样，
        // 只按标题排就会把它写进标签（真实踩到过）。这类候选一律不要。
        if (ArtistRules.looksLikeNoise(c.artist)) continue;
        // 与本地曲目的综合分：标题 / 艺人 / 时长 / 源加成走同一套口径。
        // 本地有多组解释时逐个算，取最高的那一组。
        OfferScore? best;
        String bestTitle = '';
        for (final List<String> combo in combos) {
          final String rawArtist = combo[0];
          // 群星 / 未知歌手这类占位艺人没有区分度：当作「本地没有艺人」，
          // 交给标题与时长判断，否则合辑里的歌一首也匹配不上。
          final OfferScore s = scoreDetail(
            localTitle: combo[1],
            localArtist:
                ArtistRules.isGenericArtist(rawArtist) ? '' : rawArtist,
            localDuration: q.localDuration,
            candidateTitle: c.title,
            candidateArtist: c.artist,
            candidateDuration: c.duration,
            source: r.source,
            chinese: isCn,
          );
          if (best == null || s.score > best.score) {
            best = s;
            bestTitle = combo[1];
          }
        }
        if (best == null) continue;
        // 变体词过滤：候选是「伴奏 / Remix / Live / 翻唱」而本地不是 → 不是同一版本。
        // 不做这一步会把「记事本 (Remix)」写进普通曲目（真实数据实测踩到）。
        // 用得分最高的那组标题来比，方向判错时也不会误杀。
        if (isVariant(c.title, bestTitle)) continue;
        if (verify && best.rejected) continue;
        c.matchScore = best.score;
        // 标题相似度仍留着：同分时「标题更像」优先
        c.filenameScore = bestTitle.isEmpty
            ? 0
            : TextUtil.textSimilarity(bestTitle, c.title);
        c.merged = 1;
        all.add(c);
      }
    }

    final int before = all.length;
    final List<Candidate> merged = _merge(all);
    merged.sort((Candidate a, Candidate b) {
      // 先按综合分（标题 + 艺人 + 时长）：差 0.02 以上就按分数排；
      // 分数接近再看标题谁更像，最后才用源优先级（中文曲目国内源优先）。
      final double d = a.matchScore - b.matchScore;
      if (d.abs() > 0.02) return d > 0 ? -1 : 1;
      final double t = a.filenameScore - b.filenameScore;
      if (t.abs() > 0.02) return t > 0 ? -1 : 1;
      return SourceRank.compare(
          a.source, a.confidence, b.source, b.confidence,
          chinese: isCn);
    });
    final List<Candidate> out =
        merged.length > maxCandidates ? merged.sublist(0, maxCandidates) : merged;
    return AggregateResult(out, errors, before);
  }

  /// 取歌词候选：并发问各家，返回按 [offerScore] 排好序的命中（越靠前越可信）。
  ///
  /// 最终「取不取、取哪条」由匹配链路决定，这里只负责并发与排序。
  /// 与 [tagCandidates] 一致，按 `Endpoints.enabled` 过滤被关闭的歌词源；
  /// 每家失败原因带出来，调用方若一首都没拿到，可据此判断是「真没词」还是「联网挂了」。
  static Future<LyricAggregateResult> lyricCandidates(
    LyricQuery q, {
    LyricScorer? score,
    TextFetcher? text,
    JsonFetcher? json,
    Iterable<String>? only,
  }) async {
    final List<Future<List<LyricHit>>> tasks = <Future<List<LyricHit>>>[];
    final Map<String, String> errors = <String, String>{};
    final List<LyricSource> sources = SourceRegistry.lyrics(only: only)
        .where((LyricSource s) => Endpoints.enabled(s.key))
        .toList();
    for (final LyricSource s in sources) {
      tasks.add(() async {
        try {
          return await s.search(q, text: text, json: json);
        } catch (e) {
          errors[s.key] = _short(e);
          return <LyricHit>[];
        }
      }());
    }
    final List<List<LyricHit>> groups = await Future.wait(tasks);
    final List<LyricHit> out = <LyricHit>[];
    for (final List<LyricHit> g in groups) {
      out.addAll(g);
    }
    return LyricAggregateResult(out, errors);
  }

  static Future<SourceResult> _ask(TagSource s, Query q, JsonFetcher? fetch) async {
    try {
      return SourceResult(s.key, await s.search(q, fetch: fetch));
    } catch (e) {
      return SourceResult(s.key, <Candidate>[], error: _short(e));
    }
  }

  /// 时长交叉验证：两边都读到且差超过容差 → 不是同一录音。
  static bool _durationOk(Candidate c, double? local) {
    if (local == null || local <= 0) return true;
    final double? d = c.duration;
    if (d == null || d <= 0) return true;
    return (local - d).abs() <= durationTolerance;
  }

  /// 多源去重：同一首歌在几家都返回时只留最高分那条，并记下命中了几家。
  static List<Candidate> _merge(List<Candidate> input) {
    final List<Candidate> out = <Candidate>[];
    for (final Candidate c in input) {
      int at = -1;
      for (int i = 0; i < out.length; i++) {
        if (_same(out[i], c)) {
          at = i;
          break;
        }
      }
      if (at < 0) {
        out.add(c);
        continue;
      }
      final Candidate keep = out[at];
      final int merged = keep.merged + 1;
      final List<String> names = <String>[];
      if (keep.sources.isNotEmpty) {
        names.addAll(keep.sources.split(' / '));
      } else {
        names.add(SourceRank.label(keep.source));
      }
      names.add(SourceRank.label(c.source));
      // 保留分高的那条，把「几家一致」记到它身上
      if (c.confidence > keep.confidence) {
        c.merged = merged;
        c.sources = names.join(' / ');
        out[at] = c;
      } else {
        keep.merged = merged;
        keep.sources = names.join(' / ');
      }
    }
    return out;
  }

  /// 判同：标题 + 艺人都像，且时长差在容差内（任一方缺时长时按 0 处理）。
  static bool _same(Candidate a, Candidate b) {
    if (TextUtil.textSimilarity(a.title, b.title) < mergeTitleSimilarity) {
      return false;
    }
    final String aa = TextUtil.safeStr(a.artist);
    final String ba = TextUtil.safeStr(b.artist);
    if (aa.isNotEmpty && ba.isNotEmpty) {
      if (TextUtil.bestArtistSimilarity(aa, ba) < mergeArtistSimilarity) return false;
    }
    final double ad = a.duration ?? 0;
    final double bd = b.duration ?? 0;
    if (ad > 0 && bd > 0) return (ad - bd).abs() <= mergeTolerance;
    return true;
  }

  static String _short(Object e) {
    final String s = e.toString();
    return s.length > 60 ? s.substring(0, 60) : s;
  }
}

/// 歌词打分回调签名（由调用的批量链路注入）。
typedef LyricScorer = double Function(LyricHit hit);
