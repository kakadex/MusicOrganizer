/// 标签事务写入（七步事务）。
///
/// 流程（R-04：任何标签写入必须走本类）：
///   before 快照 → 复制到本地缓存副本 → 在副本上写 → 读回校验副本
///   → 备份当前原文件 → 写回 → 回读校验（失败自动恢复备份）
///   → journal 追加 applied 记录。
/// 写盘串行：async 互斥队列保证同一文件 / 批量任务不会并发写。
library;

import 'dart:io';
import 'dart:typed_data';

import '../fs/file_store.dart';
import '../model/journal_entry.dart';
import '../model/tags.dart';
import '../model/vfile.dart';
import '../tag/tag_io.dart';
import 'journal.dart';

/// 标签事务写入（纯 Dart）。
class TagTransaction {
  TagTransaction({
    required this.store,
    required this.journal,
    this.onRefresh,
    Directory? tempDir,
  }) : tempDir = tempDir ?? Directory.systemTemp;

  final FileStore store;
  final Journal journal;

  /// 写盘后通知媒体库刷新（Repo 注入 MediaRefresh.scan；桌面 no-op）。
  Future<void> Function(VFile f)? onRefresh;

  final Directory tempDir;

  Future<void> _tail = Future<void>.value();

  /// 写盘串行互斥：任何一次事务完成（成功或失败）后才开始下一次。
  Future<T> _serialized<T>(Future<T> Function() action) {
    final Future<T> result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  /// 应用字段更新；updates 只含要修改的字段（空串=清除），cover: null=不动/空=删除。
  /// 返回 "" 表示成功，否则为错误信息（原文件保证未被修改）。
  Future<String> apply(VFile f, Map<String, String> updates,
      {Uint8List? cover, bool record = true, String batchId = ''}) {
    return _serialized(() => _apply(f, updates, cover, record, batchId));
  }

  Future<String> _apply(VFile f, Map<String, String> updates, Uint8List? cover,
      bool record, String batchId) async {
    final String ext = TagIO.extOf(f.name);
    if (!TagIO.canWrite(ext)) return '该格式不支持写标签：$ext';
    if (updates.isEmpty && cover == null) return '无变更，跳过写入';

    final Tags before = await _readTags(f, ext);

    File? tmp;
    File? backup;
    try {
      // 1. 副本
      tmp = await _tempFile(ext);
      await store.copyToLocal(f, tmp);

      // 2. 在副本上写
      final Uint8List data = await tmp.readAsBytes();
      final (String err, Uint8List? result) =
          TagIO.writeLocal(data, ext, updates, cover: cover);
      if (err.isNotEmpty) return '标签写入失败（原文件未修改）：$err';
      await tmp.writeAsBytes(result!, flush: true);

      // 3. 副本校验
      final Tags verify = TagIO.readLocal(result, ext);
      for (final MapEntry<String, String> e in updates.entries) {
        if (verify.get(e.key) != e.value.trim()) {
          return '字段校验失败（原文件未修改）：${e.key}';
        }
      }
      if (cover != null) {
        final bool want = cover.isNotEmpty;
        if (TagIO.hasCoverLocal(result, ext) != want) {
          return '封面校验失败（原文件未修改）';
        }
      }

      // 4. 备份当前原文件
      backup = await _tempFile(ext);
      await store.copyToLocal(f, backup);

      // 5. 写回
      await store.writeFromLocal(f, tmp);

      // 6. 回读校验，失败则恢复备份
      f.clearMeta();
      final Tags after = await _readTags(f, ext);
      for (final MapEntry<String, String> e in updates.entries) {
        if (after.get(e.key) != e.value.trim()) {
          await store.writeFromLocal(f, backup);
          f.clearMeta();
          return '回读校验失败，已从备份恢复：${e.key}';
        }
      }

      // 7. journal（只有封面变更时不记：回滚只能回滚字段）
      if (record && updates.isNotEmpty) {
        final JournalEntry entry = JournalEntry()
          ..id = '${DateTime.now().millisecondsSinceEpoch}-${f.name}'
          ..timestamp = journalTimestamp()
          ..uri = f.docId
          ..targetId = f.docId
          ..name = f.name
          ..batchId = batchId;
        for (final String k in Tags.keys) {
          entry.before[k] = before.get(k);
          entry.after[k] = after.get(k);
        }
        entry.status = 'applied';
        await journal.append(entry);
      }

      f.clearMeta();
      await onRefresh?.call(f);
      return '';
    } catch (e) {
      return '写入失败（原文件未修改）：$e';
    } finally {
      if (tmp != null) {
        try {
          await tmp.delete();
        } catch (_) {}
      }
      if (backup != null) {
        try {
          await backup.delete();
        } catch (_) {}
      }
    }
  }

  /// 撤销最近一次标签写入。
  Future<bool> revertLast() async {
    final JournalEntry? entry = await journal.findLastApplied();
    if (entry == null) return false;
    return _revertOne(entry);
  }

  /// 撤销指定批次，返回 {成功, 失败, 总数}。
  Future<List<int>> revertBatch(String batchId) async {
    return journal.revertBatch(batchId, revertOne: _revertOne);
  }

  Future<bool> _revertOne(JournalEntry entry) async {
    final Map<String, String> updates = <String, String>{};
    bool has = false;
    for (final String k in Tags.keys) {
      final String oldV = entry.before[k] ?? '';
      final String newV = entry.after[k] ?? '';
      if (oldV != newV) {
        updates[k] = oldV;
        has = true;
      }
    }
    if (!has) return false;
    final VFile? target = await store.stat(entry.uri);
    if (target == null) return false;
    final String err = await apply(target, updates, record: false);
    return err.isEmpty;
  }

  Future<Tags> _readTags(VFile f, String ext) async {
    final File tmp = await _tempFile(ext);
    try {
      await store.copyToLocal(f, tmp);
      final Uint8List data = await tmp.readAsBytes();
      return TagIO.readLocal(data, ext);
    } finally {
      try {
        await tmp.delete();
      } catch (_) {}
    }
  }

  Future<File> _tempFile(String ext) async {
    return File(
        '${tempDir.path}${Platform.pathSeparator}mo_${DateTime.now().microsecondsSinceEpoch}$ext');
  }
}
