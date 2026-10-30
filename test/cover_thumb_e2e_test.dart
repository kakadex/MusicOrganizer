/// 封面链路端到端（0.2.59）：真文件 + 真解码 + 真落盘。
///
/// 验证两件事一起生效：
/// 1. 第一次取封面读文件头解析出原图（320px），顺手把缩略图缩到 160px 存盘；
/// 2. 清掉内存缓存后再取同一首，直接读磁盘小图（160px），不再读文件头。
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/app/cover_cache.dart';
import 'package:musicorganizer/app/cover_thumb_cache.dart';
import 'package:musicorganizer/app/repo.dart';
import 'package:musicorganizer/core/cover/thumb_policy.dart';
import 'package:musicorganizer/core/fs/desktop_file_store.dart';
import 'package:musicorganizer/core/model/vfile.dart';

/// 画一张纯色 PNG（真实编码）。
Future<Uint8List> solidPng(int size) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  canvas.drawRect(Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
      Paint()..color = const Color(0xFF3366CC));
  final ui.Picture picture = recorder.endRecording();
  final ui.Image image = await picture.toImage(size, size);
  final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

/// 带 ID3v2.3 APIC 的假 MP3（图片用真 PNG，好让缩略图那一步能解码）。
Uint8List mp3WithPngCover(Uint8List png) {
  final List<int> frame = <int>[
    0x00, // 编码
    0x69, 0x6D, 0x61, 0x67, 0x65, 0x2F, 0x70, 0x6E, 0x67, 0x00, // image/png
    0x03, // front cover
    0x00, // 空描述
    ...png,
  ];

  final List<int> body = <int>[
    0x41, 0x50, 0x49, 0x43, // 'APIC'
    (frame.length >> 24) & 0xFF,
    (frame.length >> 16) & 0xFF,
    (frame.length >> 8) & 0xFF,
    frame.length & 0xFF,
    0x00, 0x00,
    ...frame,
  ];

  final int tagSize = body.length;
  final List<int> out = <int>[
    0x49, 0x44, 0x33, 0x03, 0x00, 0x00,
    (tagSize >> 21) & 0x7F,
    (tagSize >> 14) & 0x7F,
    (tagSize >> 7) & 0x7F,
    tagSize & 0x7F,
    ...body,
    ...List<int>.filled(8192, 0x55),
  ];
  return Uint8List.fromList(out);
}

Future<int> pngWidth(Uint8List png) async {
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory lib;
  late Directory thumbs;

  setUp(() async {
    lib = await Directory.systemTemp.createTemp('mo_lib_');
    thumbs = await Directory.systemTemp.createTemp('mo_thumbs_');
    CoverCache.instance.clear();
    CoverThumbCache.instance.resetForTest();
    CoverThumbCache.dirOverride = () async => thumbs;
    Repo.instance.resetForTest();
  });

  tearDown(() async {
    CoverThumbCache.dirOverride = null;
    CoverThumbCache.instance.resetForTest();
    Repo.instance.resetForTest();
    for (final Directory d in <Directory>[lib, thumbs]) {
      try {
        await d.delete(recursive: true);
      } catch (_) {
        // 忽略
      }
    }
  });

  test('第一次解析原图并落盘缩略图；清内存后第二次直接读小图', () async {
    final Uint8List cover = await solidPng(320);
    final File mp3 = File('${lib.path}${Platform.pathSeparator}示例歌名.mp3');
    await mp3.writeAsBytes(mp3WithPngCover(cover));

    final DesktopFileStore store = DesktopFileStore()..addRoot(lib.path);
    Repo.instance.store = store;
    final VFile? file = await store.stat(mp3.path);
    expect(file, isNotNull);

    // 第一次：走「读文件头 + 解析 + 缩图存盘」
    final Uint8List? first = await CoverCache.instance.load(file!);
    expect(first, isNotNull);
    expect(await pngWidth(first!), 320, reason: '第一次拿到的是原图');

    // 等未 await 的后台落盘完成
    final Directory cacheDir = CoverThumbCache.instance.directory!;
    final File thumbFile = File('${cacheDir.path}${Platform.pathSeparator}'
        '${ThumbPolicy.fileName(ThumbPolicy.keyOf(file))}');
    for (int i = 0; i < 50 && !thumbFile.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(thumbFile.existsSync(), isTrue, reason: '缩略图应已落盘');

    // 第二次：清掉内存缓存，模拟下次启动
    CoverCache.instance.clear();
    final Uint8List? second = await CoverCache.instance.load(file);
    expect(second, isNotNull);
    expect(await pngWidth(second!), 160, reason: '第二次应直接读 160px 小图');
    expect(second.length, lessThan(first.length), reason: '小图必须比原图小');
  });
}
