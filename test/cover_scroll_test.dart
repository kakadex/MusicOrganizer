/// 滚动中只走便宜路径（0.2.90）。
///
/// 背景：用户反馈「快速滑动出现没有缩略图」。根因是一次滚动会瞬间冒出几十个
/// 新行，每行都去读 256KB 文件头，并发名额（4 个）全被「滑过就销毁」的行
/// 占满，真正停下要看的行反而排队。
///
/// 这里锁住：`allowExpensive=false` 时**绝对不能**读文件头，只能查磁盘小图。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/app/cover_cache.dart';
import 'package:musicorganizer/app/cover_thumb_cache.dart';
import 'package:musicorganizer/core/cover/thumb_policy.dart';
import 'package:musicorganizer/core/fs/file_store.dart';
import 'package:musicorganizer/core/model/vfile.dart';
import 'package:musicorganizer/app/repo.dart';

/// 记录 headBytes 调用的假存储（读文件头 = 贵路径）。
class _Store implements FileStore {
  int headReads = 0;

  @override
  Future<Uint8List> headBytes(VFile f, int maxBytes) async {
    headReads++;
    return Uint8List(0);
  }

  @override
  Future<T> runInteractive<T>(Future<T> Function() action) => action();

  @override
  Future<void> cancelPending(String token) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

VFile song(int i) => VFile(
    docId: 'album/song$i.mp3',
    parentId: 'album',
    name: 'song$i.mp3',
    size: 1000,
    lastModified: 1700000000000);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mo_scroll_');
    CoverThumbCache.instance.resetForTest();
    CoverThumbCache.dirOverride = () async => tmp;
    CoverThumbCache.encoderOverride = (Uint8List src, int width) async => src;
    CoverCache.instance.clear();
    Repo.instance.store = null;
  });

  tearDown(() async {
    CoverThumbCache.dirOverride = null;
    CoverThumbCache.encoderOverride = null;
    CoverThumbCache.instance.resetForTest();
    CoverCache.instance.clear();
    Repo.instance.store = null;
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('滚动中（allowExpensive=false）绝不读文件头', () async {
    final _Store st = _Store();
    Repo.instance.store = st;
    final VFile f = song(1);

    final Uint8List? art = await CoverCache.instance.load(f, allowExpensive: false);
    expect(art, isNull, reason: '磁盘没有小图时保持占位，不该现场读文件头');
    expect(st.headReads, 0, reason: '滚动中一次文件头都不许读');
  });

  test('滑停后（allowExpensive=true）才允许读文件头', () async {
    final _Store st = _Store();
    Repo.instance.store = st;
    final VFile f = song(2);

    await CoverCache.instance.load(f, allowExpensive: true);
    expect(st.headReads, greaterThan(0), reason: '停下后应该补读');
  });

  test('滚动中磁盘有小图时照样能秒出（便宜路径不受影响）', () async {
    final _Store st = _Store();
    Repo.instance.store = st;
    final VFile f = song(3);

    // 先往磁盘缓存写一张小图
    final Directory dir =
        Directory('${tmp.path}${Platform.pathSeparator}cover_thumbs');
    await dir.create(recursive: true);
    await File('${dir.path}${Platform.pathSeparator}'
            '${ThumbPolicy.fileName(ThumbPolicy.keyOf(f))}')
        .writeAsBytes(Uint8List.fromList(List<int>.filled(200, 0x44)));

    final Uint8List? art =
        await CoverCache.instance.load(f, allowExpensive: false);
    expect(art, isNotNull, reason: '有磁盘小图就必须给图');
    expect(st.headReads, 0, reason: '走的是便宜路径');
  });

  test('warm 只读磁盘小图，不读文件头', () async {
    final _Store st = _Store();
    Repo.instance.store = st;
    final VFile f = song(4);
    final Directory dir =
        Directory('${tmp.path}${Platform.pathSeparator}cover_thumbs');
    await dir.create(recursive: true);
    await File('${dir.path}${Platform.pathSeparator}'
            '${ThumbPolicy.fileName(ThumbPolicy.keyOf(f))}')
        .writeAsBytes(Uint8List.fromList(List<int>.filled(300, 0x55)));

    expect(await CoverThumbCache.instance.warm(f), isTrue);
    expect(CoverCache.instance.peek(f), isNotNull);
    expect(st.headReads, 0);
  });
}
