/// 通用文本工具（对应 Python core.py 通用工具部分）。
///
/// 包含：繁转简（内置映射表，零外部依赖）、规范化比较、相似度、
/// 尾部污染后缀剥离、重编码标记剥离、文件名合法化、轨道前缀剥离、多艺人拆分。
library;

/// 通用文本工具（纯 Dart）。
abstract final class TextUtil {
  static const String unknownArtist = '未知歌手';
  static const String unrecognizedDir = '未识别';

  static const String illegalFilenameChars = '<>:"/\\|?*';

  // ------------------------------------------------------------------
  // 繁转简（短语表 + 逐字映射表；与 lyrics/zh.dart 的完整 1200 字表并存，
  // 此处是旧 TextUtil 自带的较小字表，供相似度 / 目录归一等轻量场景用）
  // ------------------------------------------------------------------

  static const List<String> _tradPhrases = <String>[
    '鄧麗君', '周傑倫', '陳奕迅', '劉德華', '張學友', '張惠妹', '孫燕姿', '梁靜茹',
    '蕭敬騰', '林俊傑', '羅大佑', '李宗盛', '黃品源', '莫文蔚', '張韶涵', '范瑋琪',
    '劉若英', '蘇打綠', '陳綺貞', '張靚穎', '鍾漢良', '譚詠麟', '楊丞琳', '林憶蓮',
    '陳慧嫻', '鄭秀文', '容祖兒', '楊千嬅', '謝霆鋒', '張信哲', '庾澄慶', '張震嶽',
    '潘越雲', '鳳飛飛', '費玉清', '鄧紫棋', '林宥嘉', '田馥甄', '盧廣仲', '韋禮安',
    '徐佳瑩', '蕭亞軒', '王心凌', '黃鴻升', '炎亞綸', '吳青峰', '小虎隊', '飛兒樂團',
    '動力火車', '信樂團',
  ];
  static const List<String> _simpPhrases = <String>[
    '邓丽君', '周杰伦', '陈奕迅', '刘德华', '张学友', '张惠妹', '孙燕姿', '梁静茹',
    '萧敬腾', '林俊杰', '罗大佑', '李宗盛', '黄品源', '莫文蔚', '张韶涵', '范玮琪',
    '刘若英', '苏打绿', '陈绮贞', '张靓颖', '钟汉良', '谭咏麟', '杨丞琳', '林忆莲',
    '陈慧娴', '郑秀文', '容祖儿', '杨千嬅', '谢霆锋', '张信哲', '庾澄庆', '张震岳',
    '潘越云', '凤飞飞', '费玉清', '邓紫棋', '林宥嘉', '田馥甄', '卢广仲', '韦礼安',
    '徐佳莹', '萧亚轩', '王心凌', '黄鸿升', '炎亚纶', '吴青峰', '小虎队', '飞儿乐团',
    '动力火车', '信乐团',
  ];

  static const String _tradChars =
      '張學劉華鄧麗傑倫陳齊瑋靜蕭騰楊許羅黃萬蘇綠綺貞靚穎鍾漢譚詠憶嫻葉鄭兒謝鋒趙傳慶嶽昇凱雲鳳飛費盧廣韋瑩亞軒吳綸樂團動車愛夢時間後來這裡為與無聲語說聽風電話讓給對錯過還會開關門問題實現發變樣點線緣願雙親寶貝媽爺鄉國際場東興陽陰紅藍顏歲紀懷戀氣畫詩書長馬龍龜齒鬥臺灣貓雞魚';
  static const String _simpChars =
      '张学刘华邓丽杰伦陈齐玮静萧腾杨许罗黄万苏绿绮贞靓颖钟汉谭咏忆娴叶郑儿谢锋赵传庆岳升凯云凤飞费卢广韦莹亚轩吴纶乐团动车爱梦时间后来这里为与无声语说听风电话让给对错过还会开关门问题实现发变样点线缘愿双亲宝贝妈爷乡国际场东兴阳阴红蓝颜岁纪怀恋气画诗书长马龙龟齿斗台湾猫鸡鱼';

