import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart' hide Tags;
import 'package:musicorganizer/core/fs/desktop_file_store.dart';
import 'package:musicorganizer/core/model/journal_entry.dart';
import 'package:musicorganizer/core/model/tags.dart';
import 'package:musicorganizer/core/model/vfile.dart';
import 'package:musicorganizer/core/tag/tag_io.dart';
import 'package:musicorganizer/core/tx/journal.dart';
import 'package:musicorganizer/core/tx/tag_transaction.dart';

import '../support/gen.dart';

/// 回读校验失败注入：下一次 writeFromLocal 写入坏字节。
class _CorruptingStore extends DesktopFileStore {
  bool corruptNextWrite = false;

  @override
  Future<void> writeFromLocal(VFile f, File src) async {
    if (corruptNextWrite) {
      corruptNextWrite = false;
      await File(f.docId).writeAsBytes(List<int>.filled(64, 0));
    } else {
      await super.writeFromLocal(f, src);
    }
  }
}

/// 「写原文件这一步抛异常」注入（硬盘满 / U 盘被拔 / 文件被占用）。
class _ThrowingStore extends DesktopFileStore {
  bool throwOnNextWrite = false;

  @override
  Future<void> writeFromLocal(VFile f, File src) async {
    if (throwOnNextWrite) {
      throwOnNextWrite = false;
      throw const FileSystemException('磁盘已满');
    }
    await super.writeFromLocal(f, src);
  }
}

/// 连续 N 次写盘都抛异常：用来模拟「写入失败、连还原也失败」。
class _FailingStore extends DesktopFileStore {
  int failWrites = 0;

  @override
  Future<void> writeFromLocal(VFile f, File src) async {
    if (failWrites > 0) {
      failWrites--;
      throw const FileSystemException('磁盘已满');
    }
    await super.writeFromLocal(f, src);
  }
}

/// 最小 M4A（moov 在尾），供 track 非法值的副本校验失败测试。
Uint8List _synthMp4() {
  final Uint8List ftyp =
      atom('ftyp', concat(<Uint8List>[ascii('M4A '), be32(0x200), ascii('M4A mp42')]));
  final Uint8List mdat = atom('mdat', Uint8List(32));
  final Uint8List stco =
      atom('stco', concat(<Uint8List>[be32(0), be32(1), be32(ftyp.length + 8)]));
  final Uint8List moov = atom('moov', concat(<Uint8List>[
    atom('mvhd', Uint8List(100)),
    atom('trak', atom('mdia', atom('minf', atom('stbl', stco)))),
  ]));
  return concat(<Uint8List>[ftyp, mdat, moov]);
}

