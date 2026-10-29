import 'package:flutter_test/flutter_test.dart' hide Tags;
import 'package:musicorganizer/core/match/local_query.dart';
import 'package:musicorganizer/core/model/lyric_hit.dart';
import 'package:musicorganizer/core/model/query.dart';
import 'package:musicorganizer/core/model/tags.dart';
import 'package:musicorganizer/core/model/vfile.dart';
import 'package:musicorganizer/core/source/offer_score.dart';
import 'package:musicorganizer/core/source/tag_source.dart';
import 'package:musicorganizer/feature/lyrics_batch/lyrics_logic.dart';

/// 文件名把歌手与歌名写反时（`歌名-歌手`），本地有两组解释；
/// 打分必须两个方向都试，否则标题被当成歌手，相似度趋零，候选全被淘汰。
void main() {
  Query queryOf(String name, {Map<String, String> tags = const <String, String>{}}) {
    final VFile f = VFile(docId: 'a', name: name);
    final Tags t = Tags();
    tags.forEach(t.put);
    return LocalQuery.forFile(f, t);
  }

  test('「歌名-歌手」解析出两个方向', () {
    final List<List<String>> combos = TagQuery.localCombos(queryOf('水手-郑智化.mp3'));
    final List<String> flat = combos.map((List<String> c) => c.join('|')).toList();
    expect(flat, contains('水手|郑智化'));
    expect(flat, contains('郑智化|水手'));
  });

  test('有标签时：标签那组也算一种解释（去重后不重复）', () {
    final List<List<String>> combos = TagQuery.localCombos(
        queryOf('水手-郑智化.mp3', tags: <String, String>{'title': '水手', 'artist': '郑智化'}));
    expect(combos.map((List<String> c) => c.join('|')), contains('郑智化|水手'));
    // 标签那组与解析出来的某一组相同，不该重复出现
    expect(combos.where((List<String> c) => c[0] == '郑智化' && c[1] == '水手').length, 1);
  });

  test('反写方向不会把候选判死：正确那组能拿到分', () {
    final Query q = queryOf('水手-郑智化.mp3');
    // 源返回的正确条目：标题「水手」、歌手「郑智化」
    double best = -1;
    for (final List<String> combo in TagQuery.localCombos(q)) {
      final double s = offerScore(
        localTitle: combo[1],
        localArtist: combo[0],
        localDuration: null,
        candidateTitle: '水手',
        candidateArtist: '郑智化',
        candidateDuration: null,
        source: 'netease',
        chinese: true,
      );
      if (s > best) best = s;
    }
    // 只看第一组（artist=水手 / title=郑智化）会被判淘汰（<0）
    final double first = offerScore(
      localTitle: '郑智化',
      localArtist: '水手',
      localDuration: null,
      candidateTitle: '水手',
      candidateArtist: '郑智化',
      candidateDuration: null,
      source: 'netease',
      chinese: true,
    );
    expect(first, lessThan(0), reason: '单看第一组确实会被砍掉');
    expect(best, greaterThan(0.5), reason: '正确方向要能拿到高分');
  });

  test('歌词候选：文件名反写时仍能选中', () {
    final Query q = queryOf('水手-郑智化.mp3');
    final LyricHit hit = LyricHit()
      ..source = 'netease'
      ..title = '水手'
      ..artist = '郑智化'
      ..synced = '[00:01.00]他说风雨中这点痛算什么';
    final List<LyricChoice> ranked = LyricPick.rank(q, <LyricHit>[hit]);
    expect(ranked, isNotEmpty, reason: '方向写反不该被淘汰');
    expect(ranked.first.selected, isTrue);
  });
}
