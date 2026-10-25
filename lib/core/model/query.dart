/// 查询上下文 —— 移植自旧 net/Sources.java 的 Query。
library;

import '../match/name_weight.dart';

/// 一次「按文件查标签 / 歌词」的查询上下文。
class Query {
  /// 文件名解析出的 (artist, title) 候选对。
  List<List<String>> filenameCandidates = <List<String>>[];

  /// 已有内嵌标签。
  Map<String, String> embeddedTags = <String, String>{};

  /// 本地读到的时长（秒）；读不到为 null。
  double? localDuration;

  /// 是否启用国内召回源。
  bool useCnSources = true;

  /// 文件名权重 0~1：越高越信文件名解析结果，越低越信已有标签。
  double filenameWeight =
      NameWeight.fromPercent(NameWeight.defaultPercent);
}
