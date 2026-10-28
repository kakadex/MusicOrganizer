/// 在线标签候选 的 Candidate。
///
/// 各数据源字段不同，在这里抹平成统一结构。
class Candidate {
  String title = '';
  String artist = '';
  String album = '';
  String year = '';
  String track = '';
  String genre = '';

  /// 秒；读不到为 null。
  double? duration;

  String source = '';

  /// 专辑封面地址（可能为空；封面补全用，标签写入不关心）。
  String coverUrl = '';

  double confidence = 0;

  /// 候选与文件名解析结果的相似度（0~1；没有文件名线索为 -1）。
  double filenameScore = 0;

  /// 与本地曲目的综合匹配分（`offerScore`：标题 / 艺人 / 时长 / 源加成）。
  ///
  /// 负数不会出现在结果里（已被淘汰）。标签候选过去只看各源自报的
  /// [confidence]，同名垃圾条目（歌手 `yyyyyy` 之类）靠标题一致就能排在
  /// 第一；现在用它来筛和排序。
  double matchScore = 0;

  /// 合并后命中几源（1 = 只有一家给出这条）。
  int merged = 1;

  /// 合并后命中的来源，如「网易云 / QQ」。
  String sources = '';
}
