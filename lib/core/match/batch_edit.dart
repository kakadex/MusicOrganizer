/// 批量编辑：给多首歌一次性设同一批字段。
///
/// 与「在线匹配」的区别：匹配是**逐首取不同值**，批量编辑是**人为指定同一值**
/// （整张专辑统一专辑名、统一流派、从 1 开始重排音轨号）。
/// 纯逻辑（不碰盘），写盘仍走事务层。
library;

import '../tag/tag_io.dart';
import '../model/vfile.dart';

/// 一次批量编辑的规格：只含「用户填了值」的字段。
class BatchEditSpec {
  /// 字段 → 新值（不含 track，音轨单独处理；空串表示清除该字段）。
  final Map<String, String> values = <String, String>{};

  /// 是否把音轨号按文件顺序重排。
  bool renumberTrack = false;

  /// 音轨起始编号（一般从 1 开始；多碟专辑第二碟可能从 11 开始）。
  int trackStart = 1;

  /// 可批量编辑的字段（顺序即界面上的顺序）。
  static const List<String> fields = <String>[
    'title', 'artist', 'album', 'genre', 'year', 'comment',
  ];

  bool get isEmpty => values.isEmpty && !renumberTrack;

  /// 一句话描述（确认框与结果提示用）。
  String summary() {
    if (isEmpty) return '没有要修改的字段';
    final StringBuffer sb = StringBuffer();
    for (final MapEntry<String, String> e in values.entries) {
      if (sb.isNotEmpty) sb.write('，');
      sb.write('${_label(e.key)} → ${e.value.isEmpty ? '（清空）' : e.value}');
    }
    if (renumberTrack) {
      if (sb.isNotEmpty) sb.write('，');
      sb.write('音轨号按顺序重排（从 $trackStart 开始）');
    }
    return sb.toString();
  }

  /// 第 [index] 个文件要写入的字段（0 起；决定音轨号）。
  Map<String, String> updatesFor(int index) {
    final Map<String, String> out = <String, String>{};
    for (final MapEntry<String, String> e in values.entries) {
      out[e.key] = e.value;
    }
    if (renumberTrack) {
      out['track'] = '${trackStart + index}';
    }
    return out;
  }

  /// 能被批量编辑的文件数（只算可写标签的格式）。
  static int editableCount(List<VFile> files) {
    int n = 0;
    for (final VFile f in files) {
      if (!f.dir && TagIO.canWrite(f.ext())) n++;
    }
    return n;
  }

  static String _label(String key) {
    switch (key) {
      case 'title':
        return '标题';
      case 'artist':
        return '艺人';
      case 'album':
        return '专辑';
      case 'genre':
        return '流派';
      case 'year':
        return '年份';
      case 'comment':
        return '注释';
      default:
        return key;
    }
  }
}
