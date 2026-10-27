import 'package:flutter_test/flutter_test.dart' hide Tags;
import 'package:musicorganizer/core/model/tags.dart';
import 'package:musicorganizer/core/model/vfile.dart';
import 'package:musicorganizer/core/scan/library_cache.dart';

VFile audio(String id, {int size = 100, int mtime = 5}) => VFile(
      docId: id,
      parentId: 'root',
      name: '$id.mp3',
      mime: 'audio/mpeg',
      size: size,
      lastModified: mtime,
    );

void main() {
  test('往返：标签 / 封面 / 时长全部保住', () {
    final VFile f = audio('a');
    f.cacheMeta(
      Tags()
        ..put('title', '晴天')
        ..put('artist', '周杰伦')
        ..put(Tags.lyrics, '[00:01.00]歌词'),
      cover: true,
      lyrics: true,
      durationMs: 269000,
      bitrateKbps: 320,
    );
    final Map<String, List<VFile>> back =
        LibraryCache.decode(LibraryCache.encode(<String, List<VFile>>{
      'root': <VFile>[f],
    }));

    expect(back.length, 1);
    final VFile g = back['root']!.first;
    expect(g.docId, 'a');
    expect(g.name, 'a.mp3');
    expect(g.size, 100);
    expect(g.lastModified, 5);
    expect(g.metaCached(), isTrue);
    expect(g.cachedTags!.get('title'), '晴天');
    expect(g.cachedTags!.get('artist'), '周杰伦');
    expect(g.cachedTags!.get(Tags.lyrics), '[00:01.00]歌词');
    expect(g.cachedHasCover, isTrue);
    expect(g.cachedHasLyrics, isTrue);
    expect(g.cachedDurationMs, 269000);
    expect(g.cachedBitrateKbps, 320);
    // 恢复出来的条目要能被增量扫描判定为「没变过」
    expect(g.size == f.size && g.lastModified == f.lastModified, isTrue);
  });

  test('目录与非音频不进缓存', () {
    final VFile dir = VFile(docId: 'd', name: '专辑', dir: true);
    final VFile txt = VFile(docId: 't', name: 't.txt', size: 10, lastModified: 1);
    final Map<String, List<VFile>> back =
        LibraryCache.decode(LibraryCache.encode(<String, List<VFile>>{
      'root': <VFile>[dir, txt, audio('a')],
    }));
    expect(back['root']!.length, 1);
    expect(back['root']!.first.docId, 'a');
  });

  test('没读过标签的条目也进缓存（列表先撑起来，标签后台补）', () {
    final Map<String, List<VFile>> back =
        LibraryCache.decode(LibraryCache.encode(<String, List<VFile>>{
      'root': <VFile>[audio('a')],
    }));
    expect(back['root']!.first.metaCached(), isFalse);
  });

  test('歌词过长不落盘，其余字段照旧', () {
    final VFile f = audio('a');
    f.cacheMeta(
      Tags()
        ..put('title', '长歌词')
        ..put(Tags.lyrics, 'x' * (LibraryCache.maxLyricsChars + 100)),
    );
    final Map<String, List<VFile>> back =
        LibraryCache.decode(LibraryCache.encode(<String, List<VFile>>{
      'root': <VFile>[f],
    }));
    final VFile g = back['root']!.first;
    expect(g.cachedTags!.get('title'), '长歌词');
    expect(g.cachedTags!.get(Tags.lyrics), '');
  });

  test('版本不符 / 结构异常 → 当没有缓存', () {
    expect(LibraryCache.decode(null), isEmpty);
    expect(LibraryCache.decode(<String, Object?>{'v': 999}), isEmpty);
    expect(LibraryCache.decode(<String, Object?>{'v': 1}), isEmpty);
    expect(
      LibraryCache.decode(<String, Object?>{
        'v': 1,
        'roots': <Object?>[1, 2, 3],
      }),
      isEmpty,
    );
    // 单条坏数据：整组丢弃，不掺半份缓存进去
    expect(
      LibraryCache.decode(<String, Object?>{
        'v': 1,
        'roots': <String, Object?>{
          'root': <Object?>[<String, Object?>{'n': '缺 docId'}],
        },
      }),
      isEmpty,
    );
  });

  test('同 docId 重复只留一条', () {
    final Map<String, List<VFile>> back =
        LibraryCache.decode(<String, Object?>{
      'v': 1,
      'roots': <String, Object?>{
        'root': <Object?>[
          <String, Object?>{'d': 'a', 'n': 'a.mp3', 's': 1, 't': 2},
          <String, Object?>{'d': 'a', 'n': 'a.mp3', 's': 1, 't': 2},
        ],
      },
    });
    expect(back['root']!.length, 1);
  });
}
