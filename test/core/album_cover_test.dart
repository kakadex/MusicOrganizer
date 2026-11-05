/// 专辑封面第二跳、缓存与限流标记的离线回归。
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

/// 所有主机都「在冷却」（模拟被限流）。
bool Function(String host) alwaysBlocked() => (String host) => true;

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

  group('AlbumCover.lookup', () {
    test('专辑名为空不联网', () async {
      Object? asked;
      final AlbumCoverLookup r = await AlbumCover.lookup('', '周杰伦',
          isBlocked: neverBlocked(),
          fetch: (String url, Map<String, String>? params) async {
            asked = url;
            return <String, Object?>{};
          });
      expect(r.url, '');
      expect(asked, isNull);
    });

    test('Deezer 命中 cover_xl 直接用，不问 iTunes', () async {
      final List<String> asked = <String>[];
      final AlbumCoverLookup r = await AlbumCover.lookup(
        '新长征路上的摇滚',
        '崔健',
        isBlocked: neverBlocked(),
        fetch: (String url, Map<String, String>? params) async {
          asked.add(url);
          if (url.contains('deezer')) {
            return <String, Object?>{
              'data': <Object?>[
                <String, Object?>{
                  'title': '新长征路上的摇滚',
                  'cover_xl':
                      'https://e-cdns-images.dzcdn.net/images/cover/a/1000x1000-000000-80-0-0.jpg',
                },
              ],
            };
          }
          return <String, Object?>{};
        },
      );
      expect(r.url, contains('1000x1000'));
      expect(r.source, 'deezer');
      expect(asked.length, 1, reason: 'Deezer 命中后不应再问 iTunes');
    });

    test('Deezer 无图时 iTunes 兜底且 entity=album', () async {
      String? itunesParams;
      final AlbumCoverLookup r = await AlbumCover.lookup(
        'Xin Chang Zheng',
        'Cui Jian',
        isBlocked: neverBlocked(),
        fetch: (String url, Map<String, String>? params) async {
          if (url.contains('deezer')) {
            return <String, Object?>{'data': <Object?>[]};
          }
          itunesParams = params?['entity'];
          return <String, Object?>{
            'results': <Object?>[
              <String, Object?>{
                'collectionName': 'Xin Chang Zheng',
                'artworkUrl100':
                    'https://is1-ssl.mzstatic.com/image/thumb/Music/100x100bb.jpg',
              },
            ],
          };
        },
      );
      expect(itunesParams, 'album', reason: '只搜专辑条目');
      expect(r.url, contains('600x600'), reason: '100 图升到 600');
      expect(r.source, 'itunes');
    });

    test('Deezer 冷却时跳过它、继续问 iTunes（不能直接放弃）', () async {
      final List<String> asked = <String>[];
      final AlbumCoverLookup r = await AlbumCover.lookup(
        '晴天',
        '周杰伦',
        isBlocked: (String host) => host == 'api.deezer.com',
        fetch: (String url, Map<String, String>? params) async {
          asked.add(url);
          return <String, Object?>{
            'results': <Object?>[
              <String, Object?>{
                'artworkUrl100':
                    'https://is1-ssl.mzstatic.com/image/thumb/Music/100x100bb.jpg',
              },
            ],
          };
        },
      );
      expect(asked.length, 1, reason: 'Deezer 在冷却，不该再发请求');
      expect(asked.single, contains('itunes.apple.com'));
      expect(r.source, 'itunes');
      expect(r.url, contains('600x600'));
    });

    test('Deezer 冷却 + iTunes 正常但没图 → 不算暂时性失败、不写负缓存', () async {
      final AlbumCoverCache cache = newCache();
      final AlbumCoverLookup r = await AlbumCover.lookup(
        '冷门专辑',
        '无名氏',
        cache: cache,
        isBlocked: (String host) => host == 'api.deezer.com',
        fetch: (String url, Map<String, String>? params) async =>
            <String, Object?>{'results': <Object?>[]},
      );
      expect(r.url, '');
      expect(r.temporary, isFalse, reason: 'iTunes 已正常应答，结论可信');
      expect(cache.size(), 0,
          reason: '还有源没应答，不能把「当时查不到」记 14 天');
    });

    test('两家都正常应答但没有图 → 返回空且不是暂时性失败', () async {
      final AlbumCoverLookup r = await AlbumCover.lookup('不存在的专辑', '没有人',
          isBlocked: neverBlocked(),
          fetch: (String url, Map<String, String>? params) async =>
              <String, Object?>{});
      expect(r.url, '');
      expect(r.source, '');
      expect(r.temporary, isFalse);
    });

    test('主机在冷却 → 暂时性失败、不发请求、不写缓存', () async {      final AlbumCoverCache cache = newCache();
      int calls = 0;
      final AlbumCoverLookup r = await AlbumCover.lookup(
        '某专辑',
        '某人',
        cache: cache,
        isBlocked: alwaysBlocked(),
        fetch: (String url, Map<String, String>? params) async {
          calls++;
          return <String, Object?>{};
        },
      );
      expect(r.url, '');
      expect(r.temporary, isTrue);
      expect(calls, 0, reason: '冷却中的主机不该再耗一次超时');
      expect(cache.size(), 0, reason: '限流不是「没图」，不能写负缓存');
    });

    test('并发查询串行执行，同一时刻最多一条在途', () async {
      int inFlight = 0;
      int maxInFlight = 0;
      Future<Object?> fake(String url, Map<String, String>? params) async {
        inFlight++;
        if (inFlight > maxInFlight) maxInFlight = inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        inFlight--;
        return <String, Object?>{};
      }

      await Future.wait(<Future<AlbumCoverLookup>>[
        AlbumCover.lookup('专辑一', '甲',
            isBlocked: neverBlocked(), fetch: fake, minIntervalMs: 0),
        AlbumCover.lookup('专辑二', '乙',
            isBlocked: neverBlocked(), fetch: fake, minIntervalMs: 0),
        AlbumCover.lookup('专辑三', '丙',
            isBlocked: neverBlocked(), fetch: fake, minIntervalMs: 0),
      ]);
      expect(maxInFlight, 1, reason: '专辑查询必须全局串行，避免打穿限流');
    });
  });

  group('AlbumCover.lookup 缓存', () {
    test('命中缓存后不再联网', () async {
      final AlbumCoverCache cache = newCache();
      cache.remember('晴天', '周杰伦', 'https://img.example.com/a.jpg');
      int calls = 0;
      final AlbumCoverLookup r = await AlbumCover.lookup(
        '晴天',
        '周杰伦',
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
      cache.remember('冷门专辑', '无名氏', '');
      int calls = 0;
      final AlbumCoverLookup r = await AlbumCover.lookup(
        '冷门专辑',
        '无名氏',
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
      Future<Object?> fake(String url, Map<String, String>? params) async {
        calls++;
        if (url.contains('deezer')) {
          return <String, Object?>{
            'data': <Object?>[
              <String, Object?>{'cover_xl': 'https://img.example.com/b.jpg'},
            ],
          };
        }
        return <String, Object?>{'results': <Object?>[]};
      }

      final AlbumCoverLookup first = await AlbumCover.lookup('同一张', '同一个人',
          cache: cache, isBlocked: neverBlocked(), fetch: fake, minIntervalMs: 0);
      expect(first.url, 'https://img.example.com/b.jpg');

      final AlbumCoverLookup second = await AlbumCover.lookup('同一张', '同一个人',
          cache: cache, isBlocked: neverBlocked(), fetch: fake, minIntervalMs: 0);
      expect(second.source, 'cache');
      expect(calls, 1, reason: '第二次不该再发请求');
    });

    test('同一专辑并发查询只发一次请求（进闸门后再查缓存）', () async {
      final AlbumCoverCache cache = newCache();
      int calls = 0;
      Future<Object?> fake(String url, Map<String, String>? params) async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (url.contains('deezer')) {
          return <String, Object?>{
            'data': <Object?>[
              <String, Object?>{'cover_xl': 'https://img.example.com/c.jpg'},
            ],
          };
        }
        return <String, Object?>{'results': <Object?>[]};
      }

      final List<AlbumCoverLookup> both = await Future.wait(<Future<AlbumCoverLookup>>[
        AlbumCover.lookup('同一张', '同一个人',
            cache: cache, isBlocked: neverBlocked(), fetch: fake, minIntervalMs: 0),
        AlbumCover.lookup('同一张', '同一个人',
            cache: cache, isBlocked: neverBlocked(), fetch: fake, minIntervalMs: 0),
      ]);
      expect(both[0].url, 'https://img.example.com/c.jpg');
      expect(both[1].url, 'https://img.example.com/c.jpg');
      expect(calls, 1, reason: '第二个调用者应命中刚写入的缓存');
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

      final AlbumCoverCache reopened = AlbumCoverCache.open(
          File('${tmp.path}/album_covers.json'));
      expect(reopened.size(), 2);
      expect(reopened.lookup('晴天', '周杰伦'), 'https://img.example.com/a.jpg');
      expect(reopened.lookup('冷门', '无名'), '');
    });

    test('清空后文件里的条目也没了', () {
      final AlbumCoverCache cache = newCache();
      cache.remember('晴天', '周杰伦', 'https://img.example.com/a.jpg');
      cache.clear();
      expect(cache.size(), 0);
      final AlbumCoverCache reopened = AlbumCoverCache.open(
          File('${tmp.path}/album_covers.json'));
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