  static final Map<int, int> _tradCharMap = _buildTradCharMap();

  static Map<int, int> _buildTradCharMap() {
    final Map<int, int> m = <int, int>{};
    final List<int> t = _tradChars.codeUnits;
    final List<int> s = _simpChars.codeUnits;
    for (int i = 0; i < t.length && i < s.length; i++) {
      m[t[i]] = s[i];
    }
    return m;
  }

  /// 繁转简（短语优先，再逐字）。null 安全。
  static String toSimplified(String? text) {
    if (text == null || text.isEmpty) return '';
    String s = text;
    for (int i = 0; i < _tradPhrases.length; i++) {
      if (s.contains(_tradPhrases[i])) {
        s = s.replaceAll(_tradPhrases[i], _simpPhrases[i]);
      }
    }
    final StringBuffer sb = StringBuffer();
    bool changed = false;
    for (final int c in s.codeUnits) {
      final int? m = _tradCharMap[c];
      if (m != null) {
        sb.writeCharCode(m);
        changed = true;
      } else {
        sb.writeCharCode(c);
      }
    }
    return changed ? sb.toString() : s;
  }

  // ------------------------------------------------------------------
  // 规范化与比较
  // ------------------------------------------------------------------

  static final RegExp _wsRe = RegExp(r'\s+');

  /// 连字符家族：半角、全角、短横、长破折号、减号等统一成 '-'。
  static final RegExp _dashRe = RegExp(
      r'[\-\u2010\u2011\u2012\u2013\u2014\u2015\u2212\ufe63\uff0d]');

  /// NFKC 近似：全角 → 半角（U+FF01..U+FF5E）+ 表意空格 U+3000 → 半角空格。
  ///
  /// Dart 标准库无 NFKC，本实现覆盖本应用匹配所需的「全半角归一」子集
  /// （等价改写；完整 NFKC 需 Unicode 表，不在此列）。
  static String _nfkc(String s) {
    final StringBuffer sb = StringBuffer();
    for (final int c in s.codeUnits) {
      if (c == 0x3000) {
        sb.writeCharCode(0x20);
      } else if (c >= 0xFF01 && c <= 0xFF5E) {
        sb.writeCharCode(c - 0xFEE0);
      } else {
        sb.writeCharCode(c);
      }
    }
    return sb.toString();
  }

  /// 等价 Python norm_compare：全半角归一 + 小写 + 连字符归一 + 去空白。
  static String normCompare(String? text) {
    if (text == null || text.isEmpty) return '';
    String n = _nfkc(text).toLowerCase();
    n = n.replaceAll(_dashRe, '-');
    n = n.replaceAll(_wsRe, '');
    return n;
  }

  static bool containsChinese(String? text) {
    if (text == null) return false;
    for (final int c in text.codeUnits) {
      if (c >= 0x4E00 && c <= 0x9FFF) return true;
    }
    return false;
  }

  static String safeStr(String? s) => s == null ? '' : s.trim();

  // ------------------------------------------------------------------
  // 相似度（bigram Dice + Levenshtein ratio 兜底）
  // ------------------------------------------------------------------

  static double levenshtein(String a, String b) {
    final int la = a.length;
    final int lb = b.length;
    if (la == 0) return lb.toDouble();
    if (lb == 0) return la.toDouble();
    List<int> prev = List<int>.generate(lb + 1, (int j) => j);
    List<int> cur = List<int>.filled(lb + 1, 0);
    for (int i = 1; i <= la; i++) {
      cur[0] = i;
      final int ca = a.codeUnitAt(i - 1);
      for (int j = 1; j <= lb; j++) {
        final int cost = ca == b.codeUnitAt(j - 1) ? 0 : 1;
        int v = cur[j - 1] + 1;
        if (prev[j] + 1 < v) v = prev[j] + 1;
        if (prev[j - 1] + cost < v) v = prev[j - 1] + cost;
        cur[j] = v;
      }
      final List<int> t = prev;
      prev = cur;
      cur = t;
    }
    return prev[lb].toDouble();
  }

