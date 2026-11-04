import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/match/text_util.dart';

double sim(String a, String b) => TextUtil.textSimilarity(a, b);

void main() {
  test('normCompare 连字符归一', () {
    expect(TextUtil.normCompare('周杰伦－晴天'), TextUtil.normCompare('周杰伦-晴天'));
    expect(TextUtil.normCompare('A–B'), TextUtil.normCompare('A-B'));
    expect(TextUtil.normCompare('A—B'), TextUtil.normCompare('A-B'));
  });

  test('textSimilarity 边界', () {
    expect(sim('晴天', '晴天'), 1.0);
    expect(sim('', '晴天'), 0.0);
    expect(sim('', ''), 1.0);
    expect(sim('周杰伦', '周杰倫'), greaterThan(0.99));
    expect(sim('Track 01', 'Track　01'), greaterThan(0.99));
  });

  test('短中文歌名', () {
    final double same = sim('晴天', '晴天');
    final double oneDiff = sim('晴天', '阴天');
    final double noOverlap = sim('晴天', '大海');
    expect(oneDiff, lessThan(0.8));
    expect(oneDiff, greaterThan(0.0));
    expect(noOverlap, lessThan(oneDiff));
    expect(noOverlap, lessThan(0.35));
    expect(same, greaterThan(oneDiff));
  });

  test('子串包含', () {
    expect(sim('晴天', '晴天 完整版'), greaterThanOrEqualTo(0.8));
    expect(TextUtil.containsSimilarity('晴天', '晴天完整版'),
        greaterThanOrEqualTo(0.8));
  });

  test('splitArtists', () {
    expect(TextUtil.splitArtists('周杰伦/杨瑞代'), ['周杰伦', '杨瑞代']);
    expect(TextUtil.splitArtists('周杰伦、林俊杰').length, 2);
    expect(TextUtil.splitArtists('A feat. B').length, 2);
    expect(TextUtil.splitArtists('Simon & Garfunkel'), ['Simon & Garfunkel']);
    expect(TextUtil.splitArtists('周杰伦、周杰伦').length, 1);
    expect(TextUtil.splitArtists('  '), isEmpty);
  });

  test('bestArtistSimilarity 合唱匹配', () {
    expect(TextUtil.bestArtistSimilarity('周杰伦', '周杰伦/杨瑞代'),
        greaterThan(0.9));
    expect(TextUtil.bestArtistSimilarity('周杰伦', '林俊杰'), lessThan(0.5));
  });

  group('normalizeStemForCleanup 清理规则', () {
    test('去轨道前缀（带标点才剥）', () {
      expect(TextUtil.normalizeStemForCleanup('01. 晴天'), '晴天');
      expect(TextUtil.normalizeStemForCleanup('03-晴天'), '晴天');
      expect(TextUtil.normalizeStemForCleanup('[07]晴天'), '晴天');
      expect(TextUtil.normalizeStemForCleanup('（12）晴天'), '晴天');
      // 纯空格分隔不剥：「7 years」是真歌名；无中文也不去空格
      expect(TextUtil.normalizeStemForCleanup('7 years'), '7 years');
    });

    test('去广告前缀（带推广关键词才剥）', () {
      expect(TextUtil.normalizeStemForCleanup('【某某音乐】晴天'), '晴天');
      expect(TextUtil.normalizeStemForCleanup('[无损音乐网]晴天'), '晴天');
      expect(TextUtil.normalizeStemForCleanup('【HQ】晴天'), '晴天');
      // 没有关键词的括号是歌名的一部分，不动
      expect(TextUtil.normalizeStemForCleanup('（晴天）晴天'), '（晴天）晴天');
      expect(TextUtil.normalizeStemForCleanup('【周杰伦】晴天'), '【周杰伦】晴天');
    });

    test('去尾部污染后缀（含「 - 副本」）', () {
      expect(TextUtil.normalizeStemForCleanup('晴天_1'), '晴天');
      expect(TextUtil.normalizeStemForCleanup('晴天(1)'), '晴天');
      expect(TextUtil.normalizeStemForCleanup('晴天_副本'), '晴天');
      expect(TextUtil.normalizeStemForCleanup('晴天 - 副本'), '晴天');
      expect(TextUtil.normalizeStemForCleanup('晴天-copy2'), '晴天');
      // 无分隔符的「副本」是歌名的一部分，不动
      expect(TextUtil.normalizeStemForCleanup('晴天副本'), '晴天副本');
    });

    test('重编码标记与中文去空格保持原有行为', () {
      expect(TextUtil.normalizeStemForCleanup('晴天_x264'), '晴天');
      expect(TextUtil.normalizeStemForCleanup('周 杰 伦 晴 天'), '周杰伦晴天');
    });

    test('剥空了就保留原名', () {
      expect(TextUtil.normalizeStemForCleanup('01'), '01');
      expect(TextUtil.normalizeStemForCleanup('【音乐】'), '【音乐】');
    });
  });

  // ------------------------------------------------------------------
  // 繁转简：短语分桶优化的等价性守卫。
  //
  // toSimplified 对 50 条短语原本逐条做 `contains` 全串扫描（16KB 歌词里占
  // 76% 的时间）。优化成「先看首字符在不在文本里，不在就跳过那条 contains」，
  // 语义上必须与原实现逐字节一致。下面用一个内嵌的原实现做特征化对比，
  // 任何人改坏分桶逻辑都会在这里红。
  // ------------------------------------------------------------------
  group('toSimplified 短语分桶等价性', () {
    // 原实现（逐条全扫 + 逐字查表）——只作为参照，不要改成调用生产代码。
    // 注意必须完整复刻两步：先短语替换，再逐字映射；只做一步就对不上。
    String original(String? text) {
      if (text == null || text.isEmpty) return '';
      const List<String> trad = <String>[
        '鄧麗君', '周傑倫', '陳奕迅', '劉德華', '張學友', '張惠妹', '孫燕姿', '梁靜茹',
        '蕭敬騰', '林俊傑', '羅大佑', '李宗盛', '黃品源', '莫文蔚', '張韶涵', '范瑋琪',
        '劉若英', '蘇打綠', '陳綺貞', '張靚穎', '鍾漢良', '譚詠麟', '楊丞琳', '林憶蓮',
        '陳慧嫻', '鄭秀文', '容祖兒', '楊千嬅', '謝霆鋒', '張信哲', '庾澄慶', '張震嶽',
        '潘越雲', '鳳飛飛', '費玉清', '鄧紫棋', '林宥嘉', '田馥甄', '盧廣仲', '韋禮安',
        '徐佳瑩', '蕭亞軒', '王心凌', '黃鴻升', '炎亞綸', '吳青峰', '小虎隊', '飛兒樂團',
        '動力火車', '信樂團',
      ];
      const List<String> simp = <String>[
        '邓丽君', '周杰伦', '陈奕迅', '刘德华', '张学友', '张惠妹', '孙燕姿', '梁静茹',
        '萧敬腾', '林俊杰', '罗大佑', '李宗盛', '黄品源', '莫文蔚', '张韶涵', '范玮琪',
        '刘若英', '苏打绿', '陈绮贞', '张靓颖', '钟汉良', '谭咏麟', '杨丞琳', '林忆莲',
        '陈慧娴', '郑秀文', '容祖儿', '杨千嬅', '谢霆锋', '张信哲', '庾澄庆', '张震岳',
        '潘越云', '凤飞飞', '费玉清', '邓紫棋', '林宥嘉', '田馥甄', '卢广仲', '韦礼安',
        '徐佳莹', '萧亚轩', '王心凌', '黄鸿升', '炎亚纶', '吴青峰', '小虎队', '飞儿乐团',
        '动力火车', '信乐团',
      ];
      const String tradChars =
          '張學劉華鄧麗傑倫陳齊瑋靜蕭騰楊許羅黃萬蘇綠綺貞靚穎鍾漢譚詠憶嫻葉鄭兒謝鋒趙傳慶嶽昇凱雲鳳飛費盧廣韋瑩亞軒吳綸樂團動車愛夢時間後來這裡為與無聲語說聽風電話讓給對錯過還會開關門問題實現發變樣點線緣願雙親寶貝媽爺鄉國際場東興陽陰紅藍顏歲紀懷戀氣畫詩書長馬龍龜齒鬥臺灣貓雞魚';
      const String simpChars =
          '张学刘华邓丽杰伦陈齐玮静萧腾杨许罗黄万苏绿绮贞靓颖钟汉谭咏忆娴叶郑儿谢锋赵传庆岳升凯云凤飞费卢广韦莹亚轩吴纶乐团动车爱梦时间后来这里为与无声语说听风电话让给对错过还会开关门问题实现发变样点线缘愿双亲宝贝妈爷乡国际场东兴阳阴红蓝颜岁纪怀恋气画诗书长马龙龟齿斗台湾猫鸡鱼';
      final Map<int, int> charMap = <int, int>{};
      for (int i = 0; i < tradChars.length && i < simpChars.length; i++) {
        charMap[tradChars.codeUnitAt(i)] = simpChars.codeUnitAt(i);
      }

      String s = text;
      for (int i = 0; i < trad.length; i++) {
        if (s.contains(trad[i])) s = s.replaceAll(trad[i], simp[i]);
      }
      final StringBuffer sb = StringBuffer();
      bool changed = false;
      for (final int c in s.codeUnits) {
        final int? m = charMap[c];
        if (m != null) {
          sb.writeCharCode(m);
          changed = true;
        } else {
          sb.writeCharCode(c);
        }
      }
      return changed ? sb.toString() : s;
    }

    test('50 条短语逐条与参照实现一致', () {
      const List<String> phrases = <String>[
        '鄧麗君', '周傑倫', '陳奕迅', '劉德華', '張學友', '張惠妹', '孫燕姿', '梁靜茹',
        '蕭敬騰', '林俊傑', '羅大佑', '李宗盛', '黃品源', '莫文蔚', '張韶涵', '范瑋琪',
        '劉若英', '蘇打綠', '陳綺貞', '張靚穎', '鍾漢良', '譚詠麟', '楊丞琳', '林憶蓮',
        '陳慧嫻', '鄭秀文', '容祖兒', '楊千嬅', '謝霆鋒', '張信哲', '庾澄慶', '張震嶽',
        '潘越雲', '鳳飛飛', '費玉清', '鄧紫棋', '林宥嘉', '田馥甄', '盧廣仲', '韋禮安',
        '徐佳瑩', '蕭亞軒', '王心凌', '黃鴻升', '炎亞綸', '吳青峰', '小虎隊', '飛兒樂團',
        '動力火車', '信樂團',
      ];
      for (final String p in phrases) {
        expect(TextUtil.toSimplified(p), original(p), reason: p);
      }
    });

    test('短语重复 / 相邻拼接 / 首字符残留，均与参照一致', () {
      const List<String> cases = <String>[
        '鄧麗君鄧麗君鄧麗君',
        '鄧麗君周傑倫陳奕迅劉德華',
        '小虎隊飛兒樂團動力火車信樂團',
        // 首字符在、但短语不完整：分桶会进桶，contains 仍应为 false
        '鄧麗', '麗君', '周傑', '傑倫', '張學', '學友', '小虎', '虎隊',
        '鄧', '麗', '君', '張', '學', '友',
        // 替换后可能产生新短语的构造
        '張學友', '張學', '學友',
        '后来 我们 電話 時間 無聲',
        '',
        'Love Me Tender 2026',
      ];
      for (final String c in cases) {
        expect(TextUtil.toSimplified(c), original(c), reason: c);
      }
    });

    test('随机串模糊对比（2000 条，含字表 / 短语 / 标点 / 英文）', () {
      // 固定种子：失败可复现，不会随机飘
      int seed = 20261104;
      int next(int mod) {
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
        return seed % mod;
      }

      const String simpPool = '我们都说好的幸福呢后来眼泪电话时间窗前明月光疑是地上霜举头望明月低头思故乡夜曲';
      const String tradChars =
          '張學劉華鄧麗傑倫陳齊瑋靜蕭騰楊許羅黃萬蘇綠綺貞靚穎鍾漢譚詠憶嫻葉鄭兒謝鋒趙傳慶嶽昇凱雲鳳飛費盧廣韋瑩亞軒吳綸樂團動車愛夢時間後來這裡為與無聲語說聽風電話讓給對錯過還會開關門問題實現發變樣點線緣願雙親寶貝媽爺鄉國際場東興陽陰紅藍顏歲紀懷戀氣畫詩書長馬龍龜齒鬥臺灣貓雞魚';
      const String punct = ' .,:;!?[]()（）「」【】·—-_';
      const String alpha = 'abcXYZ0123456789';
      const List<String> phrasePool = <String>['鄧麗君', '周傑倫', '小虎隊', '飛兒樂團', '動力火車'];

      for (int i = 0; i < 2000; i++) {
        final int len = next(50);
        final StringBuffer sb = StringBuffer();
        for (int j = 0; j < len; j++) {
          final int k = next(100);
          if (k < 30) {
            sb.write(simpPool[next(simpPool.length)]);
          } else if (k < 55) {
            sb.write(tradChars[next(tradChars.length)]);
          } else if (k < 75) {
            sb.write(phrasePool[next(phrasePool.length)]);
          } else if (k < 88) {
            sb.write(punct[next(punct.length)]);
          } else {
            sb.write(alpha[next(alpha.length)]);
          }
        }
        final String s = sb.toString();
        expect(TextUtil.toSimplified(s), original(s), reason: '随机串 #$i: "$s"');
      }
    });

    test('null 与空串', () {
      expect(TextUtil.toSimplified(null), '');
      expect(TextUtil.toSimplified(''), '');
    });
  });
}
