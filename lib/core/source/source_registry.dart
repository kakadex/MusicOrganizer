/// 在线源注册表（T10）—— 移植自旧 net/SourceRegistry.java。
///
/// 一處登记「有哪些源、各自能做什么、怎么搜」，聚合流程只跟这里打交道。
/// 新增一家：写一个 [TagSource] / [LyricSource] 实现 → 在下面登记一行，不用改 if-else 链。
///
/// 注意：**启用/停用**由 `Endpoints` 管（用户可在设置里单独关掉某一家），
/// **顺序**由 [SourceRank] 管（中文歌国内优先、外文歌海外优先）。
/// 这里只负责「有哪些」，且登记顺序 = [SourceRank] 的优先级顺序。
library;

import 'deezer.dart';
import 'itunes.dart';
import 'kugou.dart';
import 'kuwo.dart';
import 'lyric_kugou.dart';
import 'lyric_lrclib.dart';
import 'lyric_netease.dart';
import 'lyric_ovh.dart';
import 'lyric_qq.dart';
import 'lyric_source.dart';
import 'migu.dart';
import 'musicbrainz.dart';
import 'netease.dart';
import 'qqmusic.dart';
import 'tag_source.dart';

/// 源注册表。
abstract final class SourceRegistry {
  /// 标签源 8 家；顺序与 [SourceRank] 一致（国内五家在前）。
  static final Map<String, TagSource> _byKey = <String, TagSource>{
    'netease': NeteaseSource(),
    'qqmusic': QqMusicSource(),
    'kugou': KugouSource(),
    'kuwo': KuwoSource(),
    'migu': MiguSource(),
    'musicbrainz': MusicBrainzSource(),
    'deezer': DeezerSource(),
    'itunes': ItunesSource(),
  };

  /// 歌词源 5 家：LRCLIB（外文主力）/ 网易云 / QQ / lyrics.ovh / 酷狗（KRC 逐字）。
  static final Map<String, LyricSource> _lyrics = <String, LyricSource>{
    'lrclib': LrclibSource(),
    'lyric_netease': NeteaseLyricSource(),
    'lyric_qq': QqLyricSource(),
    'lyric_ovh': OvhLyricSource(),
    'lyric_kugou': KugouLyricSource(),
  };

  /// 按 key 取标签源；没有返回 null。
  static TagSource? get(String? key) => key == null ? null : _byKey[key];

  /// 已登记的全部标签源 key（顺序 = 登记顺序）。
  static List<String> keys() => _byKey.keys.toList();

  /// 全部标签源，供设置页展示「哪些源支持歌词 / 封面」。
  static List<TagSource> all() => _byKey.values.toList();

  static bool supportsLyrics(String key) => get(key)?.supportsLyrics ?? false;

  static bool supportsCover(String key) => get(key)?.supportsCover ?? false;

  /// 按 key 取歌词源；没有返回 null。
  static LyricSource? lyric(String? key) => key == null ? null : _lyrics[key];

  /// 已启用的歌词源（按登记顺序）；[only] 用于只问指定几家。
  static List<LyricSource> lyrics({Iterable<String>? only}) {
    if (only == null) return _lyrics.values.toList();
    final List<LyricSource> out = <LyricSource>[];
    for (final String k in only) {
      final LyricSource? s = _lyrics[k];
      if (s != null) out.add(s);
    }
    return out;
  }

  /// 已登记的歌词源 key。
  static List<String> lyricKeys() => _lyrics.keys.toList();
}
