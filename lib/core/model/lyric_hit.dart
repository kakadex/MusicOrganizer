/// 统一歌词候选 的 Hit。
///
/// 各源字段不同，在这里抹平。
class LyricHit {
  String source = '';
  String title = '';
  String artist = '';

  /// 秒；读不到为 null。
  double? duration;

  /// 带时间轴的 LRC。
  String synced = '';

  /// 只有文本、没有时间轴。
  String plain = '';

  /// 译文轨（网易 tlyric / QQ trans），与 synced 同一套时间点，可能为空。
  String translation = '';

  bool hasLyrics() => synced.isNotEmpty || plain.isNotEmpty;

  /// 源的中文名。
  static String label(String source) {
    if (source == 'netease') return '网易云';
    if (source == 'qqmusic') return 'QQ 音乐';
    if (source == 'lyricsovh') return 'lyrics.ovh';
    if (source == 'kugou') return '酷狗';
    return source;
  }
}