  /// 近似 difflib.SequenceMatcher.ratio：1 - 距离/较长串。
  static double ratio(String a, String b) {
    final int max = a.length > b.length ? a.length : b.length;
    if (max == 0) return 1.0;
    return 1.0 - (levenshtein(a, b) / max);
  }

  /// 综合相似度：繁转简 + 归一后，用多算法混合。
  static double textSimilarity(String? left, String? right) {
    final String a = normCompare(toSimplified(left ?? ''));
    final String b = normCompare(toSimplified(right ?? ''));
    return smartSimilarity(a, b);
  }

  /// 多算法混合相似度。入参应已做归一（normCompare / toSimplified）。
  static double smartSimilarity(String a, String b) {
    if (a.isEmpty && b.isEmpty) return 1.0;
    if (a.isEmpty || b.isEmpty) return 0.0;
    if (a == b) return 1.0;
    final double charSim = charRemainderSimilarity(a, b);
    final double levSim = ratio(a, b);
    final double dice = bigramDice(a, b);
    final double contains = containsSimilarity(a, b);
    final int ca = codePointCount(a);
    final int cb = codePointCount(b);
    final int minLen = ca < cb ? ca : cb;
    final double blended = minLen <= 3
        ? 0.35 * charSim + 0.45 * levSim + 0.20 * dice
        : 0.50 * charSim + 0.30 * levSim + 0.20 * dice;
    return contains > blended ? contains : blended;
  }

  /// 字符残差相似度：两串公共字符（按 codePoint 多重集）占两串总字符的比例。
  static double charRemainderSimilarity(String a, String b) {
    if (a.isEmpty && b.isEmpty) return 1.0;
    if (a.isEmpty || b.isEmpty) return 0.0;
    final Map<int, int> ca = codePointCounts(a);
    final Map<int, int> cb = codePointCounts(b);
    int common = 0;
    for (final MapEntry<int, int> e in ca.entries) {
      final int? other = cb[e.key];
      if (other != null) {
        common += e.value < other ? e.value : other;
      }
    }
    final int total = codePointCount(a) + codePointCount(b);
    return total == 0 ? 0.0 : 2.0 * common / total;
  }

  /// 子串包含相似度：短串是长串的子串时给 0.80 + 长度占比 0.20，否则 0。
  static double containsSimilarity(String a, String b) {
    if (a.isEmpty || b.isEmpty) return 0.0;
    final String longer = a.length >= b.length ? a : b;
    final String shorter = a.length >= b.length ? b : a;
    if (longer.contains(shorter)) {
      return 0.80 + 0.20 * (shorter.length / longer.length);
    }
    return 0.0;
  }

  static double bigramDice(String a, String b) {
    if (a.length < 2 || b.length < 2) return ratio(a, b);
    final Map<String, int> gramsA = bigramCounts(a);
    final Map<String, int> gramsB = bigramCounts(b);
    int overlap = 0;
    int totalA = 0;
    int totalB = 0;
    for (final int n in gramsA.values) {
      totalA += n;
    }
    for (final int n in gramsB.values) {
      totalB += n;
    }
    for (final MapEntry<String, int> e in gramsA.entries) {
      final int? other = gramsB[e.key];
      if (other != null) {
        overlap += e.value < other ? e.value : other;
      }
    }
    return 2.0 * overlap / (totalA + totalB);
  }

  static int codePointCount(String s) => s.runes.length;

  static Map<int, int> codePointCounts(String s) {
    final Map<int, int> map = <int, int>{};
    for (final int cp in s.runes) {
      map[cp] = (map[cp] ?? 0) + 1;
    }
    return map;
  }

  static Map<String, int> bigramCounts(String s) {
    final Map<String, int> map = <String, int>{};
    for (int i = 0; i + 2 <= s.length; i++) {
      final String g = s.substring(i, i + 2);
      map[g] = (map[g] ?? 0) + 1;
    }
    return map;
  }

  // ------------------------------------------------------------------
  // 尾部污染后缀 / 重编码标记
  // ------------------------------------------------------------------

