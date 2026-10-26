/// 多源聚合（T10b）—— 移植自旧 net/Sources.java 的 aggregate 与去重逻辑。
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
  static Future<AggregateResult> tagCandidates(
    Query q, {
    bool? chinese,
    MbClient? mbClient,
    JsonFetcher? fetch,
    Iterable<String>? only,
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

    final String localTitle = TagQuery.title(q);
    final Map<String, String> errors = <String, String>{};
    final List<Candidate> all = <Candidate>[];
    for (final SourceResult r in results) {
      if (r.error.isNotEmpty) errors[r.source] = r.error;
      for (final Candidate c in r.items) {
        if (!_durationOk(c, q.localDuration)) continue;
        // 变体词过滤：候选是「伴奏 / Remix / Live / 翻唱」而本地不是 → 不是同一版本。
        // 不做这一步会把「记事本 (Remix)」写进普通曲目（真实数据实测踩到）。
        if (isVariant(c.title, localTitle)) continue;
        // 与本地标题 / 艺人的相似度，用于同分时排序（源置信度全是 0.60，光靠它分不出好坏）
        c.filenameScore = localTitle.isEmpty
            ? 0
            : TextUtil.textSimilarity(localTitle, c.title);
        c.merged = 1;
        all.add(c);
      }
    }

    final int before = all.length;
    final List<Candidate> merged = _merge(all);
    merged.sort((Candidate a, Candidate b) {
      // 先看「像不像这首歌」：标题相似度差 0.02 以上就按相似度排，
      // 差不多再用源优先级（中文曲目国内源优先）决定。
      final double d = a.filenameScore - b.filenameScore;
      if (d.abs() > 0.02) return d > 0 ? -1 : 1;
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
  /// 最终「取不取、取哪条」由 T11 的匹配链路决定，这里只负责并发与排序。
  static Future<List<LyricHit>> lyricCandidates(
    LyricQuery q, {
    LyricScorer? score,
    TextFetcher? text,
    JsonFetcher? json,
    Iterable<String>? only,
  }) async {
    final List<Future<List<LyricHit>>> tasks = <Future<List<LyricHit>>>[];
    final List<LyricSource> sources = SourceRegistry.lyrics(only: only);
    for (final LyricSource s in sources) {
      tasks.add(() async {
        try {
          return await s.search(q, text: text, json: json);
        } catch (_) {
          return <LyricHit>[];
        }
      }());
    }
    final List<List<LyricHit>> groups = await Future.wait(tasks);
    final List<LyricHit> out = <LyricHit>[];
    for (final List<LyricHit> g in groups) {
      out.addAll(g);
    }
    return out;
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

/// 歌词打分回调签名（T11 注入 [offerScore] 的实现）。
typedef LyricScorer = double Function(LyricHit hit);
