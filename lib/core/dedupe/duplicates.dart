/// 文件名查重 —— 移植自旧 core/Duplicates.java（纯逻辑部分）。
///
/// 判定口径（与旧版一致，别改）：
/// 1. 归一后整串相同直接并组（只差「(1)」「副本」这类尾巴的就是复制件）；
/// 2. 其余按 bigram 倒排取候选，用 [TextUtil.smartSimilarity] 同时比「整串」与
///    「只留歌名」两路：只看整串时「歌手-歌名」与「歌名」长度差太多，相似度到
///    不了门槛，等于「写了歌手就查不出重复」；
/// 3. 歌名一致时再比艺人：两边都解析得出且明显不同，视为翻唱 / 同名不同曲；
/// 4. 拿不准的一律标 [DuplicateGroup.suspect]，界面据此默认不勾选。
/// 不并入内容哈希链路：[DuplicateGroup.content] 恒为 [DuplicateGroup.contentUnknown]。
library;

import 'dart:math' as math;

import '../match/text_util.dart';
import '../model/duplicate_group.dart';
import '../model/vfile.dart';

abstract final class Duplicates {
  /// 成组相似度门槛：达到它才算「像同一首」。
  static const double similarityThreshold = 0.90;
  /// 两个艺人名算同一个人的门槛；低于它视为不同歌手（含翻唱）。
  static const double artistSame = 0.80;
  /// 整串比较前的长度比门槛：[find] 的 `threshold` 默认值即此（标题比较不走）。
  static const double minLenRatio = 0.58;
  /// 单个文件最多比较多少个候选 / 单个 bigram 最多取多少倒排项。
  static const int maxPerFile = 500;
  static const int maxPosting = 400;
  /// 占位艺人：等于没写，不能当成一个人去比对。
  static const Set<String> _placeholders = <String>{
    '群星', '合辑', '未知', '未知艺人', '佚名', '未识别',
    'various', 'variousartists', 'unknown', 'unknownartist', 'va', 'ost',
  };
  /// 查找相似文件名分组。
  ///
  /// [threshold] 是**整串比较前的长度比门槛**，不是相似度门槛（后者固定为
  /// [similarityThreshold]）。[durationOf] 返回时长（秒），读不到返回 0 或省略；
  /// 只在名字证据不足或靠包含度命中时调用，调用方应自行缓存。艺人只从文件名解析
  /// （本模块不读标签），解析不出就当信息不全，交给时长复核。
  static List<DuplicateGroup> find(List<VFile> files,
      {double threshold = minLenRatio, double Function(VFile)? durationOf}) {
    final List<VFile> audio = <VFile>[];
    for (final VFile f in files) {
      if (!f.dir && f.audio()) audio.add(f);
    }
    final int total = audio.length;
    if (total == 0) return <DuplicateGroup>[];
    final List<String> keys = List<String>.filled(total, '');
    final List<String> titles = List<String>.filled(total, '');
    final List<String> artists = List<String>.filled(total, '');
    for (int i = 0; i < total; i++) {
      keys[i] = DuplicateGroup.normalizeDuplicateKey(audio[i].stem());
      titles[i] = DuplicateGroup.titleKeyOf(audio[i].stem());
      artists[i] = DuplicateGroup.artistKeyOf(audio[i].stem());
    }
    final _UnionFind uf = _UnionFind(total);
    // 归一后整串相同：先并组，后面不必再两两算相似度。
    final Map<String, List<int>> byKey = <String, List<int>>{};
    for (int i = 0; i < total; i++) {
      if (keys[i].isEmpty) continue;
      byKey.putIfAbsent(keys[i], () => <int>[]).add(i);
    }
    for (final List<int> list in byKey.values) {
      for (int j = 1; j < list.length; j++) {
        uf.union(list[0], list[j]);
      }
    }
    // bigram 倒排：只和共享至少一个二字组的文件比，避免 O(n²)。
    final Map<String, List<int>> inverted = <String, List<int>>{};
    for (int i = 0; i < total; i++) {
      if (keys[i].length < 2) continue;
      for (final String gram in _bigrams(keys[i])) {
        inverted.putIfAbsent(gram, () => <int>[]).add(i);
      }
    }
    final Set<int> compared = <int>{};
    final List<bool> unsure = List<bool>.filled(total, false);
    final Map<String, double> durCache = <String, double>{};
    for (int i = 0; i < total; i++) {
      if (keys[i].length < 2) continue;
      final Set<int> candidates = <int>{};
      for (final String gram in _bigrams(keys[i])) {
        candidates.addAll((inverted[gram] ?? const <int>[]).take(maxPosting));
      }
      final List<int> sorted = candidates.toList()..sort();
      int count = 0;
      for (final int other in sorted) {
        if (other == i) continue;
        final int pair = i < other ? i * total + other : other * total + i;
        if (!compared.add(pair)) continue;
        final String otherKey = keys[other];
        if (otherKey.isEmpty) continue;
        final String t1 = titles[i];
        final String t2 = titles[other];
        final bool bothTitles = t1.isNotEmpty && t2.isNotEmpty;
        bool matched;
        bool containsDriven = false;
        // 名字证据「强」：整串相同（复制尾巴）或歌名一致（只差歌手前缀）。
        bool strongName = false;
        // 艺人信息不全时名字不足以定论，必须靠时长。
        bool needDuration = false;
        if (keys[i] == otherKey) {
          matched = true;
          strongName = true;
        } else if (bothTitles && t1 == t2) {
          final String a1 = _artistOf(artists[i]);
          final String a2 = _artistOf(artists[other]);
          if (a1.isNotEmpty && a2.isNotEmpty) {
            matched = TextUtil.smartSimilarity(a1, a2) >= artistSame;
            strongName = matched;
          } else {
            matched = true;
            strongName = true;
            needDuration = true;
          }
        } else {
          double fullScore = 0;
          if (_lengthGateOk(keys[i], otherKey, threshold)) {
            fullScore = TextUtil.smartSimilarity(keys[i], otherKey);
          }
          final double titleScore =
              bothTitles ? TextUtil.smartSimilarity(t1, t2) : 0;
          matched = math.max(fullScore, titleScore) >= similarityThreshold;
          if (matched) {
            // 哪一路分数高就按哪一路的包含度判定「证据是不是只靠包含度」
            containsDriven = (titleScore >= fullScore
                    ? TextUtil.containsSimilarity(t1, t2)
                    : TextUtil.containsSimilarity(keys[i], otherKey)) >=
                similarityThreshold;
          }
        }
        if (matched && (strongName || containsDriven || needDuration)) {
          // 同名同大小基本就是一份副本，不做 IO；其余都要拿时长复核：
          // 「歌名 (1)」完全可能是「前后各切掉一段」的剪辑版。
          final bool identicalCopy = strongName &&
              !needDuration &&
              audio[i].stem() == audio[other].stem() &&
              audio[i].size == audio[other].size;
          if (!identicalCopy) {
            final double d1 = _duration(durationOf, durCache, audio[i]);
            final double d2 = _duration(durationOf, durCache, audio[other]);
            if (d1 > 0 && d2 > 0) {
              final double tol = math.max(3.0, math.max(d1, d2) * 0.02);
              if ((d1 - d2).abs() > tol) {
                if (needDuration) {
                  matched = false; // 艺人信息不全、长度又不同 → 多半是翻唱
                } else if (strongName) {
                  unsure[i] = true; // 名字像但时长差很多：剪辑版，标疑似
                  unsure[other] = true;
                } else {
                  matched = false;
                }
              }
            } else {
              unsure[i] = true; // 读不到时长：列出来但不敢默认勾选
              unsure[other] = true;
            }
          }
        }
        if (matched) uf.union(i, other);
        if (++count >= maxPerFile) break;
      }
    }
    final Map<int, DuplicateGroup> clusters = <int, DuplicateGroup>{};
    for (int i = 0; i < total; i++) {
      final DuplicateGroup group =
          clusters.putIfAbsent(uf.find(i), () => DuplicateGroup(keys[i]));
      final VFile f = audio[i];
      group.files.add(DuplicateItem(f, f.pathAfterRoot(), f.size, null));
      if (unsure[i]) group.suspect = true;
    }
    final List<DuplicateGroup> out = <DuplicateGroup>[];
    for (final DuplicateGroup group in clusters.values) {
      if (group.files.length < 2) continue;
      for (final DuplicateItem it in group.files) {
        if (it.duration != null && it.duration! > 0) continue;
        final double d = _duration(durationOf, durCache, it.file);
        if (d > 0) it.duration = d;
      }
      group.score = _groupScore(group);
      // 相似度没到「确证」档的也标疑似：0.90~0.95 之间确实可能是不同版本
      group.suspect = group.suspect || group.score < DuplicateGroup.highConfidence;
      out.add(group);
    }
    // 稳定排序：文件多的在前，其次省得多，最后按名字，界面顺序不会每次乱跳
    out.sort((DuplicateGroup a, DuplicateGroup b) {
      final int byCount = b.files.length - a.files.length;
      if (byCount != 0) return byCount;
      final int w = b.wastedBytes() - a.wastedBytes();
      return w != 0 ? w : a.key.compareTo(b.key);
    });
    return out;
  }
  /// 组内最高相似度（组一般只有两三个文件，两两比较代价可忽略）。
  static double _groupScore(DuplicateGroup group) {
    double best = 0;
    for (int i = 0; i < group.files.length; i++) {
      final VFile fa = group.files[i].file;
      final String a = DuplicateGroup.normalizeDuplicateKey(fa.stem());
      final String ta = DuplicateGroup.titleKeyOf(fa.stem());
      for (int j = i + 1; j < group.files.length; j++) {
        final VFile fb = group.files[j].file;
        final String b = DuplicateGroup.normalizeDuplicateKey(fb.stem());
        final String tb = DuplicateGroup.titleKeyOf(fb.stem());
        if (a == b) return 1.0;
        // 只差艺人前缀按确证算；但两边艺人明确不同（翻唱 / 重名）不按确证
        if (ta.isNotEmpty && ta == tb) {
          final String aa = DuplicateGroup.artistKeyOf(fa.stem());
          final String ab = DuplicateGroup.artistKeyOf(fb.stem());
          final bool both = aa.isNotEmpty && ab.isNotEmpty;
          if (!both || TextUtil.smartSimilarity(aa, ab) >= artistSame) return 1.0;
        }
        final double s = math.max(TextUtil.smartSimilarity(a, b),
            TextUtil.smartSimilarity(ta, tb));
        if (s > best) best = s;
      }
    }
    return best;
  }
  static String _artistOf(String key) => _placeholders.contains(key) ? '' : key;
  static bool _lengthGateOk(String a, String b, double threshold) {
    final int min = math.min(a.length, b.length), max = math.max(a.length, b.length);
    return min > 0 && min / max >= threshold;
  }
  static Set<String> _bigrams(String text) {
    if (text.length < 2) return <String>{text};
    return <String>{
      for (int i = 0; i + 2 <= text.length; i++) text.substring(i, i + 2),
    };
  }
  /// 取时长（带缓存）；来源为 null 或读失败都按「未知」返回 0。
  static double _duration(
      double Function(VFile)? src, Map<String, double> cache, VFile file) {
    if (src == null) return 0;
    final String key = file.docId.isEmpty ? file.name : file.docId;
    final double? cached = cache[key];
    if (cached != null) return cached;
    double value = 0;
    try {
      value = src(file);
    } catch (_) {
      value = 0;
    }
    if (value.isNaN || value < 0) value = 0;
    cache[key] = value;
    return value;
  }
}
/// 并查集：只需合并与查根。
class _UnionFind {
  _UnionFind(int size) : _parent = List<int>.generate(size, (int i) => i);
  final List<int> _parent;
  int find(int x) => _parent[x] == x ? x : (_parent[x] = find(_parent[x]));

  void union(int a, int b) {
    final int ra = find(a);
    final int rb = find(b);
    if (ra != rb) _parent[rb] = ra;
  }
}
