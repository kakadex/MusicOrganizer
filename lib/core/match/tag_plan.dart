/// 写入前预览计划：把「候选」变成逐文件、逐字段的变更，供用户确认。
///
/// **为什么必须先预览再写盘**：在线结果来自多家源，字段口径不一、置信度参差，
/// 直接落盘会把用户整理好的标签改坏，且只能靠 journal 事后回滚。
/// 这里把候选折算成「逐文件、逐字段的旧值 → 新值」清单交给界面：
/// 用户逐字段勾选（[PlanField.accepted]）、整首取舍（[FilePlan.selected]），
/// 低置信的标出来（[FilePlan.lowConfidence]），确认后才交给
/// `TagTransaction.apply` 落盘。
///
/// 本文件不读盘、不联网、不打日志 —— 全部是纯函数，便于离线回归。
library;

import '../model/candidate.dart';
import '../model/tags.dart';
import '../model/vfile.dart';
import '../source/source_rank.dart';
import 'artist_rules.dart';
import 'tag_fill.dart';

/// 单个字段的变更计划（界面对应一行「旧值 → 新值」）。
class PlanField {
  PlanField({
    required this.key,
    required this.oldValue,
    required this.newValue,
    required this.mode,
  });

  /// 字段名（取值见 [TagFill.candidateFields]）。
  final String key;

  /// 当前值（已去首尾空白；原来没有就是空串）。
  final String oldValue;

  /// 候选值（非空，[TagFill.diff] 已过滤空值）。
  final String newValue;

  /// 采用的策略：[TagFill.supplement] / [TagFill.overwrite]。
  final int mode;

  /// 是否勾选写入；界面可取消勾选，取消后不进 [FilePlan.toUpdates]。
  bool accepted = true;

  /// 值与原来不同。
  bool get changed => oldValue != newValue;

  /// 字段中文名（界面列头）。
  String get label => TagFill.label(key);

  /// 策略中文名（界面提示「只补空 / 覆盖」）。
  String get modeLabel => TagFill.modeName(mode);

  @override
  String toString() => '$label：$oldValue → $newValue';
}

/// 单个文件的写入计划（界面对应一张可折叠卡片）。
class FilePlan {
  FilePlan({
    required this.file,
    this.candidate,
    List<PlanField>? fields,
    this.note = '',
    this.lowConfidence = false,
  }) : fields = fields ?? <PlanField>[];

  final VFile file;

  /// 命中的候选；null 表示这一首没匹配上（[note] 为「无候选」）。
  final Candidate? candidate;

  /// 逐字段变更；顺序与 [TagFill.candidateFields] 一致。
  final List<PlanField> fields;

  /// 计划说明，如「3 家一致：网易云 / QQ 音乐」「低置信，建议人工确认」。
  String note;

  /// 命中置信度低于 [TagPlan.lowConfidenceThreshold]。
  final bool lowConfidence;

  /// 整首是否参与写入；整首取消勾选后不进 [TagPlan.onlySelected]。
  bool selected = true;

  /// 是否至少有一行已勾选且真变了。
  bool get hasChange => fields.any((PlanField f) => f.accepted && f.changed);

  /// 导出要交给 `TagTransaction.apply` 的字段更新；只含已勾选且真变了的。
  Map<String, String> toUpdates() {
    final Map<String, String> out = <String, String>{};
    for (final PlanField f in fields) {
      if (f.accepted && f.changed) out[f.key] = f.newValue;
    }
    return out;
  }

  @override
  String toString() => '${file.name}：${TagFill.describe(toUpdates())}';
}

/// 批量匹配的写入前预览计划生成器（纯 Dart）。
abstract final class TagPlan {
  /// 置信度低于它的命中标记为 [FilePlan.lowConfidence]，提示人工确认。
  static double lowConfidenceThreshold = 0.5;

