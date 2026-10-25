/// 在线源注册表（T10a）—— 移植自旧 net/SourceRegistry.java。
///
/// 一处登记「有哪些源、各自能做什么」，聚合流程只跟这里打交道。
/// 新增一家：写一个 [TagSource] 实现 → 在下面登记一行，不用再改 if-else 链。
///
/// 注意：**启用/停用**由 `Endpoints` 管（用户可在设置里单独关掉某一家），
/// **顺序**由 [SourceRank] 管（中文歌国内优先）。这里只负责「有哪些」。
library;

import 'deezer.dart';
import 'itunes.dart';
import 'tag_source.dart';

/// 源注册表。
abstract final class SourceRegistry {
  static final Map<String, TagSource> _byKey = <String, TagSource>{
    'deezer': DeezerSource(),
    'itunes': ItunesSource(),
    // TODO(T10b)：musicbrainz（需要 MbClient 票约客户端）+ 国内五家
    // （netease / qqmusic / kugou / kuwo / migu）逐个补齐后登记到这里。
  };

  /// 按 key 取源；没有返回 null。
  static TagSource? get(String? key) => key == null ? null : _byKey[key];

  /// 已登记的全部 key（顺序 = 登记顺序）。
  static List<String> keys() => _byKey.keys.toList();

  /// 全部源，供设置页展示「哪些源支持歌词 / 封面」。
  static List<TagSource> all() => _byKey.values.toList();

  static bool supportsLyrics(String key) => get(key)?.supportsLyrics ?? false;

  static bool supportsCover(String key) => get(key)?.supportsCover ?? false;
}