  /// _N / _N_N / (N) / （N） / _(N) / _副本 / 「 - 副本」等混合污染链。
  static final RegExp _trailingSuffixRe = RegExp(
      r'(?:_\d+(?:[~.\-、 _]\d+|[\s\u3000]*[（(]\s*\d+\s*[)）])*'
      r'|(?:[\s\u3000]*[-_][\s\u3000]*|[\s\u3000]+)(?:副本|拷贝|copy|複製|复制)\s*\d*'
      r'|[\s\u3000_]*[（(]\s*\d+\s*[)）])+$',
      caseSensitive: false);

  static String stripTrailingNumericSuffix(String? stem) {
    if (stem == null) return '';
    return stem.replaceFirst(_trailingSuffixRe, '');
  }

  static const List<String> _recodeKeywords = <String>[
    'h264_videotoolbox', 'hevc_videotoolbox', 'libx264', 'libx265',
    'h264_nvenc', 'hevc_nvenc', 'h264_qsv', 'hevc_qsv', 'h264_amf',
    'hevc_amf', 'h264_vaapi', 'hevc_vaapi',
    'x264', 'x265', 'h264', 'h265', 'hevc', 'av1', 'vp8', 'vp9',
    'recode', 'reencoded', 'encoded', 'ffmpeg', 'new',
  ];

  static final RegExp _crfRe =
      RegExp(r'_crf\s*\d+(?:\.\d+)?(?:_[a-z]+)*$', caseSensitive: false);
  static final RegExp _bracketRe =
      RegExp(r'_\[[^\]]+\]$|_\([^)]+\)$', caseSensitive: false);

  /// 剥离 FFmpegFreeUI / HandBrake 等重编码工具追加的标记（最多 10 轮）。
  static String stripRecodeMarker(String? stem) {
    if (stem == null || stem.isEmpty) return stem ?? '';
    String result = stem;
    for (int round = 0; round < 10; round++) {
      final String original = result;
      for (final String kw in _recodeKeywords) {
        result = result.replaceAll(
          RegExp('_${RegExp.escape(kw)}(?:\\s*\\d+(?:\\.\\d+)?)?\$',
              caseSensitive: false),
          '',
        );
      }
      result = result.replaceFirst(_crfRe, '');
      result = result.replaceFirst(_bracketRe, '');
      result = stripTrailingNumericSuffix(result);
      if (result == original) break;
    }
    return result.isEmpty ? stem : result;
  }

  static final RegExp _spaceCharsRe =
      RegExp(r'[\s\u3000\u00a0\u2000-\u200b\u202f\u205f]+');

  /// 清理归一化：去广告前缀 + 轨道前缀 + 重编码标记 + 污染后缀；
  /// 含中文则去全部空格。每一步都保守：拿不准就不动。
  static String normalizeStemForCleanup(String? stem) {
    if (stem == null || stem.isEmpty) return stem ?? '';
    String cleaned = _stripAdPrefix(stem);
    cleaned = _stripCleanupTrackPrefix(cleaned);
    cleaned = stripRecodeMarker(cleaned);
    if (containsChinese(cleaned)) {
      final String noSpace = cleaned.replaceAll(_spaceCharsRe, '');
      if (noSpace.isNotEmpty) cleaned = noSpace;
    }
    if (cleaned.trim().isEmpty) return stem;
    return cleaned;
  }

  // ------------------------------------------------------------------
  // 清理专用的前缀剥离（比匹配路径的剥法更保守）
  // ------------------------------------------------------------------

  /// 广告/来源前缀的关键词：括号内容带这些才认为是包装，否则不动 ——
  /// 【某某音乐】 / [无损音乐网] 削；（晴天） 这种歌名前缀是正文，不能削。
  static const List<String> _adPrefixKeywords = <String>[
    '音乐', '无损', '高清', '音质', '推荐', '分享', '下载', '试听',
    '官方', '资源', '网盘', '电台',
  ];

