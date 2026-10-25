import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/model/candidate.dart';
import 'package:musicorganizer/core/model/query.dart';
import 'package:musicorganizer/core/source/kugou.dart';
import 'package:musicorganizer/core/source/kuwo.dart';
import 'package:musicorganizer/core/source/migu.dart';
import 'package:musicorganizer/core/source/netease.dart';
import 'package:musicorganizer/core/source/qqmusic.dart';

/// 造查询上下文：文件名解析出 (艺人, 标题)，权重拉满（只信文件名）。
Query q({String artist = '', String title = ''}) => Query()
  ..filenameCandidates = <List<String>>[
    <String>[artist, title]
  ]
  ..embeddedTags = <String, String>{}
  ..filenameWeight = 1.0;

/// 必炸的取数回调：用来验证各家都吞异常不外抛。
Future<Object?> boom(String url, Map<String, String>? params) async {
  throw StateError('网络炸了');
}

void main() {
  const String artist = '示例歌手';
  const String title = '示例歌名';
  const String album = '示例专辑';

  group('网易云', () {
    test('解析候选：艺人拼串、年份取毫秒时间戳、封面追加 800 参数', () async {
      final List<Candidate> got = await NeteaseSource().search(
        q(artist: artist, title: title),
        fetch: (String url, Map<String, String>? params) async {
          expect(params!['s'], '$artist $title');
          expect(params['type'], '1');
          expect(params['limit'], '5');
          return <String, Object>{
            'result': <String, Object>{
              'songs': <Object>[
                <String, Object>{
                  'name': title,
                  'artists': <Object>[
                    <String, Object>{'name': artist},
                    <String, Object>{'name': '示例合唱'},
                  ],
                  'album': <String, Object>{
                    'name': album,
                    'publishTime': 1588291200000, // 2020-05-01 UTC
                    'picUrl': 'https://cdn.example/pic.jpg',
                  },
                  'duration': 258000,
                }
              ]
            }
          };
        },
      );
      expect(got.length, 1);
      expect(got.first.title, title);
      expect(got.first.artist, '$artist,示例合唱');
      expect(got.first.album, album);
      expect(got.first.year, '2020');
      expect(got.first.duration, 258.0);
      expect(got.first.coverUrl, 'https://cdn.example/pic.jpg?param=800y800');
      expect(got.first.source, 'netease');
      expect(got.first.confidence, NeteaseSource.baseConfidence);
    });

    test('最多返回 5 条', () async {
      final List<Object> songs = <Object>[];
      for (int i = 0; i < 8; i++) {
        songs.add(<String, Object>{'name': '$title$i'});
      }
      final List<Candidate> got = await NeteaseSource().search(
        q(title: title),
        fetch: (String url, Map<String, String>? params) async =>
            <String, Object>{'result': <String, Object>{'songs': songs}},
      );
      expect(got.length, 5);
    });

    test('没有检索串时直接返回空（不发请求）', () async {
      int calls = 0;
      final List<Candidate> got = await NeteaseSource().search(
        q(),
        fetch: (String url, Map<String, String>? params) async {
          calls++;
          return <String, Object>{};
        },
      );
      expect(got, isEmpty);
      expect(calls, 0);
    });

    test('返回体不是预期形状时返回空，不抛异常', () async {
      final List<Candidate> got = await NeteaseSource().search(
        q(title: title),
        fetch: (String url, Map<String, String>? params) async => 'not json',
      );
      expect(got, isEmpty);
      final List<Candidate> noResult = await NeteaseSource().search(
        q(title: title),
        fetch: (String url, Map<String, String>? params) async =>
            <String, Object>{'code': 405},
      );
      expect(noResult, isEmpty);
    });
  });

  group('QQ 音乐', () {
    test('解析候选：音轨取 index_album、封面拼 albummid、年份取 time_public', () async {
      final List<Candidate> got = await QqMusicSource().search(
        q(artist: artist, title: title),
        fetch: (String url, Map<String, String>? params) async {
          final String data = params!['data']!;
          expect(data, contains('DoSearchForQQMusicDesktop'));
          expect(data, contains('music.search.SearchCgiService'));
          expect(data, contains('"query":"$artist $title"'));
          expect(data, contains('"ct":19'));
          expect(data, contains('"cv":1859'));
          return <String, Object>{
            'req': <String, Object>{
              'code': 0,
              'data': <String, Object>{
                'body': <String, Object>{
                  'song': <String, Object>{
                    'list': <Object>[
                      <String, Object>{
                        'name': title,
                        'singer': <Object>[
                          <String, Object>{'name': artist},
                        ],
                        'album': <String, Object>{
                          'name': album,
                          'mid': 'DEMOALBUMMID',
                        },
                        'time_public': '2020-05-01',
                        'index_album': 3,
                        'interval': 258,
                      }
                    ]
                  }
                }
              }
            }
          };
        },
      );
      expect(got.length, 1);
      expect(got.first.title, title);
      expect(got.first.artist, artist);
      expect(got.first.album, album);
      expect(got.first.year, '2020');
      expect(got.first.track, '3');
      expect(got.first.duration, 258.0);
      expect(got.first.coverUrl,
          'https://y.gtimg.cn/music/photo_new/T002R800x800M000DEMOALBUMMID.jpg');
      expect(got.first.source, 'qqmusic');
      expect(got.first.confidence, QqMusicSource.baseConfidence);
    });

    test('缺 album 节点时封面留空，不抛异常', () async {
      final List<Candidate> got = await QqMusicSource().search(
        q(title: title),
        fetch: (String url, Map<String, String>? params) async =>
            <String, Object>{
          'req': <String, Object>{
            'data': <String, Object>{
              'body': <String, Object>{
                'song': <String, Object>{'list': <Object>[<String, Object>{}]}
              }
            }
          }
        },
      );
      expect(got.length, 1);
      expect(got.first.title, '');
      expect(got.first.coverUrl, '');
      expect(got.first.duration, isNull);
      expect(got.first.track, '');
    });

    test('返回体不是预期形状时返回空，不抛异常', () async {
      final List<Candidate> got = await QqMusicSource().search(
        q(title: title),
        fetch: (String url, Map<String, String>? params) async =>
            <Object>['unexpected'],
      );
      expect(got, isEmpty);
      final List<Candidate> emptyBody = await QqMusicSource().search(
        q(title: title),
        fetch: (String url, Map<String, String>? params) async =>
            <String, Object>{'req': <String, Object>{'code': 2001}},
      );
      expect(emptyBody, isEmpty);
    });
  });

  group('酷狗', () {
    test('解析候选：小写下划线字段，时长本来就是秒', () async {
      final List<Candidate> got = await KugouSource().search(
        q(artist: artist, title: title),
        fetch: (String url, Map<String, String>? params) async {
          expect(params!['keyword'], '$artist $title');
          expect(params['pagesize'], '5');
          expect(params['format'], 'json');
          return <String, Object>{
            'data': <String, Object>{
              'info': <Object>[
                <String, Object>{
                  'songname': title,
                  'singername': artist,
                  'album_name': album,
                  'duration': 258,
                }
              ]
            }
          };
        },
      );
      expect(got.length, 1);
      expect(got.first.title, title);
      expect(got.first.artist, artist);
      expect(got.first.album, album);
      expect(got.first.duration, 258.0);
      expect(got.first.source, 'kugou');
      expect(got.first.confidence, KugouSource.baseConfidence);
    });

    test('返回体不是预期形状时返回空，不抛异常', () async {
      final List<Candidate> got = await KugouSource().search(
        q(title: title),
        fetch: (String url, Map<String, String>? params) async => 42,
      );
      expect(got, isEmpty);
      final List<Candidate> noInfo = await KugouSource().search(
        q(title: title),
        fetch: (String url, Map<String, String>? params) async =>
            <String, Object>{'data': <String, Object>{}},
      );
      expect(noInfo, isEmpty);
    });
  });

  group('酷我', () {
    test('解析候选：字段全大写', () async {
      final List<Candidate> got = await KuwoSource().search(
        q(artist: artist, title: title),
        fetch: (String url, Map<String, String>? params) async {
          expect(params!['all'], '$artist $title');
          expect(params['rn'], '5');
          expect(params['rformat'], 'json');
          return <String, Object>{
            'abslist': <Object>[
              <String, Object>{
                'SONGNAME': title,
                'ARTIST': artist,
                'ALBUM': album,
                'DURATION': 258,
              }
            ]
          };
        },
      );
      expect(got.length, 1);
      expect(got.first.title, title);
      expect(got.first.artist, artist);
      expect(got.first.album, album);
      expect(got.first.duration, 258.0);
      expect(got.first.source, 'kuwo');
      expect(got.first.confidence, KuwoSource.baseConfidence);
    });

    test('SONGNAME 缺失时退回 NAME；标题仍为空则丢掉这条', () async {
      final List<Candidate> got = await KuwoSource().search(
        q(title: title),
        fetch: (String url, Map<String, String>? params) async =>
            <String, Object>{
          'abslist': <Object>[
            <String, Object>{'NAME': '$title（备用）'},
            <String, Object>{'ARTIST': artist, 'DURATION': 100},
            'not a map',
          ]
        },
      );
      expect(got.length, 1);
      expect(got.first.title, '$title（备用）');
    });

    test('返回体不是预期形状时返回空，不抛异常', () async {
      final List<Candidate> got = await KuwoSource().search(
        q(title: title),
        fetch: (String url, Map<String, String>? params) async => null,
      );
      expect(got, isEmpty);
    });
  });

  group('咪咕', () {
    test('解析候选：只留单曲、流派走白名单', () async {
      final List<Candidate> got = await MiguSource().search(
        q(artist: artist, title: title),
        fetch: (String url, Map<String, String>? params) async {
          expect(params!['text'], '$artist $title');
          expect(params['searchSwitch'], contains('"song":1'));
          expect(params['searchSwitch'], contains('"tagSong":1'));
          return <String, Object>{
            'songResultData': <String, Object>{
              'result': <Object>[
                <String, Object>{
                  'resourceType': '2',
                  'name': title,
                  'singers': <Object>[<String, Object>{'name': artist}],
                  'albums': <Object>[<String, Object>{'name': album}],
                  'tags': <Object>['示例地区', '流行'],
                }
              ]
            }
          };
        },
      );
      expect(got.length, 1);
      expect(got.first.title, title);
      expect(got.first.artist, artist);
      expect(got.first.album, album);
      expect(got.first.genre, '流行');
      expect(got.first.source, 'migu');
      expect(got.first.confidence, MiguSource.baseConfidence);
    });

    test('非单曲（resourceType 不为 2）被过滤掉', () async {
      final List<Candidate> got = await MiguSource().search(
        q(title: title),
        fetch: (String url, Map<String, String>? params) async =>
            <String, Object>{
          'songResultData': <String, Object>{
            'result': <Object>[
              <String, Object>{'resourceType': '3', 'name': album},
            ]
          }
        },
      );
      expect(got, isEmpty);
    });

    test('流派不在白名单里就留空；返回体畸形返回空，不抛异常', () async {
      final List<Candidate> got = await MiguSource().search(
        q(title: title),
        fetch: (String url, Map<String, String>? params) async =>
            <String, Object>{
          'songResultData': <String, Object>{
            'result': <Object>[
              <String, Object>{'name': title, 'tags': <Object>['示例场景']},
            ]
          }
        },
      );
      expect(got.length, 1);
      expect(got.first.genre, '');

      final List<Candidate> broken = await MiguSource().search(
        q(title: title),
        fetch: (String url, Map<String, String>? params) async =>
            <String, Object>{'songResultData': 'oops'},
      );
      expect(broken, isEmpty);
    });
  });

  group('国内五家共同约定', () {
    test('都声明支持标签 / 歌词 / 封面，置信度统一 0.60', () {
      final List<dynamic> sources = <dynamic>[
        NeteaseSource(),
        QqMusicSource(),
        KugouSource(),
        KuwoSource(),
        MiguSource(),
      ];
      for (final dynamic s in sources) {
        expect(s.supportsTags, isTrue);
        expect(s.supportsLyrics, isTrue);
        expect(s.supportsCover, isTrue);
        expect(s.label, isNotEmpty);
        expect(
            <double>[
              NeteaseSource.baseConfidence,
              QqMusicSource.baseConfidence,
              KugouSource.baseConfidence,
              KuwoSource.baseConfidence,
              MiguSource.baseConfidence,
            ],
            everyElement(0.60));
      }
    });

    test('key 与 Endpoints 登记的 key 一致', () {
      expect(NeteaseSource().key, 'netease');
      expect(QqMusicSource().key, 'qqmusic');
      expect(KugouSource().key, 'kugou');
      expect(KuwoSource().key, 'kuwo');
      expect(MiguSource().key, 'migu');
    });

    test('取数回调抛异常时吞掉并返回空列表', () async {
      expect(await NeteaseSource().search(q(title: title), fetch: boom), isEmpty);
      expect(await QqMusicSource().search(q(title: title), fetch: boom), isEmpty);
      expect(await KugouSource().search(q(title: title), fetch: boom), isEmpty);
      expect(await KuwoSource().search(q(title: title), fetch: boom), isEmpty);
      expect(await MiguSource().search(q(title: title), fetch: boom), isEmpty);
    });
  });
}