  /// 单文件计划：用 [TagFill.diff] 算变更，命中为空或没有变更时给空计划。
  static FilePlan buildFor({
    required VFile file,
    Tags? before,
    Candidate? candidate,
    Map<String, int>? modes,
    bool overwrite = false,
  }) {
    final Map<String, int> m = modes ?? TagFill.defaultModes(overwrite);
    final Map<String, String> diff = TagFill.diff(
      before?.toMap(),
      candidate == null ? null : _values(candidate),
      modes: m,
    );

    final List<PlanField> fields = <PlanField>[];
    for (final String key in TagFill.candidateFields) {
      final String? newValue = diff[key];
      if (newValue == null) continue;
      final String oldValue =
          before == null ? '' : before.get(key).trim();
      fields.add(
        PlanField(
          key: key,
          oldValue: oldValue,
          newValue: newValue,
          mode: TagFill.modeOf(m, key),
        ),
      );
    }

    return FilePlan(
      file: file,
      candidate: candidate,
      fields: fields,
      note: _note(candidate),
      lowConfidence: _isLow(candidate),
    );
  }

  /// 批量构建；[chosen] 里没有的文件给「无候选」的空计划。
  static List<FilePlan> build({
    required List<VFile> files,
    required Map<String, Tags> before,
    required Map<String, Candidate> chosen,
    Map<String, int>? modes,
    bool overwrite = false,
  }) {
    final List<FilePlan> out = <FilePlan>[];
    for (final VFile f in files) {
      out.add(
        buildFor(
          file: f,
          before: before[f.docId],
          candidate: chosen[f.docId],
          modes: modes,
          overwrite: overwrite,
        ),
      );
    }
    return out;
  }

  /// 一行汇总：「共 120 首，待写入 87 首，低置信 12 首，无变更 33 首」。
  ///
  /// 待写入按 [FilePlan.hasChange] 计数；无变更 = 总数 - 待写入。
  static String summarize(List<FilePlan> plans) {
    int pending = 0;
    int low = 0;
    for (final FilePlan p in plans) {
      if (!p.hasChange) continue;
      pending++;
      if (p.lowConfidence) low++;
    }
    final int noChange = plans.length - pending;
    return '共 ${plans.length} 首，'
        '待写入 $pending 首，'
        '低置信 $low 首，'
        '无变更 $noChange 首';
  }

  /// 过滤出整首勾选且有变更的，交给写入队列。
  static List<FilePlan> onlySelected(List<FilePlan> plans) =>
      plans.where((FilePlan p) => p.selected && p.hasChange).toList();

  /// 候选字段 → Map（[TagFill.diff] 的入参形状）。
  static Map<String, String> _values(Candidate c) => <String, String>{
        'title': c.title,
        // 兜底：聚合阶段已按「噪声歌手」淘汰过，这里再挡一次 —— 宁可少写一个
        // 字段，也不把 `yyyyyy` 这种名字写进用户的曲库
        'artist': ArtistRules.looksLikeNoise(c.artist) ? '' : c.artist,
        'album': c.album,
        'year': c.year,
        'track': c.track,
        'genre': c.genre,
      };

  static bool _isLow(Candidate? c) =>
      c != null && c.confidence < lowConfidenceThreshold;

  /// 计划说明：命中家数 / 来源名，低置信再追加提示。
  static String _note(Candidate? c) {
    if (c == null) return '无候选';
    final StringBuffer sb = StringBuffer();
    if (c.merged > 1) {
      sb.write('${c.merged} 家一致');
      final String names = c.sources.trim();
      if (names.isNotEmpty) sb.write('：$names');
    } else {
      final String name = SourceRank.label(c.source).trim();
      sb.write(name.isEmpty ? '来源未知' : '来源：$name');
    }
    if (_isLow(c)) {
      if (sb.isNotEmpty) sb.write('；');
      sb.write('低置信，建议人工确认');
    }
    return sb.toString();
  }
}
