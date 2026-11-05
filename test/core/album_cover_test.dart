/// 专辑封面第二跳与酷狗 / 酷我封面地址拼装的离线回归。
///
/// 全部走注入的假 fetch，不联网；端点注册表用默认地址。
library;

import 'package:musicorganizer/core/model/candidate.dart';
import 'package:musicorganizer/core/source/album_cover.dart';
import 'package:musicorganizer/core/source/kugou.dart';
import 'package:musicorganizer/core/source/kuwo.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AlbumCover.lookup', () {
    test('专辑名为空不联网', () async {
      Object? asked;
      final AlbumCoverLookup r = await AlbumCover.lookup('', '周杰伦',
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
        fetch: (String url, Map<String, String>? params) async {
          asked.add(url);
          if (url.contains('deezer')) {
            return <String, Object?>{
              'data': <Object?>[
                <String, Object?>{
                  'title': '新长征路上的摇滚',
                  'cover_xl': 'https://e-cdns-images.dzcdn.net/images/cover/a/1000x1000-000000-80-0-0.jpg',
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

    test('两家都空返回空串', () async {
      final AlbumCoverLookup r = await AlbumCover.lookup('不存在的专辑', '没有人',
          fetch: (String url, Map<String, String>? params) async =>
              <String, Object?>{});
      expect(r.url, '');
      expect(r.source, '');
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
