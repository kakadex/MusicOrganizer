import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/model/query.dart';
import 'package:musicorganizer/core/source/aggregator.dart';
import 'package:musicorganizer/core/source/mb_client.dart';
import 'package:musicorganizer/core/source/offer_score.dart';
import 'package:musicorganizer/core/source/source_rank.dart';
import 'package:musicorganizer/core/source/tag_source.dart';

Query q({String artist = '示例歌手', String title = '示例歌名', double? duration}) =>
    Query()
      ..filenameCandidates = <List<String>>[
        <String>[artist, title]
      ]
      ..embeddedTags = <String, String>{}
      ..localDuration = duration;

/// 按 URL 分派：让「并发问多家」在离线测试里也能跑。
JsonFetcher dispatcher() => (String url, Map<String, String>? params) async {
      if (url.contains('music.163.com')) {
        return <String, Object>{
          'result': <String, Object>{
            'songs': <Object>[
              <String, Object>{
                'name': '示例歌名',
                'artists': <Object>[<String, Object>{'name': '示例歌手'}],
                'album': <String, Object>{
                  'name': '示例专辑',
                  'publishTime': 1577836800000,
                },
                'duration': 258000,
              }
            ]
          }
        };
      }
      if (url.contains('deezer')) {
        return <String, Object>{
          'data': <Object>[
            <String, Object>{
              'title': '示例歌名',
              'artist': <String, Object>{'name': '示例歌手'},
              'album': <String, Object>{'title': '示例专辑'},
              'duration': 258,
            }
          ]
        };
      }
      return <String, Object>{};
    };

