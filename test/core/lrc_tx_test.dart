/// 同名 `.lrc` 与内嵌歌词同属一个事务（T-08）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart' hide Tags;
import 'package:musicorganizer/core/fs/desktop_file_store.dart';
import 'package:musicorganizer/core/model/tags.dart';
import 'package:musicorganizer/core/model/vfile.dart';
import 'package:musicorganizer/core/tag/tag_io.dart';
import 'package:musicorganizer/core/tx/journal.dart';
import 'package:musicorganizer/core/tx/tag_transaction.dart';

/// 建 `.lrc` 一定失败：用来验证「歌词文件写不进去时音频也要退回去」。
class _NoLrcStore extends DesktopFileStore {
  @override
  Future<VFile> createFile(VFile parent, String name, String mime) async {
    if (name.toLowerCase().endsWith('.lrc')) {
      throw const FileSystemException('模拟：歌词文件创建失败');
    }
    return super.createFile(parent, name, mime);
  }
}

void main() {
  late Directory dir;
  late DesktopFileStore store;
  late TagTransaction tx;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('mo_lrc_tx_');
    store = DesktopFileStore()..addRoot(dir.path);
    tx = TagTransaction(
        store: store, journal: Journal(File('${dir.path}/journal.jsonl')));
  });

  tearDown(() => dir.delete(recursive: true));

  File mp3(String name) {
    final File f = File('${dir.path}/$name');
    f.writeAsBytesSync(List<int>.filled(2048, 0xFF));
    return f;
  }

  Future<VFile> stat(File f) async => (await store.stat(f.path))!;

  test('写歌词时 .lrc 一起进事务，撤销两者同步回退', () async {
    final File f = mp3('a.mp3');
    final File lrc = File('${dir.path}/a.lrc')
      ..writeAsStringSync('[00:01]旧歌词', flush: true);
    final VFile v = await stat(f);

    const String batch = 'lyrics-b1';
    final String err = await tx.apply(v, <String, String>{'lyrics': '[00:02]新歌词'},
        batchId: batch, lrcText: '[00:02]新歌词');
    expect(err, '');
    expect(lrc.readAsStringSync(), '[00:02]新歌词');
    expect(TagIO.readLocal(f.readAsBytesSync(), '.mp3').get(Tags.lyrics),
        '[00:02]新歌词');

    final List<int> r = await tx.revertBatch(batch);
    expect(r[0], 1, reason: '一条记录回滚成功');
    expect(lrc.readAsStringSync(), '[00:01]旧歌词');
    expect(TagIO.readLocal(f.readAsBytesSync(), '.mp3').get(Tags.lyrics), '');
  });

  test('原来没有 .lrc：撤销时把它删掉，不留孤儿文件', () async {
    final File f = mp3('b.mp3');
    final VFile v = await stat(f);
    const String batch = 'lyrics-b2';
    expect(
        await tx.apply(v, <String, String>{'lyrics': '歌词'},
            batchId: batch, lrcText: '歌词'),
        '');
    final File lrc = File('${dir.path}/b.lrc');
    expect(lrc.existsSync(), isTrue);

    await tx.revertBatch(batch);
    expect(lrc.existsSync(), isFalse);
  });

  test('.lrc 写失败 → 音频标签一起还原（不留半成品）', () async {
    final Directory tmp = await Directory.systemTemp.createTemp('mo_lrc_bad_');
    addTearDown(() => tmp.delete(recursive: true));
    final _NoLrcStore bad = _NoLrcStore()..addRoot(tmp.path);
    final TagTransaction badTx = TagTransaction(
        store: bad, journal: Journal(File('${tmp.path}/journal.jsonl')));
    final File f = File('${tmp.path}/c.mp3')
      ..writeAsBytesSync(List<int>.filled(2048, 0xFF));
    final VFile v = (await bad.stat(f.path))!;

    final String err = await badTx.apply(
        v, <String, String>{'lyrics': '新歌词'},
        lrcText: '新歌词');
    expect(err, isNotEmpty);
    expect(err.contains('已还原原文件'), isTrue);
    expect(TagIO.readLocal(f.readAsBytesSync(), '.mp3').get(Tags.lyrics), '',
        reason: '音频必须回到写入前的状态');
  });

  test('不传 lrcText 时完全不碰同名 .lrc', () async {
    final File f = mp3('d.mp3');
    final File lrc = File('${dir.path}/d.lrc')
      ..writeAsStringSync('保持原样', flush: true);
    final VFile v = await stat(f);
    expect(await tx.apply(v, <String, String>{'title': '标题'}), '');
    expect(lrc.readAsStringSync(), '保持原样');
  });

  test('removeLrc 删除同名 .lrc，撤销时一起还原', () async {
    final File f = mp3('e.mp3');
    final VFile v = await stat(f);
    // 先造出标签 + 内嵌歌词 + .lrc
    expect(
        await tx.apply(
            v, <String, String>{'title': '标题', 'lyrics': '歌词'},
            lrcText: '歌词'),
        '');
    final File lrc = File('${dir.path}/e.lrc');
    expect(lrc.existsSync(), isTrue);

    // 清空全部标签与歌词（含 .lrc）
    const String batch = 'clearall';
    final String err = await tx.apply(
        v,
        <String, String>{
          for (final String k in Tags.keys) k: '',
          Tags.lyrics: '',
        },
        batchId: batch,
        removeLrc: true);
    expect(err, '');
    expect(lrc.existsSync(), isFalse);
    final Tags cleared = TagIO.readLocal(f.readAsBytesSync(), '.mp3');
    expect(cleared.get('title'), '');
    expect(cleared.get(Tags.lyrics), '');

    // 撤销：标签、内嵌歌词、.lrc 一起还原
    final List<int> r = await tx.revertBatch(batch);
    expect(r[0], 1);
    expect(lrc.existsSync(), isTrue);
    expect(lrc.readAsStringSync(), '歌词');
    final Tags back = TagIO.readLocal(f.readAsBytesSync(), '.mp3');
    expect(back.get('title'), '标题');
    expect(back.get(Tags.lyrics), '歌词');
  });
}
