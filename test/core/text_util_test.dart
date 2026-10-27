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
}
