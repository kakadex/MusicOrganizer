/// 专辑封面第二跳、多源对比、缓存与「源不可用」判定的离线回归。
///
/// 全部走注入的假 fetch，不联网；端点注册表用默认地址。
/// 每个用例前重置串行闸门与节流状态，避免互相影响。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/model/candidate.dart';
import 'package:musicorganizer/core/source/album_cover.dart';
import 'package:musicorganizer/core/source/album_cover_cache.dart';
import 'package:musicorganizer/core/source/kugou.dart';
import 'package:musicorganizer/core/source/kuwo.dart';

/// 所有主机都「不在冷却」。
bool Function(String host) neverBlocked() => (String host) => false;

/// 所有主机都「在冷却」（模拟全都连不上）。
bool Function(String host) alwaysBlocked() => (String host) => true;

/// 本地专辑（各用例共用）。
const String localAlbum = '寂寞不痛';
const String localArtist = 'A-Lin';

/// 一个匹配本地专辑的酷狗专辑条目。
Map<String, Object?> kugouAlbum(Map<String, String> overwrite) =>
    <String, Object?>{
      'albumname': overwrite['album'] ?? localAlbum,
      'singername': overwrite['artist'] ?? localArtist,
      'imgurl':
          'http://imge.kugou.com/stdmusic/{size}/20220501/20220501000502296227.jpg',
    };

/// 一个匹配本地专辑的 iTunes 专辑条目。
Map<String, Object?> itunesAlbum() => <String, Object?>{
      'collectionName': localAlbum,
      'artistName': localArtist,
      'artworkUrl100':
          'https://is1-ssl.mzstatic.com/image/thumb/Music/100x100bb.jpg',
    };

