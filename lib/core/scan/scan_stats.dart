/// 扫描统计（纯数据，可离线单测）。
library;

/// 扫描统计。
class ScanStats {
  /// 音频文件总数（含已归位 / 未识别里的），即「曲目数」。
  int audio = 0;

  /// 歌词文件数。
  int lyrics = 0;

  /// 待整理的音频文件数。
  int files = 0;
  int groups = 0;
  int skippedArtist = 0;
  int skippedUnrecognized = 0;
  int ignored = 0;

  String summary() {
    final StringBuffer sb = StringBuffer();
    if (audio > 0 || lyrics > 0) {
      sb.write('曲目 $audio 首');
      if (lyrics > 0) sb.write(' · 歌词 $lyrics 个');
    } else {
      sb.write('共 $files 个文件');
    }
    sb.write(' · 待整理 $files 个文件 / $groups 组');
    sb.write('；跳过已归位 $skippedArtist，跳过未识别 $skippedUnrecognized，忽略非音乐 $ignored');
    return sb.toString();
  }
}
