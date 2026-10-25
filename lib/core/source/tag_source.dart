/// 在线标签源的统一契约（T10a）—— 移植自旧 net/OnlineSource.java。
///
/// 以前所有源都挤在一个类的 if-else 里：加一家要改多处、还说不清
/// 「这家支不支持歌词 / 封面」。现在一个源一个实现 + 注册表，
/// 新增源只写一个类并登记一行，聚合流程不用动。
///
/// 能力位（tags / lyrics / cover）只是**声明**，用于界面提示与按能力挑选。
library;

import '../model/candidate.dart';
import '../model/query.dart';
import '../match/name_weight.dart';
import '../match/text_util.dart';
import '../lyrics/zh.dart';

/// 取 JSON 的回调；可注入（测试与桌面/移动端共用）。
typedef JsonFetcher = Future<Object?> Function(String url, Map<String, String>? params);

/// 一个在线标签源。
abstract class TagSource {
  /// 与 [Endpoints] 里登记的 key 一致（如 `deezer`）。
  String get key;

  /// 界面上显示的名字。
  String get label;

  bool get supportsTags;

  bool get supportsLyrics;

  bool get supportsCover;

  /// 按查询上下文搜一遍；查不到返回空列表（不允许返回 null）。
  Future<List<Candidate>> search(Query q, {JsonFetcher? fetch});
}

/// 从查询上下文里取检索用的标题 / 艺人 —— 移植自旧 net/Sources.java。
///
/// 文件名解析结果与已有标签按 [Query.filenameWeight] 取舍：权重高更信文件名，
/// 权重低更信内嵌标签。所有源必须用同一套取值口径，否则同一首歌在不同源会搜出不同结果。
abstract final class TagQuery {
  static List<String> _firstPair(Query ctx) {
    final List<List<String>> cands = ctx.filenameCandidates;
    if (cands.isEmpty) return <String>['', ''];
    final List<String> p = cands[0];
    return <String>[
      p.isNotEmpty ? p[0] : '',
      p.length > 1 ? p[1] : '',
    ];
  }

  static String title(Query ctx) {
    final List<String> p = _firstPair(ctx);
    return NameWeight.pick(p[1].trim(), ctx.embeddedTags['title'], ctx.filenameWeight);
  }

  static String artist(Query ctx) {
    final List<String> p = _firstPair(ctx);
    return NameWeight.pick(p[0].trim(), ctx.embeddedTags['artist'], ctx.filenameWeight);
  }

  /// 检索串：艺人 + 标题（海外站都吃这种组合）。
  static String term(Query ctx) => '${artist(ctx)} ${title(ctx)}'.trim();

  /// 文本是否「像中文曲目」：含汉字且不像日文（假名优先判定为日文）。
  static bool hasHan(String? s) {
    if (s == null || s.isEmpty) return false;
    return TextUtil.containsChinese(s) && !Zh.isJapanese(s);
  }

  /// 这次查询的曲目是否中文（标题或艺人任一方含汉字且非日文）。
  static bool isChineseTrack(Query ctx) => hasHan(title(ctx)) || hasHan(artist(ctx));
}

/// JSON 取值小工具（各源字段形状不一，这里统一容错）。
abstract final class JsonPick {
  static String str(Object? container, String key) {
    if (container is Map) {
      final Object? v = container[key];
      if (v is String) return v;
      if (v is num) return v.toString();
    }
    return '';
  }

  static Map<dynamic, dynamic>? map(Object? container, String key) {
    if (container is Map && container[key] is Map) return container[key] as Map;
    return null;
  }

  static List<dynamic> list(Object? container, String key) {
    if (container is Map && container[key] is List) {
      return container[key] as List<dynamic>;
    }
    return const <dynamic>[];
  }

  /// 取第一个非空值。
  static String firstNonEmpty(String a, String b) => a.isNotEmpty ? a : b;

  /// 毫秒时间戳 → 四位年份；0 或异常值返回空串。
  static String yearOfMillis(int millis) {
    if (millis <= 0) return '';
    final DateTime t = DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
    if (t.year < 1900 || t.year > 2200) return '';
    return '${t.year}';
  }

  /// 取前四位年份（如 `2020-05-01` → `2020`）。
  static String yearOf(String? date) {
    if (date == null || date.length < 4) return '';
    return date.substring(0, 4);
  }
}