void main() {
  group('offerScore 三道门槛', () {
    double score({
      String title = '示例歌名',
      String artist = '示例歌手',
      double? duration = 258,
      String cTitle = '示例歌名',
      String cArtist = '示例歌手',
      double? cDuration = 258,
      String source = 'netease',
      bool chinese = true,
      bool timed = false,
    }) =>
        offerScore(
          localTitle: title,
          localArtist: artist,
          localDuration: duration,
          candidateTitle: cTitle,
          candidateArtist: cArtist,
          candidateDuration: cDuration,
          source: source,
          chinese: chinese,
          hasTiming: timed,
        );

    test('完全一致得高分', () {
      expect(score() > 0.9, isTrue);
    });

    test('标题不像 → 淘汰', () {
      expect(score(cTitle: '完全不相干的另一首'), -1);
    });

    test('艺人对不上 → 淘汰', () {
      expect(score(cArtist: '另一位歌手'), -1);
    });

    test('时长差超过 6 秒 → 淘汰', () {
      expect(score(cDuration: 300), -1);
    });

    test('变体词（伴奏 / 现场）→ 淘汰', () {
      expect(score(cTitle: '示例歌名 伴奏'), -1);
      expect(score(cTitle: '示例歌名 (Live)'), -1);
    });

    test('缺时长时给中间值，不淘汰', () {
      expect(score(cDuration: null) > 0, isTrue);
      expect(score(duration: null) > 0, isTrue);
    });

    test('带时间轴 +0.05，源加成生效', () {
      final double plain = score(timed: false);
      final double timed = score(timed: true);
      expect((timed - plain).toStringAsFixed(2), '0.05');
      expect(sourceBonus('netease', true), 0.06);
      expect(sourceBonus('lrclib', false), 0.06);
      expect(sourceBonus('deezer', true), 0);
    });

    test('淘汰时能给出原因', () {
      final OfferScore r = scoreDetail(
        localTitle: '示例歌名',
        localArtist: '示例歌手',
        localDuration: 258,
        candidateTitle: '完全不相干的另一首',
        candidateArtist: '示例歌手',
        candidateDuration: 258,
        source: 'netease',
        chinese: true,
      );
      expect(r.rejected, isTrue);
      expect(r.reason, '标题差异过大');
    });
  });

  group('Aggregator', () {
    test('并发问多家并合并「同一首歌」', () async {
      final AggregateResult r = await Aggregator.tagCandidates(
        q(duration: 258),
        only: <String>['netease', 'deezer'],
        fetch: dispatcher(),
      );
      expect(r.errors, isEmpty);
      expect(r.totalBeforeDedupe, 2);
      expect(r.candidates.length, 1);
      expect(r.candidates.first.merged, 2);
      // 两家给的元数据一致，代表取置信度更高的那条（Deezer 0.75 > 网易 0.60）
      expect(r.candidates.first.source, 'deezer');
      expect(r.candidates.first.sources.contains('网易云'), isTrue);
      expect(r.candidates.first.sources.contains('Deezer'), isTrue);
    });

    test('中文曲目下国内源压过海外源（不会合并的两条）', () async {
      final AggregateResult r = await Aggregator.tagCandidates(
        q(duration: 258),
        only: <String>['netease', 'deezer'],
        fetch: (String url, Map<String, String>? params) async {
          // 标题相同、时长差 3 秒：既不合并（>2 秒），又都合格（≤3 秒）
          if (url.contains('music.163.com')) {
            return <String, Object>{
              'result': <String, Object>{
                'songs': <Object>[
                  <String, Object>{
                    'name': '示例歌名',
                    'artists': <Object>[<String, Object>{'name': '示例歌手'}],
                    'duration': 258000,
                  }
                ]
              }
            };
          }
          return <String, Object>{
            'data': <Object>[
              <String, Object>{
                'title': '示例歌名',
                'artist': <String, Object>{'name': '示例歌手'},
                'duration': 261,
              }
            ]
          };
        },
      );
      expect(r.candidates.length, 2);
      // 两条都过 offerScore；网易时长对得上且带国内源加成 → 综合分更高，排前
      expect(r.candidates.first.source, 'netease');
      expect(SourceRank.label(r.candidates.first.source), '网易云');
    });

    test('时长差超过容差的候选被丢掉', () async {
      final AggregateResult r = await Aggregator.tagCandidates(
        q(duration: 180), // 与候选 258 秒差 78 秒
        only: <String>['deezer'],
        fetch: dispatcher(),
      );
      expect(r.candidates, isEmpty);
    });

    test('变体词候选被剔除（Remix / 伴奏不算同一首）', () async {
      final AggregateResult r = await Aggregator.tagCandidates(
        q(title: '示例歌名'),
        only: <String>['deezer'],
        fetch: (String url, Map<String, String>? params) async {
          return <String, Object>{
            'data': <Object>[
              <String, Object>{
                'title': '示例歌名 (Remix)',
                'artist': <String, Object>{'name': '示例歌手'},
              },
              <String, Object>{
                'title': '示例歌名 伴奏',
                'artist': <String, Object>{'name': '示例歌手'},
              },
              <String, Object>{
                'title': '示例歌名',
                'artist': <String, Object>{'name': '示例歌手'},
              },
            ]
          };
        },
      );
      expect(r.candidates.length, 1);
      expect(r.candidates.first.title, '示例歌名');
    });

    test('标题更像的候选排在前面（同源同分时）', () async {
      final AggregateResult r = await Aggregator.tagCandidates(
        q(title: '示例歌名'),
        only: <String>['deezer'],
        fetch: (String url, Map<String, String>? params) async {
          return <String, Object>{
            'data': <Object>[
              <String, Object>{
                'title': '示例歌名 加长版现场', // 相似度低
                'artist': <String, Object>{'name': '示例歌手'},
              },
              <String, Object>{
                'title': '示例歌名', // 完全一致
                'artist': <String, Object>{'name': '示例歌手'},
              },
            ]
          };
        },
      );
      expect(r.candidates.first.title, '示例歌名');
    });

    test('聚合结果最多 10 条', () async {
      final AggregateResult r = await Aggregator.tagCandidates(
        q(),
        only: <String>['deezer'],
        fetch: (String url, Map<String, String>? params) async {
          final List<Object> data = <Object>[];
          for (int i = 0; i < 15; i++) {
            data.add(<String, Object>{
              'title': '示例歌名 $i',
              'artist': <String, Object>{'name': '示例歌手'},
            });
          }
          return <String, Object>{'data': data};
        },
      );
      expect(r.candidates.length, Aggregator.maxCandidates);
    });

    test('源出错时只记原因，不影响别家', () async {
      final AggregateResult r = await Aggregator.tagCandidates(
        q(),
        only: <String>['deezer', 'itunes'],
        fetch: (String url, Map<String, String>? params) async {
          if (url.contains('itunes')) throw StateError('boom');
          return <String, Object>{
            'data': <Object>[
              <String, Object>{
                'title': '示例歌名',
                'artist': <String, Object>{'name': '示例歌手'},
              }
            ]
          };
        },
      );
      expect(r.errors.containsKey('itunes'), isTrue);
      expect(r.candidates.length, 1);
    });
  });

  group('MbClient', () {
    test('解析 artist-credit 与首条发行', () {
      final MbRecording? rec = MbClient.parseRecording(<String, Object>{
        'title': '示例歌名',
        'artist-credit': <Object>[
          <String, Object>{'name': '示例歌手', 'joinphrase': ' & '},
          <String, Object>{'artist': <String, Object>{'name': '另一位'}},
        ],
        'first-release-date': '2020-05-01',
        'releases': <Object>[<String, Object>{'title': '示例专辑'}],
        'score': 98,
      });
      expect(rec, isNotNull);
      expect(rec!.title, '示例歌名');
      expect(rec.artist, '示例歌手 & 另一位');
      expect(rec.album, '示例专辑');
      expect(rec.date, '2020-05-01');
      expect(rec.score, 98);
    });

    test('标题或艺人为空视为无效条目', () {
      expect(MbClient.parseRecording(<String, Object>{'title': '只有标题'}), isNull);
      expect(
          MbClient.parseRecording(<String, Object>{
            'title': '示例歌名',
            'artist-credit': <Object>[<String, Object>{'name': '示例歌手'}],
          }),
          isNotNull);
    });

    test('Lucene 特殊字符转义', () {
      expect(MbClient.luceneEscape('a+b:c'), contains('\\\\'));
    });

    test('缓存命中后不再发请求；离线锁在连续失败后生效', () async {
      final MbClient client = MbClient();
      int calls = 0;
      Future<Object?> fake(String url, Map<String, String>? params) async {
        calls++;
        return <String, Object>{
          'recordings': <Object>[
            <String, Object>{
              'title': '示例歌名',
              'artist-credit': <Object>[<String, Object>{'name': '示例歌手'}],
            }
          ]
        };
      }

      final List<MbRecording> a =
          await client.searchRecordings('示例歌名', '示例歌手', fetch: fake);
      final List<MbRecording> b =
          await client.searchRecordings('示例歌名', '示例歌手', fetch: fake);
      expect(a.length, 1);
      expect(b.length, 1);
      expect(calls, 1, reason: '第二次应命中缓存');

      int fails = 0;
      for (int i = 0; i < MbClient.offlineAfterErrors; i++) {
        fails++;
        await client.searchRecordings('另一首 $i', null,
            fetch: (String url, Map<String, String>? params) async => null);
      }
      expect(fails, MbClient.offlineAfterErrors);
      expect(client.isOffline(), isTrue);
      // 离线后直接短路，不再发请求
      final List<MbRecording> off =
          await client.searchRecordings('示例歌名', '示例歌手', fetch: fake);
      expect(off, isEmpty);
    });

    test('离线冷却结束后再探一次，成功即解锁', () async {
      final MbClient client =
          MbClient(offlineCooldown: const Duration(milliseconds: 20));
      for (int i = 0; i < MbClient.offlineAfterErrors; i++) {
        await client.searchRecordings('示例歌名 $i', null,
            fetch: (String url, Map<String, String>? params) async => null);
      }
      expect(client.isOffline(), isTrue);

      // 冷却期内不发请求
      await client.searchRecordings('示例歌名', null,
          fetch: (String url, Map<String, String>? params) async =>
              <String, Object>{'recordings': <Object>[]});
      expect(client.isOffline(), isTrue);

      // 冷却结束 → 再探一次就恢复
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(client.isOffline(), isFalse);
      await client.searchRecordings('示例歌名', null,
          fetch: (String url, Map<String, String>? params) async =>
              <String, Object>{'recordings': <Object>[]});
      expect(client.isOffline(), isFalse);
    });
  });

  group('标签候选同样要过 offerScore', () {
    /// 网易云返回两条同标题条目：一条是垃圾（歌手 yyyyyy），一条是正版。
    JsonFetcher songs(List<String> artists) =>
        (String url, Map<String, String>? params) async => <String, Object>{
              'result': <String, Object>{
                'songs': <Object>[
                  for (final String a in artists)
                    <String, Object>{
                      'name': '新贵妃醉酒',
                      'artists': <Object>[<String, Object>{'name': a}],
                      'album': <String, Object>{'name': '新贵妃醉酒'},
                      'duration': 275000,
                    }
                ]
              }
            };

    test('歌手是 yyyyyy 的同名条目被淘汰，只留正版', () async {
      final AggregateResult r = await Aggregator.tagCandidates(
        q(artist: '李玉刚', title: '新贵妃醉酒', duration: 275),
        only: <String>['netease'],
        fetch: songs(<String>['yyyyyy', '李玉刚']),
      );
      expect(r.candidates.length, 1);
      expect(r.candidates.first.artist, '李玉刚');
      // 综合分要能被界面用上
      expect(r.candidates.first.matchScore, greaterThan(0.6));
    });

    test('本地没有歌手信息时，也不会挑走垃圾条目', () async {
      final AggregateResult r = await Aggregator.tagCandidates(
        q(artist: '', title: '新贵妃醉酒', duration: 275),
        only: <String>['netease'],
        fetch: songs(<String>['yyyyyy', '李玉刚']),
      );
      expect(r.candidates.length, 1);
      expect(r.candidates.first.artist, '李玉刚');
    });

    test('歌手完全对不上（不是噪声）也要淘汰，宁可不写', () async {
      final AggregateResult r = await Aggregator.tagCandidates(
        q(artist: '李玉刚', title: '新贵妃醉酒', duration: 275),
        only: <String>['netease'],
        fetch: songs(<String>['别人的名字']),
      );
      expect(r.candidates, isEmpty);
    });

    test('手动匹配（verify: false）不淘汰，只把不像的排后面', () async {
      final AggregateResult r = await Aggregator.tagCandidates(
        q(artist: '李玉刚', title: '新贵妃醉酒', duration: 275),
        only: <String>['netease'],
        fetch: songs(<String>['别人的名字', '李玉刚']),
        verify: false,
      );
      expect(r.candidates.length, 2, reason: '手动挑选要能看到全部候选');
      expect(r.candidates.first.artist, '李玉刚', reason: '像的那条排前面');
    });
  });
}