  /// 英文来源标记（带词边界，防止 Shadow 这类词被误伤）。
  static final RegExp _adPrefixEnRe = RegExp(
      r'\b(?:music|lossless|flac|mp3|wav|aac|320kbps|320|download|official|hq|sq)\b',
      caseSensitive: false);

  /// 开头连续的括号组：【…】 / […] / （…） / (…)，单组内容 ≤ 24 字符。
  static final RegExp _leadingBracketRe =
      RegExp(r'^\s*(?:[【\[（(][^【\[（(】\]）)]{0,24}[】\]）)]\s*)+');

  /// 去开头的广告/来源括号前缀：只有括号内容带推广关键词才削。
  static String _stripAdPrefix(String stem) {
    final Match? m = _leadingBracketRe.firstMatch(stem);
    if (m == null) return stem;
    final String head = m.group(0)!;
    bool promo = false;
    for (final String kw in _adPrefixKeywords) {
      if (head.contains(kw)) {
        promo = true;
        break;
      }
    }
    if (!promo) promo = _adPrefixEnRe.hasMatch(head);
    if (!promo) return stem;
    final String rest = stem.substring(m.end);
    return rest.trim().isEmpty ? stem : rest;
  }

  /// 清理用的轨道前缀：只认带标点/括号的「01. / 01- / (01) / [01]」，
  /// 纯空格分隔的「01 歌名」不剥 —— 「7 years」这类真歌名会被误伤。
  static final RegExp _cleanupTrackPrefixRe = RegExp(
      r'^\s*(?:\[\s*\d{1,4}\s*\]|\(\s*\d{1,4}\s*\)|（\s*\d{1,4}\s*）|\d{1,4}\s*[.．、_\-]\s*)(?=\S)');

  static String _stripCleanupTrackPrefix(String stem) {
    final String candidate = stem.replaceFirst(_cleanupTrackPrefixRe, '').trim();
    if (candidate.isEmpty || candidate == stem.trim()) return stem;
    // 剥完必须还剩文字（中文/字母/假名），防止把「01」这类整名剥空
    for (final int c in candidate.runes) {
      if ((c >= 0x41 && c <= 0x5A) ||
          (c >= 0x61 && c <= 0x7A) ||
          (c >= 0x4E00 && c <= 0x9FFF) ||
          (c >= 0x3040 && c <= 0x30FF)) {
        return candidate;
      }
    }
    return stem;
  }

  // ------------------------------------------------------------------
  // 文件名合法化 / 轨道前缀
  // ------------------------------------------------------------------

  static String sanitizeFilenameComponent(
      String? name, String fallback, int maxLength) {
    String text = _nfkc(name ?? '');
    text = text.replaceAll('\r', ' ').replaceAll('\n', ' ').replaceAll('\t', ' ');
    for (final int c in illegalFilenameChars.codeUnits) {
      text = text.replaceAll(String.fromCharCode(c), '_');
    }
    final StringBuffer sb = StringBuffer();
    for (final int c in text.codeUnits) {
      if (c >= 32) sb.writeCharCode(c);
    }
    text = sb.toString().trim();
    text = _stripDots(text);
    if (text.isEmpty) return fallback;
    if (text.length > maxLength) text = text.substring(0, maxLength);
    text = _stripDots(text);
    return text.isEmpty ? fallback : text;
  }

  static final RegExp _trackPrefixRe = RegExp(
      r'^\s*(?:\[(?:\d{1,4})\]|\((?:\d{1,4})\)|(?:\d{1,4})\s*[.．、_\-]\s*|(?:\d{1,4})\s+)(?=\S)');

  /// 剥离「01.」「(03)」「08 -」等轨道前缀，剥离结果必须含文字才采用。
  static String stripTrackPrefix(String? stem) {
    if (stem == null) return '';
    final String original = stem;
    final String candidate = stem.replaceFirst(_trackPrefixRe, '').trim();
    if (candidate.isNotEmpty && candidate != original) {
      if (RegExp(r'[-–—_]').hasMatch(candidate) || containsChinese(candidate)) {
        return candidate;
      }
      for (final int c in candidate.codeUnits) {
        if ((c >= 0x41 && c <= 0x5A) ||
            (c >= 0x61 && c <= 0x7A) ||
            (c >= 0x4E00 && c <= 0x9FFF)) {
          return candidate;
        }
      }
    }
    return original;
  }

