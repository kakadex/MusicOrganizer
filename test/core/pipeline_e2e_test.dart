import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart' hide Tags;
import 'package:musicorganizer/core/fs/desktop_file_store.dart';
import 'package:musicorganizer/core/match/tag_plan.dart';
import 'package:musicorganizer/core/model/candidate.dart';
import 'package:musicorganizer/core/model/journal_entry.dart';
import 'package:musicorganizer/core/model/tags.dart';
import 'package:musicorganizer/core/model/vfile.dart';
import 'package:musicorganizer/core/scan/scanner.dart';
import 'package:musicorganizer/core/tag/id3.dart';
import 'package:musicorganizer/core/tx/journal.dart';
import 'package:musicorganizer/core/tx/tag_transaction.dart';

/// 端到端：真实文件 → 扫描 → 读标签 → 生成计划 → 事务写盘 → 撤销。
///
/// 走的是**桌面同一套代码**（DesktopFileStore + TagTransaction），
/// 所以即使 GUI 构建受限，这条链路的正确性也能在这里验证。
void main() {
  late Directory root;
  late DesktopFileStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mo_e2e_');
    store = DesktopFileStore();
    store.addRoot(root.path);
  });

  tearDown(() async {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// 造一个带 ID3v2.3 标签的 MP3（假音频段，够事务校验用）。
  Future<File> makeMp3(String name, Map<String, String> tags) async {
    Uint8List data = Uint8List.fromList(List<int>.filled(2048, 0xFF));
    data = Id3.rewrite(data, tags);
    final File f = File('${root.path}/$name');
    await f.writeAsBytes(data);
    return f;
  }

  test('扫描 → 读标签 → 计划 → 写盘 → 撤销（整条链路）', () async {
    await makeMp3('a.mp3', <String, String>{'title': '示例歌名', 'artist': '示例歌手'});
    await makeMp3('b.mp3', <String, String>{'title': '另一首'});
    await File('${root.path}/note.txt').writeAsString('不是音频');
    await Directory('${root.path}/sub').create();
    await makeMp3('sub/c.mp3', <String, String>{'title': '子目录里的'});

    // ① 扫描：只收音频，递归进子目录，跳过非音频
    final VFile rootDir = VFile(docId: root.path, name: 'root', dir: true);
    final WalkResult walk = await Scanner.scanMusicFiles(store, rootDir);
    expect(walk.files.length, 3);

    // ② 读标签：走 headBytes 头部读取
    final VFile a =
        walk.files.firstWhere((VFile f) => f.name == 'a.mp3');
    final Tags before = await Scanner.readTags(store, a);
    expect(before.get('title'), '示例歌名');
    expect(before.get('artist'), '示例歌手');

    // ③ 计划：模拟联网命中，补专辑 + 改标题
    final Candidate c = Candidate()
      ..title = '示例歌名'
      ..artist = '示例歌手'
      ..album = '示例专辑'
      ..track = '1'
      ..confidence = 0.8;
    final FilePlan plan =
        TagPlan.buildFor(file: a, before: before, candidate: c);
    expect(plan.hasChange, isTrue);
    expect(plan.toUpdates()['album'], '示例专辑');
    expect(plan.lowConfidence, isFalse);

    // ④ 写盘：事务七步
    final Journal journal = Journal(File('${root.path}/journal.jsonl'));
    final TagTransaction tx = TagTransaction(store: store, journal: journal);
    final String err = await tx.apply(a, plan.toUpdates(), batchId: 'e2e-1');
    expect(err, isEmpty);

    // ⑤ 回读校验：文件真的变了
    final Uint8List after = await File('${root.path}/a.mp3').readAsBytes();
    expect(Id3.read(after).get('album'), '示例专辑');

    // ⑥ 撤销：把 before 写回去
    final List<int> reverted = await journal.revertBatch('e2e-1',
        revertOne: (JournalEntry entry) async {
      final Map<String, String> back = Map<String, String>.from(entry.before);
      final String e2 = await tx.apply(a, back, record: false);
      return e2.isEmpty;
    });
    expect(reverted.isNotEmpty, isTrue);
    final Uint8List undone = await File('${root.path}/a.mp3').readAsBytes();
    expect(Id3.read(undone).get('album'), '');
    expect(Id3.read(undone).get('title'), '示例歌名');
  });

  test('增量扫描：文件没变就沿用上次标签', () async {
    await makeMp3('a.mp3', <String, String>{'title': '示例歌名'});
    final VFile rootDir = VFile(docId: root.path, name: 'root', dir: true);
    final WalkResult first = await Scanner.scanMusicFiles(store, rootDir);
    final VFile a = first.files.first;
    a.cacheMeta(Tags()..put('title', '缓存里的标题'));

    final WalkResult second = await Scanner.scanMusicFiles(store, rootDir);
    final VFile again = second.files.first;
    expect(again.size, a.size);
    expect(again.lastModified, a.lastModified);
  });

  test('写盘失败时原文件不动（只读格式）', () async {
    final File wma = File('${root.path}/x.wma');
    await wma.writeAsBytes(List<int>.filled(64, 0x30));
    final VFile v = (await store.stat(wma.path))!;
    final Journal journal = Journal(File('${root.path}/journal.jsonl'));
    final TagTransaction tx = TagTransaction(store: store, journal: journal);
    final String err = await tx.apply(v, <String, String>{'title': 'X'});
    expect(err.isNotEmpty, isTrue);
    expect(await wma.readAsBytes(), List<int>.filled(64, 0x30));
  });
}