void main() {
  late Directory tmp;

  setUp(() {
    AlbumCover.resetLimiter();
    tmp = Directory.systemTemp.createTempSync('album_cover_test');
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  AlbumCoverCache newCache() =>
      AlbumCoverCache(File('${tmp.path}/album_covers.json'));

  /// 按主机分派的假接口：默认什么也不返回。
  Future<Object?> Function(String, Map<String, String>?) fake(
    Map<String, Map<String, Object?>> byHost, {
    List<String>? asked,
  }) {
    return (String url, Map<String, String>? params) async {
      asked?.add(Uri.parse(url).host);
      for (final MapEntry<String, Map<String, Object?>> e in byHost.entries) {
        if (Uri.parse(url).host == e.key) return e.value;
      }
      return <String, Object?>{};
    };
  }

  group('AlbumCover.lookup 多源对比', () {
    test('专辑名为空或太泛不联网', () async {
      Object? asked;
      final AlbumCoverLookup r = await AlbumCover.lookup('   ', '周杰伦',
          isBlocked: neverBlocked(),
          fetch: (String url, Map<String, String>? params) async {
            asked = url;
            return <String, Object?>{};
          });
      expect(r.url, '');
      expect(asked, isNull);

      final AlbumCoverLookup g = await AlbumCover.lookup('未知专辑', '某人',
          isBlocked: neverBlocked(),
          fetch: (String url, Map<String, String>? params) async {
            asked = url;
            return <String, Object?>{};
          });
      expect(g.url, '');
      expect(asked, isNull, reason: '「未知专辑」搜了也只会拿到不相干的图');
    });

    test('所有能给图的源都要问到（网易云 / 酷狗 / Deezer / iTunes）', () async {
      final List<String> asked = <String>[];
      final AlbumCoverLookup r = await AlbumCover.lookup(
        localAlbum,
        localArtist,
        isBlocked: neverBlocked(),
        fetch: fake(<String, Map<String, Object?>>{
          'mobiles.kugou.com': <String, Object?>{
            'data': <String, Object?>{
              'info': <Object?>[kugouAlbum(<String, String>{})],
            },
          },
        }, asked: asked),
      );
      expect(asked.toSet(),
          containsAll(<String>['music.163.com', 'mobiles.kugou.com', 'itunes.apple.com']),
          reason: '就算酷狗已经给了图，也要把其余源问完再做对比');
      expect(r.source, 'kugou');
      expect(r.url, contains('/500/'), reason: '{size} 要换成 500');
      expect(r.url, startsWith('https://'));
    });

    test('多家结果做对比：挑与本地专辑最像的，不拿第一张返回的', () async {
      // 网易云第一条是别人的翻唱版（实测真的会这样），酷狗那条才是本尊
      final AlbumCoverLookup r = await AlbumCover.lookup(
        localAlbum,
        localArtist,
        isBlocked: neverBlocked(),
        fetch: fake(<String, Map<String, Object?>>{
          'music.163.com': <String, Object?>{
            'result': <String, Object?>{
              'albums': <Object?>[
                <String, Object?>{
                  'name': '给我一个理由忘记「A-lin 马嘉祺版」',
                  'picUrl': 'http://p2.music.126.net/wrong.jpg',
                  'artists': <Object?>[
                    <String, Object?>{'name': '小朶'},
                  ],
                },
              ],
            },
          },
          'mobiles.kugou.com': <String, Object?>{
            'data': <String, Object?>{
              'info': <Object?>[kugouAlbum(<String, String>{})],
            },
          },
        }),
      );
      expect(r.source, 'kugou', reason: '翻唱版标题对不上，应被淘汰');
      expect(r.url, isNot(contains('wrong.jpg')));
    });

    test('Deezer 命中给图也算（标题艺人一致）', () async {
      final AlbumCoverLookup r = await AlbumCover.lookup(
        localAlbum,
        localArtist,
        isBlocked: neverBlocked(),
        fetch: fake(<String, Map<String, Object?>>{
          'api.deezer.com': <String, Object?>{
            'data': <Object?>[
              <String, Object?>{
                'title': localAlbum,
                'cover_xl': 'https://img.example.com/big.jpg',
                'artist': <String, Object?>{'name': localArtist},
              },
            ],
          },
        }),
      );
      expect(r.source, 'deezer');
      expect(r.url, 'https://img.example.com/big.jpg');
    });

    test('一家不可用就问下一家：Deezer 在冷却时跳过、仍问 iTunes', () async {
      final List<String> asked = <String>[];
      final AlbumCoverLookup r = await AlbumCover.lookup(
        localAlbum,
        localArtist,
        isBlocked: (String host) => host == 'api.deezer.com',
        fetch: fake(<String, Map<String, Object?>>{
          'itunes.apple.com': <String, Object?>{
            'results': <Object?>[itunesAlbum()],
          },
        }, asked: asked),
      );
      expect(asked, isNot(contains('api.deezer.com')),
          reason: '冷却中的源不该再耗一次超时');
      expect(asked, contains('itunes.apple.com'));
      expect(r.source, 'itunes');
      expect(r.url, contains('600x600'));
    });

    test('各家都正常应答但都不像 → 空且不是暂时性失败', () async {
      final AlbumCoverLookup r = await AlbumCover.lookup('不存在的专辑', '没有人',
          isBlocked: neverBlocked(),
          fetch: fake(<String, Map<String, Object?>>{}));
      expect(r.url, '');
      expect(r.source, '');
      expect(r.temporary, isFalse);
    });

    test('全部源不可用 → 暂时性失败、不发请求、不写缓存', () async {
      final AlbumCoverCache cache = newCache();
      int calls = 0;
      final AlbumCoverLookup r = await AlbumCover.lookup(
        localAlbum,
        localArtist,
        cache: cache,
        isBlocked: alwaysBlocked(),
        fetch: (String url, Map<String, String>? params) async {
          calls++;
          return <String, Object?>{};
        },
      );
      expect(r.url, '');
      expect(r.temporary, isTrue);
      expect(calls, 0);
      expect(cache.size(), 0, reason: '连不上不是「没图」，不能写负缓存');
    });

    test('部分源不可用、其余应答无图 → 不算暂时性失败、不写负缓存', () async {
      final AlbumCoverCache cache = newCache();
      final AlbumCoverLookup r = await AlbumCover.lookup(
        '不存在的专辑',
        '没有人',
        cache: cache,
        isBlocked: (String host) => host == 'api.deezer.com',
        fetch: fake(<String, Map<String, Object?>>{}),
      );
      expect(r.url, '');
      expect(r.temporary, isFalse, reason: '其余源已正常应答，结论可信');
      expect(cache.size(), 0, reason: '还有源没应答，不能把「当时查不到」记 14 天');
    });

    test('并发查询串行执行，同一时刻最多一条在途', () async {
      int inFlight = 0;
      int maxInFlight = 0;
      Future<Object?> slow(String url, Map<String, String>? params) async {
        inFlight++;
        if (inFlight > maxInFlight) maxInFlight = inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        inFlight--;
        return <String, Object?>{};
      }

      await Future.wait(<Future<AlbumCoverLookup>>[
        AlbumCover.lookup('专辑一', '甲',
            isBlocked: neverBlocked(), fetch: slow, minIntervalMs: 0),
        AlbumCover.lookup('专辑二', '乙',
            isBlocked: neverBlocked(), fetch: slow, minIntervalMs: 0),
        AlbumCover.lookup('专辑三', '丙',
            isBlocked: neverBlocked(), fetch: slow, minIntervalMs: 0),
      ]);
      expect(maxInFlight, 1, reason: '专辑查询必须全局串行，避免打穿限流');
    });
  });

  group('AlbumCover.lookup 缓存', () {
    test('命中缓存后不再联网', () async {
      final AlbumCoverCache cache = newCache();
      cache.remember(localAlbum, localArtist, 'https://img.example.com/a.jpg');
      int calls = 0;
      final AlbumCoverLookup r = await AlbumCover.lookup(
        localAlbum,
        localArtist,
        cache: cache,
        isBlocked: neverBlocked(),
        fetch: (String url, Map<String, String>? params) async {
          calls++;
          return <String, Object?>{};
        },
      );
      expect(r.url, 'https://img.example.com/a.jpg');
      expect(r.source, 'cache');
      expect(calls, 0);
    });

    test('确认没图的负缓存也会跳过联网', () async {
      final AlbumCoverCache cache = newCache();
      cache.remember(localAlbum, localArtist, '');
      int calls = 0;
      final AlbumCoverLookup r = await AlbumCover.lookup(
        localAlbum,
        localArtist,
        cache: cache,
        isBlocked: neverBlocked(),
        fetch: (String url, Map<String, String>? params) async {
          calls++;
          return <String, Object?>{};
        },
      );
      expect(r.url, '');
      expect(r.source, 'cache');
      expect(calls, 0);
    });

    test('一次查到图会写回缓存，同一专辑第二次直接命中', () async {
      final AlbumCoverCache cache = newCache();
      int calls = 0;
      final Future<Object?> Function(String, Map<String, String>?) f =
          fake(<String, Map<String, Object?>>{
        'mobiles.kugou.com': <String, Object?>{
          'data': <String, Object?>{
            'info': <Object?>[kugouAlbum(<String, String>{})],
          },
        },
      });
      Future<Object?> counting(String url, Map<String, String>? params) {
        calls++;
        return f(url, params);
      }

      final AlbumCoverLookup first = await AlbumCover.lookup(localAlbum, localArtist,
          cache: cache, isBlocked: neverBlocked(), fetch: counting, minIntervalMs: 0);
      expect(first.source, 'kugou');

      final AlbumCoverLookup second = await AlbumCover.lookup(
          localAlbum, localArtist,
          cache: cache, isBlocked: neverBlocked(), fetch: counting, minIntervalMs: 0);
      expect(second.source, 'cache');
      expect(calls, 4, reason: '第二次不该再发请求（第一次问了四家）');
    });

    test('同一专辑并发查询只发一轮请求（进闸门后再查缓存）', () async {
      final AlbumCoverCache cache = newCache();
      int calls = 0;
      final Future<Object?> Function(String, Map<String, String>?) f =
          fake(<String, Map<String, Object?>>{
        'mobiles.kugou.com': <String, Object?>{
          'data': <String, Object?>{
            'info': <Object?>[kugouAlbum(<String, String>{})],
          },
        },
      });
      Future<Object?> counting(String url, Map<String, String>? params) {
        calls++;
        return f(url, params);
      }

      final List<AlbumCoverLookup> both = await Future.wait(<Future<AlbumCoverLookup>>[
        AlbumCover.lookup(localAlbum, localArtist,
            cache: cache, isBlocked: neverBlocked(), fetch: counting, minIntervalMs: 0),
        AlbumCover.lookup(localAlbum, localArtist,
            cache: cache, isBlocked: neverBlocked(), fetch: counting, minIntervalMs: 0),
      ]);
      expect(both[0].url, contains('/500/'));
      expect(both[1].url, contains('/500/'));
      expect(calls, 4, reason: '第二个调用者应命中刚写入的缓存，只跑一轮四家');
    });
  });

  group('AlbumCover.fromCandidates', () {
    test('取第一条带专辑名的候选，候选没艺人退本地艺人', () {
      final (String album, String artist) = AlbumCover.fromCandidates(
        <Candidate>[
          Candidate()..title = 'a',
          Candidate()
            ..title = 'b'
            ..album = '某专辑',
          Candidate()
            ..title = 'c'
            ..album = '另一张',
        ],
        '本地歌手',
      );
      expect(album, '某专辑');
      expect(artist, '本地歌手', reason: '候选 b 没填艺人');
    });

    test('全都没有专辑名返回空对', () {
      final (String album, String artist) =
          AlbumCover.fromCandidates(<Candidate>[Candidate()..title = 'x'], '谁');
      expect(album, '');
      expect(artist, '');
    });
  });

  group('AlbumCoverCache', () {
    test('缓存键忽略大小写与首尾空白', () {
      expect(AlbumCoverCache.keyOf(' 晴天 ', '周杰伦'),
          AlbumCoverCache.keyOf('晴天', ' 周杰伦 '));
      expect(AlbumCoverCache.keyOf('ABBey Road', 'The Beatles'),
          AlbumCoverCache.keyOf('abbey road', 'the beatles'));
    });

    test('命中图 90 天过期', () {
      int now = 1000;
      final AlbumCoverCache cache =
          AlbumCoverCache(File('${tmp.path}/a.json'), clock: () => now);
      cache.remember('晴天', '周杰伦', 'https://img.example.com/a.jpg');
      now += albumHitTtlMs - 1;
      expect(cache.lookup('晴天', '周杰伦'), 'https://img.example.com/a.jpg');
      now += 2;
      expect(cache.lookup('晴天', '周杰伦'), isNull);
    });

    test('「确认没图」14 天过期，过期后允许重查', () {
      int now = 1000;
      final AlbumCoverCache cache =
          AlbumCoverCache(File('${tmp.path}/a.json'), clock: () => now);
      cache.remember('冷门', '无名', '');
      now += albumMissTtlMs - 1;
      expect(cache.lookup('冷门', '无名'), '');
      now += 2;
      expect(cache.lookup('冷门', '无名'), isNull);
    });

    test('落盘后重新打开还能读到', () {
      final AlbumCoverCache cache = newCache();
      cache.remember('晴天', '周杰伦', 'https://img.example.com/a.jpg');
      cache.remember('冷门', '无名', '');
      expect(cache.save(), isTrue);

      final AlbumCoverCache reopened =
          AlbumCoverCache.open(File('${tmp.path}/album_covers.json'));
      expect(reopened.size(), 2);
      expect(reopened.lookup('晴天', '周杰伦'), 'https://img.example.com/a.jpg');
      expect(reopened.lookup('冷门', '无名'), '');
    });

    test('清空后文件里的条目也没了', () {
      final AlbumCoverCache cache = newCache();
      cache.remember('晴天', '周杰伦', 'https://img.example.com/a.jpg');
      cache.clear();
      expect(cache.size(), 0);
      final AlbumCoverCache reopened =
          AlbumCoverCache.open(File('${tmp.path}/album_covers.json'));
      expect(reopened.size(), 0);
    });
  });

  group('KugouSource.coverOf', () {
    test('hash 模板拼 500 图', () {
      expect(
        KugouSource.coverOf('{ABC123}.jpg'),
        'https://imge.kugou.com/stdmusic/500x500/{ABC123}.jpg',
      );
    });
    test('完整地址升档', () {
      expect(
        KugouSource.coverOf('http://imge.kugou.com/stdmusic/240x240/{X}.jpg'),
        'http://imge.kugou.com/stdmusic/500x500/{X}.jpg',
      );
    });
    test('空串与非法串留空', () {
      expect(KugouSource.coverOf(''), '');
      expect(KugouSource.coverOf('garbage'), '');
    });
  });

  group('KuwoSource.coverOf', () {
    test('hts_IMG 完整地址升到 500', () {
      expect(
        KuwoSource.coverOf('http://img4.kuwo.cn/star/albumcover/123/90.jpg'),
        'http://img4.kuwo.cn/star/albumcover/123/500.jpg',
      );
    });
    test('相对路径补域名', () {
      expect(
        KuwoSource.coverOf('abc/120.jpg'),
        'https://img4.kuwo.cn/star/albumcover/abc/500.jpg',
      );
    });
    test('协议相对地址补 https', () {
      expect(
        KuwoSource.coverOf('//img4.kuwo.cn/star/albumcover/a/150.jpg'),
        'https://img4.kuwo.cn/star/albumcover/a/500.jpg',
      );
    });
    test('空串留空', () {
      expect(KuwoSource.coverOf(''), '');
    });
  });
}
