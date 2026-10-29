/// 时长不符的「另一个录音版本」：严格模式判不同录音，宽松模式仍要能列出来。
///
/// 背景：同一首歌的现场版 / 合辑剪辑 / 转码被截断的版本，时长能差几十秒。
/// 卡死时长会让这类文件一首也匹配不到（4:17 对 5:43 差 86 秒）；放宽之后
/// 又不能让「标题像、歌手不同」的噪声跟着进来。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/lyrics/zh.dart';
import 'package:musicorganizer/core/model/query.dart';
import 'package:musicorganizer/core/source/aggregator.dart';
import 'package:musicorganizer/core/source/offer_score.dart';
import 'package:musicorganizer/core/source/tag_source.dart';

Query _q({
  String artist = '示例歌手',
  String title = '示例歌名',
  double? duration = 257,
}) =>
    Query()
      ..filenameCandidates = <List<String>>[
        <String>[artist, title]
      ]
      ..embeddedTags = <String, String>{}
      ..localDuration = duration;

/// 只问 iTunes，返回一条指定时长的候选（离线，不联网）。
JsonFetcher _itunesFetcher(String title, String artist, double seconds) =>
    (String url, Map<String, String>? params) async {
      if (!url.contains('itunes.apple.com')) return <String, Object>{};
      return <String, Object>{
        'results': <Object>[
          <String, Object>{
            'trackName': title,
            'artistName': artist,
            'collectionName': '示例专辑',
            'releaseDate': '1989-02-01T12:00:00Z',
            'trackTimeMillis': (seconds * 1000).round(),
          }
        ]
      };
    };

void main() {
  group('scoreDetail 的时长门槛', () {
    OfferScore score({required bool strict}) => scoreDetail(
          localTitle: '示例歌名',
          localArtist: '示例歌手',
          localDuration: 257,
          candidateTitle: '示例歌名',
          candidateArtist: '示例歌手',
          candidateDuration: 343.5,
          source: 'itunes',
          chinese: true,
          strictDuration: strict,
        );

    test('严格模式：差 86 秒判为不同录音', () {
      expect(score(strict: true).rejected, isTrue);
      expect(score(strict: true).reason, contains('时长'));
    });

    test('宽松模式：标题歌手都对时，时长不符仍给正分', () {
      final OfferScore s = score(strict: false);
      expect(s.rejected, isFalse);
      expect(s.score, greaterThan(0.6));
    });

    test('宽松模式：歌手对不上照样淘汰', () {
      final OfferScore s = scoreDetail(
        localTitle: '示例歌名',
        localArtist: '示例歌手',
        localDuration: 257,
        candidateTitle: '示例歌名',
        candidateArtist: '另一位歌手',
        candidateDuration: 343.5,
        source: 'itunes',
        chinese: true,
        strictDuration: false,
      );
      expect(s.rejected, isTrue);
    });

    test('宽松模式：标题对不上照样淘汰', () {
      final OfferScore s = scoreDetail(
        localTitle: '示例歌名',
        localArtist: '示例歌手',
        localDuration: 257,
        candidateTitle: '完全不同的歌',
        candidateArtist: '示例歌手',
        candidateDuration: 343.5,
        source: 'itunes',
        chinese: true,
        strictDuration: false,
      );
      expect(s.rejected, isTrue);
    });
  });

  group('Aggregator 的 verify 开关', () {
    test('严格模式砍掉时长不符的候选', () async {
      final AggregateResult r = await Aggregator.tagCandidates(
        _q(),
        only: <String>['itunes'],
        fetch: _itunesFetcher('示例歌名', '示例歌手', 343.5),
      );
      expect(r.candidates, isEmpty);
    });

    test('宽松模式保留它，且分数为正', () async {
      final AggregateResult r = await Aggregator.tagCandidates(
        _q(),
        only: <String>['itunes'],
        verify: false,
        fetch: _itunesFetcher('示例歌名', '示例歌手', 343.5),
      );
      expect(r.candidates, hasLength(1));
      expect(r.candidates.first.matchScore, greaterThan(0.6));
    });

    test('宽松模式也要给歌手不符的候选打负分（批量兜底据此跳过）', () async {
      final AggregateResult r = await Aggregator.tagCandidates(
        _q(),
        only: <String>['itunes'],
        verify: false,
        fetch: _itunesFetcher('示例歌名', '另一位歌手', 343.5),
      );
      // 宽松模式不淘汰（手动挑选要能看到），但必须打负分：批量兜底只认
      // matchScore ≥ 0.55 的候选，负分不会被当成命中写进去。
      expect(r.candidates, isNotEmpty);
      expect(r.candidates.first.matchScore, lessThan(0));
    });
  });

  group('iTunes 台湾区返回繁体', () {
    test('中文曲目的标题 / 歌手 / 专辑转成简体', () async {
      final AggregateResult r = await Aggregator.tagCandidates(
        _q(artist: '示例歌手', title: '示例歌名'),
        only: <String>['itunes'],
        fetch: _itunesFetcher('一無所有', '崔健', 343.5),
      );
      // 标题被转简后与本地不一致，这里只看繁转简这一半：直接验 Zh 的映射
      expect(Zh.toSimplified('一無所有'), '一无所有');
      expect(r.candidates, isEmpty); // 标题对不上，仍被淘汰
    });

    test('繁体标题转简后能与本地标题对上', () async {
      final AggregateResult r = await Aggregator.tagCandidates(
        _q(artist: '崔健', title: '一无所有'),
        only: <String>['itunes'],
        verify: false,
        fetch: _itunesFetcher('一無所有', '崔健', 343.5),
      );
      expect(r.candidates, hasLength(1));
      expect(r.candidates.first.title, '一无所有');
    });
  });
}