  static String formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    double v = bytes.toDouble();
    const List<String> units = <String>['KB', 'MB', 'GB', 'TB'];
    for (final String unit in units) {
      v /= 1024.0;
      if (v < 1024.0 || unit == 'TB') {
        return '${v.toStringAsFixed(1)} $unit';
      }
    }
    return '$bytes B';
  }

  static String formatDuration(double? seconds) {
    if (seconds == null || seconds.isNaN || seconds.isInfinite || seconds <= 0) {
      return '--:--';
    }
    final int total = seconds.round();
    final int h = total ~/ 3600;
    final int m = (total % 3600) ~/ 60;
    final int s = total % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  static String shortError(Object? t) {
    if (t == null) return '未知错误';
    final String msg = t.toString();
    final String text = msg.trim().isEmpty ? t.runtimeType.toString() : msg.trim();
    return text.length > 180 ? text.substring(0, 180) : text;
  }

  static String joinArtists(List<String> names, String sep) => names.join(sep);

  // ------------------------------------------------------------------
  // 多艺人拆分（按分隔符与括号提示切分）
  // ------------------------------------------------------------------

  /// 含分隔符的组合艺人名，不能被拆开（整串白名单，normCompare 后比对）。
  static const List<String> _noSplitArtists = <String>[
    'simon & garfunkel', 'earth, wind & fire', 'guns n\' roses',
    'crosby, stills, nash & young', 'a great big world',
    'fitz and the tantrums', 'twenty one pilots', 'boyz ii men',
  ];

  static final RegExp _artistSepRe = RegExp(
      r'\s*(?:/|／|、|;|；|,|，|&|＆|\bfeat\.?\b|\bft\.?\b|\bfeaturing\b)\s*',
      caseSensitive: false);

  /// 拆多艺人：按分隔符拆，白名单保护会被误拆的组合名，结果去空 + 去重。
  static List<String> splitArtists(String? raw) {
    final List<String> out = <String>[];
    if (raw == null || raw.trim().isEmpty) return out;
    final String key = normCompare(raw);
    for (final String noSplit in _noSplitArtists) {
      if (key == normCompare(noSplit)) {
        out.add(raw.trim());
        return out;
      }
    }
    for (final String part in raw.split(_artistSepRe)) {
      final String p = part.trim();
      if (p.isEmpty || _containsNorm(out, p)) continue;
      out.add(p);
    }
    return out.isEmpty ? <String>[raw.trim()] : out;
  }

  /// 多艺人最佳相似度：拆分双方，取「任一本地艺人 × 任一候选艺人」的最大相似度。
  static double bestArtistSimilarity(String a, String b) {
    final List<String> as = splitArtists(a);
    final List<String> bs = splitArtists(b);
    if (as.isEmpty || bs.isEmpty) return 0.0;
    double best = 0.0;
    for (final String x in as) {
      for (final String y in bs) {
        final double s = textSimilarity(x, y);
        if (s > best) best = s;
      }
    }
    return best;
  }

  /// 简易匹配工具：返回所有匹配组。
  static List<String> findAll(RegExp p, String text, [int group = 0]) {
    final List<String> out = <String>[];
    for (final Match m in p.allMatches(text)) {
      out.add(m.group(group)!);
    }
    return out;
  }

  static bool _containsNorm(List<String> list, String s) {
    final String key = normCompare(s);
    for (final String e in list) {
      if (normCompare(e) == key) return true;
    }
    return false;
  }

  static String _stripDots(String s) {
    int start = 0;
    int end = s.length;
    while (start < end && (s[start] == '.' || s[start] == ' ')) {
      start++;
    }
    while (end > start && (s[end - 1] == '.' || s[end - 1] == ' ')) {
      end--;
    }
    return s.substring(start, end);
  }
}
