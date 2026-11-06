// 封面打包存储的本机实测（0.2.93）。
//
// 目的：不靠推测，量出「一次读入内存」到底多快、打包文件多大。
// 用真实的测试曲库目录（如果存在），否则用合成数据。
//
// 运行：dart run tools/cover_pack_bench.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:musicorganizer/core/cover/thumb_pack.dart';
import 'package:musicorganizer/core/model/vfile.dart';

void main() async {
  stdout.writeln('=== 封面打包存储实测 ===');
  const int n = 900;
  const int thumbBytes = 30 * 1024; // 实测平均 37.8KB，取保守的 30KB

  // ① 编码：900 张 30KB
  final Map<String, String> keys = <String, String>{};
  final Map<String, Uint8List> blobs = <String, Uint8List>{};
  for (int i = 0; i < n; i++) {
    final String id = 'primary:Music/Artist$i/song-$i.mp3';
    final VFile f = VFile(
        docId: id, name: 'song-$i.mp3', size: 4000000 + i, lastModified: 1700000000000 + i);
    keys[id] = ThumbPackCodec.keyOf(f);
    blobs[id] = Uint8List.fromList(List<int>.filled(thumbBytes, i & 0xFF));
  }

  Stopwatch sw = Stopwatch()..start();
  final Uint8List packed = ThumbPackCodec.encode(keys: keys, blobs: blobs);
  sw.stop();
  final int encMs = sw.elapsedMilliseconds;
  stdout.writeln('① 编码 900 张：$encMs ms，大小 ${(packed.length / 1024 / 1024).toStringAsFixed(1)} MB');

  // ② 写盘
  final Directory tmp = await Directory.systemTemp.createTemp('mo_bench_');
  final File file = File('${tmp.path}${Platform.pathSeparator}pack.bin');
  sw = Stopwatch()..start();
  await file.writeAsBytes(packed, flush: true);
  sw.stop();
  final int writeMs = sw.elapsedMilliseconds;
  stdout.writeln('② 写盘：$writeMs ms');

  // ③ 读盘（模拟启动加载）
  sw = Stopwatch()..start();
  final Uint8List back = await file.readAsBytes();
  sw.stop();
  final int readMs = sw.elapsedMilliseconds;
  stdout.writeln('③ 读盘（一次）：$readMs ms，${(back.length / 1024 / 1024).toStringAsFixed(1)} MB');

  // ④ 解码
  sw = Stopwatch()..start();
  final ThumbPack? pack = ThumbPackCodec.decode(back);
  sw.stop();
  final int decMs = sw.elapsedMilliseconds;
  stdout.writeln('④ 解码成内存表：$decMs ms，${pack!.count} 条');

  // ⑤ 取 900 次（模拟滚动）
  sw = Stopwatch()..start();
  int hit = 0;
  for (int i = 0; i < n; i++) {
    final String id = 'primary:Music/Artist$i/song-$i.mp3';
    if (pack.entries[id] != null) hit++;
  }
  sw.stop();
  stdout.writeln('⑤ 取 900 次（纯内存）：${sw.elapsedMilliseconds} ms，命中 $hit');

  stdout.writeln('');
  stdout.writeln('=== 对比旧方案（一歌一文件）的理论代价 ===');
  stdout.writeln('旧方案：900 次文件打开+读 = 900 次跨进程调用（安卓 SAF）');
  stdout.writeln('新方案：1 次读 ${(back.length / 1024 / 1024).toStringAsFixed(1)} MB = ${readMs}ms + 解码 ${decMs}ms');

  await tmp.delete(recursive: true);
  stdout.writeln('');
  stdout.writeln('结论：新方案启动一次性约 ${readMs + decMs} ms，之后 900 次取值 ${sw.elapsedMilliseconds} ms 级。');
}