void main() {
  late Directory dir;
  late DesktopFileStore store;
  late Journal journal;
  late TagTransaction tx;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('mo_tx_');
    store = DesktopFileStore();
    store.addRoot(dir.path);
    journal = Journal(File('${dir.path}/journal.jsonl'));
    tx = TagTransaction(store: store, journal: journal);
  });

  tearDown(() => dir.delete(recursive: true));

  File mp3(String name) {
    final File f = File('${dir.path}/$name');
    f.writeAsBytesSync(List<int>.filled(2048, 0xFF));
    return f;
  }

  test('合并语义：只改 title，其余字段保留', () async {
    final File f = mp3('a.mp3');
    final VFile v = (await store.stat(f.path))!;
    expect(await tx.apply(v, <String, String>{'title': '原歌名', 'artist': '原歌手', 'album': '原专辑'}),
        '');
    expect(await tx.apply(v, <String, String>{'title': '新歌名'}), '');

    final Tags tags = TagIO.readLocal(await f.readAsBytes(), '.mp3');
    expect(tags.get('title'), '新歌名');
    expect(tags.get('artist'), '原歌手');
    expect(tags.get('album'), '原专辑');
  });

  test('副本校验失败 → 原文件不动', () async {
    final File f = File('${dir.path}/a.m4a');
    f.writeAsBytesSync(_synthMp4());
    final VFile v = (await store.stat(f.path))!;

    // M4A 的 trkn 只接受数字：'abc' 写进去读回为空 → 副本校验失败
    final String err = await tx.apply(v, <String, String>{'track': 'abc'});
    expect(err, isNotEmpty);
    expect(err.contains('字段校验失败'), isTrue);

    final Tags tags = TagIO.readLocal(await f.readAsBytes(), '.m4a');
    expect(tags.get('track'), '');
  });

  test('回读失败 → 从备份恢复，原文件不动', () async {
    final _CorruptingStore corrupt = _CorruptingStore();
    corrupt.addRoot(dir.path);
    final Journal j = Journal(File('${dir.path}/j2.jsonl'));
    final TagTransaction t = TagTransaction(store: corrupt, journal: j);

    final File f = mp3('b.mp3');
    final VFile v = (await corrupt.stat(f.path))!;
    expect(await t.apply(v, <String, String>{'title': '旧标题'}), '');

    corrupt.corruptNextWrite = true;
    final String err = await t.apply(v, <String, String>{'title': '新标题'});
    expect(err, isNotEmpty);
    expect(err.contains('回读校验失败'), isTrue);

    final Tags tags = TagIO.readLocal(await f.readAsBytes(), '.mp3');
    expect(tags.get('title'), '旧标题');
  });

  test('revertBatch 逆序回滚 + 追加 reverted 记录', () async {
    final List<VFile> files = <VFile>[];
    for (int i = 0; i < 3; i++) {
      final File f = mp3('f$i.mp3');
      final VFile v = (await store.stat(f.path))!;
      expect(await tx.apply(v, <String, String>{'title': '旧标题$i'}), '');
      files.add(v);
    }
    for (final VFile v in files) {
      expect(await tx.apply(v, <String, String>{'title': '新标题'}, batchId: 'B1'), '');
    }

    final List<int> r = await tx.revertBatch('B1');
    expect(r[0], 3); // 成功 3 首
    expect(r[1], 0);
    expect(r[2], 3);

    for (int i = 0; i < 3; i++) {
      final Tags tags = TagIO.readLocal(await File(files[i].docId).readAsBytes(), '.mp3');
      expect(tags.get('title'), '旧标题$i');
    }
    // 追加了 3 条 reverted 记录
    final List<JournalEntry> all = await journal.readAll();
    expect(all.where((JournalEntry e) => e.status == 'reverted').length, 3);
  });

  test('批次回滚：第 2 首失败后整批退回，第 3 首没被碰过', () async {
    final List<File> fs = <File>[mp3('p0.mp3'), mp3('p1.mp3'), mp3('p2.mp3')];
    final List<VFile> vs = <VFile>[
      for (final File f in fs) (await store.stat(f.path))!,
    ];
    // 先给三首都写上「旧标题」，作为回滚的对照值
    for (int i = 0; i < 3; i++) {
      expect(await tx.apply(vs[i], <String, String>{'title': '旧标题$i'}), '');
    }
    final Uint8List before2 = await fs[2].readAsBytes();

    // 用会写坏字节的 store：第 2 首的写盘会在回读校验这步失败
    final _CorruptingStore st = _CorruptingStore();
    st.addRoot(dir.path);
    final TagTransaction t2 =
        TagTransaction(store: st, journal: Journal(File('${dir.path}/jb.jsonl')));

    const String batch = 'BATCH-1';
    t2.beginBatch(batch);
    expect(await t2.apply(vs[0], <String, String>{'title': '新标题0'},
            batchId: batch),
        '');
    st.corruptNextWrite = true;
    final String err = await t2.apply(vs[1], <String, String>{'title': '新标题1'},
        batchId: batch);
    expect(err, isNotEmpty);

    // 整批退回
    final (int ok, int bad) = await t2.rollbackBatch(batch);
    expect(bad, 0);
    expect(ok, greaterThanOrEqualTo(1));

    // 第 1 首回到旧值；第 3 首压根没被写过（字节与之前完全一致）
    final Tags t0 = TagIO.readLocal(await fs[0].readAsBytes(), '.mp3');
    expect(t0.get('title'), '旧标题0');
    final Uint8List after2 = await fs[2].readAsBytes();
    expect(after2.length, before2.length);
    bool same = true;
    for (int i = 0; i < before2.length; i++) {
      if (before2[i] != after2[i]) same = false;
    }
    expect(same, isTrue);
  });

  test('批次 commit 后备份被清掉，rollback 不再有作用', () async {
    final File f = mp3('c0.mp3');
    final VFile v = (await store.stat(f.path))!;
    const String batch = 'BATCH-2';
    tx.beginBatch(batch);
    expect(await tx.apply(v, <String, String>{'title': '写入值'}, batchId: batch),
        '');
    await tx.commitBatch(batch);
    final (int ok, int bad) = await tx.rollbackBatch(batch);
    expect(ok, 0);
    expect(bad, 0);
    expect(TagIO.readLocal(await f.readAsBytes(), '.mp3').get('title'), '写入值');
  });

  test('写原文件抛异常：先恢复备份，报错不再说「原文件未修改」', () async {
    final File f = mp3('throw.mp3');
    final VFile v = (await store.stat(f.path))!;
    final _ThrowingStore throwing = _ThrowingStore();
    throwing.addRoot(dir.path);
    final Directory clean = await Directory.systemTemp.createTemp('mo_clean_');
    final TagTransaction t =
        TagTransaction(store: throwing, journal: journal, tempDir: clean);

    // 先写一笔正常内容，把「写之前」的字节定下来
    expect(await t.apply(v, <String, String>{'title': '原标题'}), '');
    final Uint8List beforeBytes = await f.readAsBytes();

    // 这次「写原文件」这一步会抛异常
    throwing.throwOnNextWrite = true;
    final String err = await t.apply(v, <String, String>{'title': '新标题'});

    expect(err, contains('已用备份恢复'), reason: '要如实说「已恢复」，不能说没动过');
    expect(err, isNot(contains('原文件未修改')));
    final Uint8List afterBytes = await f.readAsBytes();
    expect(afterBytes.length, beforeBytes.length);
    bool same = true;
    for (int i = 0; i < beforeBytes.length; i++) {
      if (beforeBytes[i] != afterBytes[i]) {
        same = false;
        break;
      }
    }
    expect(same, isTrue, reason: '原文件必须逐字节还原');
    final List<String> leftover = clean
        .listSync()
        .whereType<File>()
        .map((File e) => e.path.split(RegExp(r'[/\\]')).last)
        .where((String n) => n.startsWith('mo_tx_'))
        .toList();
    expect(leftover, isEmpty, reason: '备份临时文件必须被清理');
    await clean.delete(recursive: true);
  });

  test('回滚恢复失败的那首，备份不删（可重试）', () async {
    final File f1 = mp3('r1.mp3');
    final File f2 = mp3('r2.mp3');
    final VFile v1 = (await store.stat(f1.path))!;
    final VFile v2 = (await store.stat(f2.path))!;
    final _ThrowingStore throwing = _ThrowingStore();
    throwing.addRoot(dir.path);
    final Directory clean = await Directory.systemTemp.createTemp('mo_clean_');
    final TagTransaction t =
        TagTransaction(store: throwing, journal: journal, tempDir: clean);

    const String batch = 'BATCH-R';
    t.beginBatch(batch);
    expect(await t.apply(v1, <String, String>{'title': '新1'}, batchId: batch), '');
    expect(await t.apply(v2, <String, String>{'title': '新2'}, batchId: batch), '');

    // 恢复时抛异常（逆序先恢复第 2 首，会失败）
    throwing.throwOnNextWrite = true;
    final (int ok, int bad) = await t.rollbackBatch(batch);
    expect(ok, 1);
    expect(bad, 1);

    // 失败那首的备份必须保留，才能重试
    final List<String> leftover = clean
        .listSync()
        .whereType<File>()
        .map((File e) => e.path.split(RegExp(r'[/\\]')).last)
        .where((String n) => n.startsWith('mo_tx_'))
        .toList();
    expect(leftover, isNotEmpty, reason: '恢复失败的备份要保留，不能一起删');
    await clean.delete(recursive: true);
  });

  test('还原也失败：如实说「原文件可能已损坏」并给出备份真实路径', () async {
    final File f = mp3('double-fail.mp3');
    final VFile v = (await store.stat(f.path))!;
    final _FailingStore failing = _FailingStore();
    failing.addRoot(dir.path);
    final Directory clean = await Directory.systemTemp.createTemp('mo_clean_');
    final TagTransaction t =
        TagTransaction(store: failing, journal: journal, tempDir: clean);

    // 先正常写一笔，把「写之前」的字节定下来
    expect(await t.apply(v, <String, String>{'title': '原标题'}), '');

    // 写原文件抛 + 拿备份还原也抛
    failing.failWrites = 2;
    final String err = await t.apply(v, <String, String>{'title': '新标题'});

    expect(err, contains('原文件可能已损坏'));
    expect(err, isNot(contains('已用备份恢复')));
    expect(err, isNot(contains('原文件未修改')));

    // 错误串里要有备份的真实路径，且备份文件确实还在
    final List<File> backups = clean
        .listSync()
        .whereType<File>()
        .where((File e) =>
            e.path.split(RegExp(r'[/\\]')).last.startsWith('mo_tx_'))
        .toList();
    expect(backups, isNotEmpty, reason: '还原失败时备份必须保留');
    expect(err, contains(backups.first.path));

    await clean.delete(recursive: true);
  });

  test('journal 2000 条回绕', () async {
    final Journal j = Journal(File('${dir.path}/j3.jsonl'));
    for (int i = 0; i < 2005; i++) {
      await j.append(JournalEntry()..id = 'id$i');
    }
    final List<JournalEntry> all = await j.readAll();
    expect(all.length, 2000);
    expect(all.first.id, 'id5');
    expect(all.last.id, 'id2004');
  });
}
