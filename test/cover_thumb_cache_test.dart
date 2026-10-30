/// 封面缩略图磁盘缓存（0.2.59）。
///
/// 这里不测 dart:ui 的编码（那是引擎的事），只测这一层的骨架：
/// 键变了就换文件、写盘原子、读回来一致、超预算按最旧删、清空能用。
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/app/cover_thumb_cache.dart';
import 'package:musicorganizer/core/cover/thumb_policy.dart';
import 'package:musicorganizer/core/model/vfile.dart';

VFile song(String name, {int mtime = 1}) => VFile(
      docId: 'r/$name',
      parentId: 'r',
      name: name,
      size: 1000,
      lastModified: mtime,
    );

void main() {
  // dart:ui 的解码 / 编码要引擎，这里把测试绑定初始化起来
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('mo_thumb_');
    CoverThumbCache.instance.resetForTest();
    CoverThumbCache.dirOverride = () async => dir;
    // 编码器换成「原样返回」，测试跑在纯 Dart 环境里，不需要引擎解码
    CoverThumbCache.encoderOverride =
        (Uint8List src, int width) async => src;
  });

  tearDown(() async {
    CoverThumbCache.dirOverride = null;
    CoverThumbCache.encoderOverride = null;
    CoverThumbCache.instance.resetForTest();
    try {
      await dir.delete(recursive: true);
    } catch (_) {
      // 忽略
    }
  });

  Uint8List blob(int n) => Uint8List.fromList(List<int>.generate(n, (int i) => i & 0xFF));

  test('存进去再读回来一致，文件名是策略算出来的那个', () async {
    final VFile f = song('示例歌名.mp3');
    final Uint8List art = blob(256);
    await CoverThumbCache.instance.save(f, art);

    final Uint8List? back = await CoverThumbCache.instance.peek(f);
    expect(back, isNotNull);
    expect(back, art);

    final Directory cacheDir = CoverThumbCache.instance.directory!;
    final String path = '${cacheDir.path}${Platform.pathSeparator}'
        '${ThumbPolicy.fileName(ThumbPolicy.keyOf(f))}';
    expect(File(path).existsSync(), isTrue);
    // 不留临时文件
    final Iterable<String> tmps = cacheDir
        .listSync()
        .map((FileSystemEntity e) => e.path)
        .where((String p) => p.endsWith('.tmp'));
    expect(tmps, isEmpty);
  });

  test('没存过的读回 null（不代表没有封面）', () async {
    expect(await CoverThumbCache.instance.peek(song('没有缓存.mp3')), isNull);
  });

  test('文件改动（大小/时间变了）就换键，不会读到旧缩略图', () async {
    final VFile before = song('示例歌名.mp3', mtime: 1);
    await CoverThumbCache.instance.save(before, blob(128));
    final VFile after = song('示例歌名.mp3', mtime: 2);

    expect(await CoverThumbCache.instance.peek(after), isNull);
    expect(await CoverThumbCache.instance.peek(before), isNotNull);
  });

  test('太小的东西当坏文件不入缓存', () async {
    final VFile f = song('示例歌名.mp3');
    await CoverThumbCache.instance.save(f, Uint8List.fromList(<int>[1, 2, 3]));
    expect(await CoverThumbCache.instance.peek(f), isNull);
  });

  test('remove 只删这一首，clear 清空整个目录', () async {
    final VFile a = song('甲.mp3');
    final VFile b = song('乙.mp3');
    await CoverThumbCache.instance.save(a, blob(200));
    await CoverThumbCache.instance.save(b, blob(200));
    expect(await CoverThumbCache.instance.peek(a), isNotNull);

    await CoverThumbCache.instance.remove(a);
    expect(await CoverThumbCache.instance.peek(a), isNull);
    expect(await CoverThumbCache.instance.peek(b), isNotNull);

    await CoverThumbCache.instance.clear();
    expect(await CoverThumbCache.instance.peek(b), isNull);
  });

  test('缓存目录拿不到时整体静默关闭（返回 null，不抛异常）', () async {
    CoverThumbCache.instance.resetForTest();
    CoverThumbCache.dirOverride = () async => null;
    final VFile f = song('示例歌名.mp3');
    await CoverThumbCache.instance.save(f, blob(200));
    expect(await CoverThumbCache.instance.peek(f), isNull);
  });

  test('真实编码路径：大图缩到 160px、小图不放大，落盘的是能解码的 PNG', () async {
    CoverThumbCache.encoderOverride = null; // 走真实的 dart:ui 解码 + PNG 编码
    final VFile big = song('大图.mp3');
    final VFile small = song('小图', mtime: 2);

    final Uint8List bigPng = await _solidPng(320);
    final Uint8List smallPng = await _solidPng(64);

    await CoverThumbCache.instance.save(big, bigPng);
    await CoverThumbCache.instance.save(small, smallPng);

    final Uint8List? bigThumb = await CoverThumbCache.instance.peek(big);
    final Uint8List? smallThumb = await CoverThumbCache.instance.peek(small);
    expect(bigThumb, isNotNull);
    expect(smallThumb, isNotNull);

    expect(await _width(bigThumb!), 160, reason: '大图应缩到 160px');
    expect(await _width(smallThumb!), 64, reason: '比 160px 还小的图不该被放大');
    // 缩略图必须还能被引擎解开（不是半张图）
    expect(await _width(bigThumb), greaterThan(0));
  });
}

/// 用 canvas 画一张纯色 PNG（真实编码，能测到解码器那条路）。
Future<Uint8List> _solidPng(int size) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    Paint()..color = const Color(0xFF3366CC),
  );
  final ui.Picture picture = recorder.endRecording();
  final ui.Image image = await picture.toImage(size, size);
  final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

/// 解码未知 PNG 的宽度；解不开返回 0。
Future<int> _width(Uint8List png) async {
  ui.Codec? codec;
  ui.Image? image;
  try {
    codec = await ui.instantiateImageCodec(png);
    image = (await codec.getNextFrame()).image;
    return image.width;
  } catch (_) {
    return 0;
  } finally {
    image?.dispose();
    codec?.dispose();
  }
}
