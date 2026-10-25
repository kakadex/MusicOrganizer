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
