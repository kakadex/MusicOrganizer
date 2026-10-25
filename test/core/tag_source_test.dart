import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/match/name_weight.dart';
import 'package:musicorganizer/core/model/candidate.dart';
import 'package:musicorganizer/core/model/query.dart';
import 'package:musicorganizer/core/source/deezer.dart';
import 'package:musicorganizer/core/source/itunes.dart';
import 'package:musicorganizer/core/source/source_registry.dart';
import 'package:musicorganizer/core/source/tag_source.dart';

Query q({
  String artist = '',
  String title = '',
  Map<String, String>? tags,
  double weight = 1.0,
}) =>
    Query()
      ..filenameCandidates = <List<String>>[
        <String>[artist, title]
      ]
      ..embeddedTags = tags ?? <String, String>{}
      ..filenameWeight = weight;

void main() {
  group('TagQuery 取值口径', () {
    test('权重 100% 只用文件名', () {
      final Query ctx = q(
          artist: '示例歌手', title: '示例歌名', tags: <String, String>{'title': '旧标题'});
      expect(TagQuery.title(ctx), '示例歌名');
      expect(TagQuery.artist(ctx), '示例歌手');
    });

    test('权重 0% 只用内嵌标签', () {
      final Query ctx = q(
          artist: '示例歌手',
          title: '示例歌名',
          tags: <String, String>{'title': '旧标题', 'artist': '旧歌手'},
          weight: 0.0);
      expect(TagQuery.title(ctx), '旧标题');
      expect(TagQuery.artist(ctx), '旧歌手');
    });

    test('检索串是「艺人 标题」', () {
      expect(TagQuery.term(q(artist: '示例歌手', title: '示例歌名')), '示例歌手 示例歌名');
      expect(TagQuery.term(q()), '');
    });

    test('中文曲目判定：含汉字且非日文', () {
      expect(TagQuery.isChineseTrack(q(title: '示例歌名')), isTrue);
      expect(TagQuery.isChineseTrack(q(title: 'Song Name')), isFalse);
      expect(TagQuery.isChineseTrack(q(title: 'ひらがな')), isFalse);
      expect(TagQuery.hasHan(null), isFalse);
    });
  });

  group('Deezer', () {
    test('解析候选（含封面与时长）', () async {
      final DeezerSource src = DeezerSource();
      final List<Candidate> got = await src.search(
        q(artist: '示例歌手', title: '示例歌名'),
        fetch: (String url, Map<String, String>? params) async {
          expect(params!['q'], '示例歌手 示例歌名');
          expect(params['limit'], '5');
          return <String, Object>{
            'data': <Object>[
              <String, Object>{
                'title': '示例歌名',
                'artist': <String, Object>{'name': '示例歌手'},
                'album': <String, Object>{
                  'title': '示例专辑',
                  'cover_xl': 'https://cdn.example/xl.jpg',
                },
                'duration': 258,
              }
            ]
          };
        },
      );
      expect(got.length, 1);
      expect(got.first.title, '示例歌名');
      expect(got.first.artist, '示例歌手');
      expect(got.first.album, '示例专辑');
      expect(got.first.duration, 258);
      expect(got.first.coverUrl, 'https://cdn.example/xl.jpg');
      expect(got.first.source, 'deezer');
      expect(got.first.confidence, DeezerSource.baseConfidence);
    });

    test('没有检索串时直接返回空（不发请求）', () async {
      int calls = 0;
      final List<Candidate> got = await DeezerSource().search(
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
      final List<Candidate> got = await DeezerSource().search(
        q(title: '示例歌名'),
        fetch: (String url, Map<String, String>? params) async => 'not json',
      );
      expect(got, isEmpty);
    });
  });

  group('iTunes', () {
    test('解析候选：年份取前四位、时长毫秒转秒、封面换 600', () async {
      final List<Candidate> got = await ItunesSource().search(
        q(artist: '示例歌手', title: '示例歌名'),
        fetch: (String url, Map<String, String>? params) async {
          expect(params!['term'], '示例歌手 示例歌名');
          expect(params['media'], 'music');
          return <String, Object>{
            'results': <Object>[
              <String, Object>{
                'trackName': '示例歌名',
                'artistName': '示例歌手',
                'collectionName': '示例专辑',
                'releaseDate': '2020-05-01T07:00:00Z',
                'trackTimeMillis': 258660,
                'artworkUrl100': 'https://cdn.example/a/100x100bb.jpg',
              }
            ]
          };
        },
      );
      expect(got.length, 1);
      expect(got.first.title, '示例歌名');
      expect(got.first.artist, '示例歌手');
      expect(got.first.album, '示例专辑');
      expect(got.first.year, '2020');
      expect(got.first.duration, 258.66);
      expect(got.first.coverUrl, 'https://cdn.example/a/600x600bb.jpg');
      expect(got.first.source, 'itunes');
    });

    test('封面尺寸替换的两种写法', () {
      expect(ItunesSource.coverUrl('https://x/100x100bb.jpg'),
          'https://x/600x600bb.jpg');
      expect(ItunesSource.coverUrl(''), '');
    });

    test('缺字段时留空而不报错', () async {
      final List<Candidate> got = await ItunesSource().search(
        q(title: '示例歌名'),
        fetch: (String url, Map<String, String>? params) async =>
            <String, Object>{'results': <Object>[<String, Object>{}]},
      );
      expect(got.length, 1);
      expect(got.first.title, '');
      expect(got.first.year, '');
      expect(got.first.duration, isNull);
    });
  });

  group('注册表', () {
    test('按 key 取源与能力位', () {
      expect(SourceRegistry.get('deezer'), isNotNull);
      expect(SourceRegistry.get('itunes'), isNotNull);
      expect(SourceRegistry.get('未知源'), isNull);
      expect(SourceRegistry.get(null), isNull);
      expect(SourceRegistry.supportsCover('deezer'), isTrue);
      expect(SourceRegistry.supportsLyrics('deezer'), isFalse);
      // 8 家标签源（国内五家 + MusicBrainz/Deezer/iTunes）
      expect(SourceRegistry.keys().length, 8);
      expect(SourceRegistry.all().length, 8);
      // 歌词源 5 家单独登记
      expect(SourceRegistry.lyricKeys().length, 5);
      expect(SourceRegistry.lyric('lrclib'), isNotNull);
      expect(SourceRegistry.lyric('没有这个源'), isNull);
      expect(SourceRegistry.lyrics(only: <String>['lrclib']).length, 1);
    });

    test('源声明的 key 与 Endpoints 登记的 key 一致', () {
      for (final TagSource s in SourceRegistry.all()) {
        expect(s.key, isNotEmpty);
        expect(s.label, isNotEmpty);
      }
      expect(NameWeight.defaultPercent, 20);
    });
  });
}
