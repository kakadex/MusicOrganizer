// 临时探针：0.3.0 发布前回归（真实曲库，纯 Dart，只读）。
import 'dart:typed_data';

import 'package:musicorganizer/core/cleanup/cleaner.dart';
import 'package:musicorganizer/core/cover/folder_cover.dart';
import 'package:musicorganizer/core/cover/sidecar_cover.dart';
import 'package:musicorganizer/core/dedupe/content_sample.dart';
import 'package:musicorganizer/core/dedupe/duplicates.dart';
import 'package:musicorganizer/core/fs/desktop_file_store.dart';
import 'package:musicorganizer/core/model/duplicate_group.dart';
import 'package:musicorganizer/core/model/tags.dart';
import 'package:musicorganizer/core/model/vfile.dart';
import 'package:musicorganizer/core/organize/organizer.dart';
import 'package:musicorganizer/core/scan/scanner.dart';

Future<void> main(List<String> args) async {
  final String root = args.isNotEmpty ? args[0] : r'C:\Android\test\MP3X2026';
  final DesktopFileStore store = DesktopFileStore();
  store.addRoot(root);
  final VFile rootDir = VFile(docId: root, name: root, dir: true);
  final WalkResult walk = await Scanner.scanMusicFiles(store, rootDir);
  final List<VFile> audio = walk.files.where((VFile f) => f.audio()).toList();
  for (final VFile f in audio) {
    if (f.metaCached()) continue;
    final Tags t = await Scanner.readTags(store, f);
    f.cacheMeta(t, cover: await Scanner.hasCover(store, f),
        lyrics: t.get(Tags.lyrics).trim().isNotEmpty);
  }
  print('[SCAN] 音频 ${audio.length} 首');

  // 查重三遍
  final List<DuplicateGroup> g1 = Duplicates.find(audio);
  final Map<String, String> artistMap = <String, String>{};
  for (final DuplicateGroup g in g1) {
    for (final DuplicateItem it in g.files) {
      if (DuplicateGroup.artistKeyOf(it.file.stem()).isEmpty) {
        final Tags t = await Scanner.readTags(store, it.file);
        final String a = t.get('artist').trim();
        if (a.isNotEmpty) artistMap[it.file.docId] = a;
      }
    }
  }
  final List<DuplicateGroup> g2 = Duplicates.find(audio,
      tagArtist: (VFile f) => artistMap[f.docId] ?? '');
  await Duplicates.verifyContent(g2, (VFile f) async {
    try {
      return ContentSample(f.size, await store.headBytes(f, 65536),
          await store.tailBytes(f, 65536));
    } catch (_) {
      return null;
    }
  });
  int same = 0, diff = 0, unknown = 0;
  for (final DuplicateGroup g in g2) {
    if (g.content == DuplicateGroup.contentSame) {
      same++;
    } else if (g.content == DuplicateGroup.contentDiff) {
      diff++;
    } else {
      unknown++;
    }
  }
  print('[DEDUPE] 文件名分组 ${g1.length} → 加艺人 ${g2.length} → 内容一致 $same / 不同 $diff / 未知 $unknown');
  for (final DuplicateGroup g in g2) {
    print('   · ${g.files.length} 个 score=${g.score.toStringAsFixed(2)} suspect=${g.suspect} content=${g.content}');
    for (final DuplicateItem it in g.files) {
      print('       ${it.relative}');
    }
  }

  // 整理
  final List<MovePlan> all =
      Organizer.plan(audio, rootDocId: root, onlyUnorganized: false);
  int already = 0, needMove = 0;
  for (final MovePlan p in all) {
    final String cur = p.fromDir.split('/').last;
    if (p.targetPath.toLowerCase() == cur.toLowerCase()) {
      already++;
    } else {
      needMove++;
    }
  }
  print('[ORGANIZE] 识别出歌手 ${all.length} 首：已在正确目录 $already / 需要移动 $needMove');

  // 改名计划（清理规则 + 模板）
  final List<RenamePlan> rp = await Cleaner.planCleanup(store, audio);
  int rc = 0;
  for (final RenamePlan p in rp) {
    if (p.changed) rc++;
  }
  print('[RENAME 清理规则] ${rp.length} 条：要改 $rc');
  final List<RenamePlan> tp =
      await Cleaner.planTemplate(store, audio.take(300).toList(), '{artist} - {title}');
  int tc = 0;
  for (final RenamePlan p in tp) {
    if (p.changed) tc++;
  }
  print('[RENAME 模板] ${tp.length} 条：要改 $tc');

  // 文件夹封面
  int folders = 0, withCover = 0;
  final Set<String> dirs = <String>{};
  for (final VFile f in audio) {
    final String? p = f.parentId;
    if (p != null && p.isNotEmpty) dirs.add(p);
  }
  for (final String d in dirs) {
    folders++;
    final Uint8List? art = await FolderCover.find(
        store, VFile(docId: d, name: d.split('/').last, dir: true));
    if (art != null) withCover++;
  }
  print('[FOLDER COVER] 目录 $folders 个（含封面的 $withCover 个）');

  // 同名图片封面
  int sidecar = 0;
  final List<String> sidecarNames = <String>[];
  for (final VFile f in audio) {
    final Uint8List? art = await SidecarCover.find(store, f);
    if (art != null) {
      sidecar++;
      if (sidecarNames.length < 5) sidecarNames.add(f.pathAfterRoot());
    }
  }
  print('[SIDECAR COVER] 命中同名图片封面 $sidecar 首');
  for (final String n in sidecarNames) {
    print('   · $n');
  }
  FolderCover.invalidate();
  SidecarCover.invalidate();
}
