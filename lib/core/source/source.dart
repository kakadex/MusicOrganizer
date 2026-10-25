/// 数据源层（T10 落位）：端点注册表 + 8 标签源 + 5 歌词源 + 聚合。
///
/// - `endpoints.dart`：地址覆盖 / 启用开关（SharedPreferences 持久化，
///   「接口挂掉不用等发版」）；
/// - 标签源 8 家：MusicBrainz（锚点）/ Deezer / iTunes / 网易 / QQ /
///   酷狗 / 酷我 / 咪咕，统一抽象 `TagSource{key,label,fetch,healthy}`；
/// - 歌词源 5 家：LRCLIB / 网易云 / QQ / lyrics.ovh / 酷狗（KRC）；
/// - `aggregator.dart`：源级并发 + 去重截断（MAX 10）+ 时长容差 3s；
/// - `offer_score.dart`：**唯一取舍点**（标题 ≥0.60 / 艺人 ≥0.50 /
///   时长差 ≤6s + 变体词过滤 + 国内源基础分）；
/// - `source_rank.dart`：中文国内优先 0.30 宽容带。
library;
