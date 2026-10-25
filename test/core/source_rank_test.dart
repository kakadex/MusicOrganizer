import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/source/source_rank.dart';

void main() {
  group('优先级与判定', () {
    test('国内五家在前，未登记源排最后', () {
      expect(SourceRank.priority('netease'), 0);
      expect(SourceRank.priority('migu'), 4);
      expect(SourceRank.priority('deezer'), 6);
      expect(SourceRank.priority('没有这个源'), SourceRank.order.length);
      expect(SourceRank.priority(null), SourceRank.order.length);
    });

    test('是否国内源', () {
      expect(SourceRank.isChinese('netease'), isTrue);
      expect(SourceRank.isChinese('migu'), isTrue);
      expect(SourceRank.isChinese('musicbrainz'), isFalse);
      expect(SourceRank.isChinese('没有这个源'), isFalse);
    });

    test('展示名', () {
      expect(SourceRank.label('netease'), '网易云');
      expect(SourceRank.label('qqmusic'), 'QQ 音乐');
      expect(SourceRank.label('itunes'), 'iTunes');
      expect(SourceRank.label('没有这个源'), '没有这个源');
      expect(SourceRank.label(null), '');
    });

    test('顺序表随语种切换，且返回的是副本', () {
      expect(SourceRank.ordered().first, 'netease');
      expect(SourceRank.ordered(chinese: false).first, 'musicbrainz');
      final List<String> copy = SourceRank.ordered();
      copy.clear();
      expect(SourceRank.ordered().first, 'netease');
    });
  });

  group('候选排序', () {
    test('中文曲目：国内源在宽容带内压过海外源', () {
      // 海外 0.85 vs 国内 0.60，差 0.25 ≤ 0.30 → 国内在前
      expect(
          SourceRank.compare('netease', 0.60, 'musicbrainz', 0.85), -1);
      expect(
          SourceRank.compare('musicbrainz', 0.85, 'netease', 0.60), 1);
    });

    test('中文曲目：海外明显更可信时仍按置信度', () {
      expect(SourceRank.compare('netease', 0.40, 'musicbrainz', 0.90), 1);
      expect(SourceRank.compare('musicbrainz', 0.90, 'netease', 0.40), -1);
    });

    test('外文曲目：海外优先', () {
      expect(
          SourceRank.compare('netease', 0.60, 'musicbrainz', 0.85, chinese: false),
          1);
      expect(
          SourceRank.compare('musicbrainz', 0.85, 'netease', 0.60, chinese: false),
          -1);
    });

    test('同为国内或同为海外时按置信度', () {
      expect(SourceRank.compare('netease', 0.80, 'qqmusic', 0.60), -1);
      expect(SourceRank.compare('deezer', 0.80, 'itunes', 0.60), -1);
    });

    test('置信度持平（在容差内）时按优先级', () {
      expect(SourceRank.compare('qqmusic', 0.7000, 'netease', 0.7000), 1);
      // 浮点边界：0.9000 - 0.9010 的差刚好卡在 0.001 上，加 epsilon 后算持平
      expect(SourceRank.compare('netease', 0.9000, 'qqmusic', 0.9010), -1);
    });

    test('完全相同视为持平', () {
      expect(SourceRank.compare('netease', 0.7, 'netease', 0.7), 0);
    });

    test('用排序表排一串候选：国内在前', () {
      final List<List<Object>> items = <List<Object>>[
        <Object>['musicbrainz', 0.85],
        <Object>['netease', 0.60],
        <Object>['deezer', 0.75],
      ];
      items.sort((List<Object> a, List<Object> b) => SourceRank.compare(
          a[0] as String, a[1] as double, b[0] as String, b[1] as double));
      expect(items.map((List<Object> e) => e[0]).toList(),
          <String>['netease', 'musicbrainz', 'deezer']);
    });
  });
}
