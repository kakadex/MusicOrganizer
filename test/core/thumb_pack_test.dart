/// 封面缩略图打包格式的编解码（0.2.93）。
///
/// 这是新方案的地基：所有缩略图打进**一个文件**，启动时顺序读一次。
/// 编码错一个字节，整个封面缓存就废——所以这里把边界情况全部锁住。
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/cover/thumb_pack.dart';
import 'package:musicorganizer/core/model/vfile.dart';

VFile song(String id, {int size = 1000, int mtime = 1700000000000}) =>
    VFile(docId: id, name: '$id.mp3', size: size, lastModified: mtime);

Uint8List blob(int n, int fill) =>
    Uint8List.fromList(List<int>.filled(n, fill));

void main() {
  test('编码再解码：内容与字节完全一致', () {
    final Map<String, String> keys = <String, String>{
      'a/song1.mp3': ThumbPackCodec.keyOf(song('a/song1.mp3')),
      'a/song2.mp3': ThumbPackCodec.keyOf(song('a/song2.mp3')),
    };
    final Map<String, Uint8List> blobs = <String, Uint8List>{
      'a/song1.mp3': blob(100, 0x11),
      'a/song2.mp3': blob(250, 0x22),
    };

    final Uint8List packed = ThumbPackCodec.encode(keys: keys, blobs: blobs);
    final ThumbPack? pack = ThumbPackCodec.decode(packed);

    expect(pack, isNotNull);
    expect(pack!.count, 2);
    expect(pack.entries['a/song1.mp3'], blob(100, 0x11));
    expect(pack.entries['a/song2.mp3'], blob(250, 0x22));
  });

  test('过期判定：文件大小/修改时间变了，旧图不算新', () {
    final VFile f = song('a/song.mp3');
    final Map<String, String> keys = <String, String>{
      f.docId: ThumbPackCodec.keyOf(f),
    };
    final ThumbPack? pack = ThumbPackCodec.decode(ThumbPackCodec.encode(
      keys: keys,
      blobs: <String, Uint8List>{f.docId: blob(50, 0x33)},
    ));

    expect(pack!.isFresh(f), isTrue, reason: '同一个文件应判定为新鲜');
    expect(pack.isFresh(song('a/song.mp3', size: 999)), isFalse,
        reason: '大小变了要重做');
    expect(pack.isFresh(song('a/song.mp3', mtime: 1)), isFalse,
        reason: '修改时间变了要重做');
    expect(pack.isFresh(song('a/other.mp3')), isFalse, reason: '没存过的要重做');
  });

  test('空输入也能编解码（不炸、count=0）', () {
    final Uint8List packed = ThumbPackCodec.encode(
        keys: <String, String>{}, blobs: <String, Uint8List>{});
    final ThumbPack? pack = ThumbPackCodec.decode(packed);
    expect(pack, isNotNull);
    expect(pack!.count, 0);
  });

  test('空字节的条目被跳过（不能污染索引）', () {
    final VFile f = song('a/x.mp3');
    final Uint8List packed = ThumbPackCodec.encode(
      keys: <String, String>{f.docId: ThumbPackCodec.keyOf(f)},
      blobs: <String, Uint8List>{f.docId: Uint8List(0)},
    );
    expect(ThumbPackCodec.decode(packed)!.count, 0);
  });

  test('不是我们的文件：返回 null（调用方当没有缓存）', () {
    expect(ThumbPackCodec.decode(Uint8List(0)), isNull);
    expect(ThumbPackCodec.decode(blob(100, 0x00)), isNull);
    expect(ThumbPackCodec.decode(Uint8List.fromList(List<int>.filled(200, 0x41))),
        isNull);
  });

  test('数据被截断：返回 null 而不是崩溃', () {
    final VFile f = song('a/y.mp3');
    final Uint8List full = ThumbPackCodec.encode(
      keys: <String, String>{f.docId: ThumbPackCodec.keyOf(f)},
      blobs: <String, Uint8List>{f.docId: blob(500, 0x44)},
    );
    for (final int cut in <int>[10, 20, 30, full.length - 1]) {
      if (cut <= 0 || cut >= full.length) continue;
      expect(ThumbPackCodec.decode(Uint8List.sublistView(full, 0, cut)), isNull,
          reason: '截断到 $cut 字节时应判损坏');
    }
  });

  test('中文 docId（SAF 常见）能正确往返', () {
    const String id = 'primary:音乐/周杰伦/晴天.mp3';
    final VFile f = song(id);
    final ThumbPack? pack = ThumbPackCodec.decode(ThumbPackCodec.encode(
      keys: <String, String>{id: ThumbPackCodec.keyOf(f)},
      blobs: <String, Uint8List>{id: blob(80, 0x55)},
    ));
    expect(pack!.entries[id], blob(80, 0x55));
  });

  test('尺寸检查：900 首 × 30KB 打包后大小合理（不因索引膨胀失控）', () {
    final Map<String, String> keys = <String, String>{};
    final Map<String, Uint8List> blobs = <String, Uint8List>{};
    for (int i = 0; i < 900; i++) {
      final String id = 'primary:Music/Artist$i/song-$i.mp3';
      final VFile f = song(id, size: 5000000 + i);
      keys[id] = ThumbPackCodec.keyOf(f);
      blobs[id] = blob(30 * 1024, i & 0xFF);
    }
    final Uint8List packed = ThumbPackCodec.encode(keys: keys, blobs: blobs);
    final double mb = packed.length / 1024 / 1024;
    expect(mb, lessThan(40), reason: '900 首 30KB 应在 27MB 左右，索引开销不该超过 40MB');
    expect(ThumbPackCodec.decode(packed)!.count, 900);
  });
}
