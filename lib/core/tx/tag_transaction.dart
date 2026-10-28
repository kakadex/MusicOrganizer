/// 标签事务写入（七步事务）。
///
/// 流程（R-04：任何标签写入必须走本类）：
///   before 快照 → 复制到本地缓存副本 → 在副本上写 → 读回校验副本
///   → 备份当前原文件 → 写回 → 回读校验（失败自动恢复备份）
///   → journal 追加 applied 记录。
/// 写盘串行：async 互斥队列保证同一文件 / 批量任务不会并发写。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../fs/file_store.dart';
import '../fs/temp_name.dart';
import '../log/log.dart';
import '../model/journal_entry.dart';
import '../model/tags.dart';
import '../model/vfile.dart';
import '../tag/tag_io.dart';
import 'journal.dart';
import 'lrc_sidecar.dart';

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
  ///
  /// [lrcText] 不为 null 时，同名的 `.lrc` 也纳入本次事务：音频写成功但 `.lrc`
  /// 写失败会把音频回滚并从备份还原 `.lrc`；撤销时两者一起回退。
  Future<String> apply(VFile f, Map<String, String> updates,
      {Uint8List? cover,
      bool record = true,
      String batchId = '',
      String? lrcText}) {
    return _serialized(
        () => _apply(f, updates, cover, record, batchId, lrcText));
  }

  /// 与 `Tags.put` 一致的归一化：去首尾空白，year 只留前 4 位。
  static String _normalize(String key, String raw) {
    String v = raw.trim();
    if (key == 'year' && v.length > 4) v = v.substring(0, 4);
    return v;
  }

  Future<String> _apply(VFile f, Map<String, String> updates, Uint8List? cover,
      bool record, String batchId, String? lrcText) async {
    final String ext = TagIO.extOf(f.name);
    if (!TagIO.canWrite(ext)) return '该格式不支持写标签：$ext';
    if (updates.isEmpty && cover == null) return '无变更，跳过写入';
    // 先把值按 Tags 的规则归一化（year 截 4 位、去首尾空白）。
    // 否则写入成功、回读校验却拿到截断后的值，事务会误判失败并回滚。
    updates = <String, String>{
      for (final MapEntry<String, String> e in updates.entries)
        e.key: _normalize(e.key, e.value),
    };

    final Tags before = await _readTags(f, ext);
    // .lrc 的旧内容要在**动盘之前**读出来：写失败时得靠它还原。
    final Uint8List? lrcBefore =
        lrcText == null ? null : await LrcSidecar.readBytes(store, f);
    final Uint8List? lrcAfter = lrcText == null
        ? null
        : Uint8List.fromList(utf8.encode(lrcText));

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

      // 6.5 同名 .lrc：与音频同一个事务窗口。写失败就把音频也退回去，
      //     否则会留下「内嵌歌词是新的、.lrc 还是旧的」这种半成品。
      if (lrcText != null && lrcAfter != null) {
        final String lrcErr = await LrcSidecar.writeBytes(store, f, lrcAfter);
        if (lrcErr.isNotEmpty) {
          await store.writeFromLocal(f, backup);
          f.clearMeta();
          await LrcSidecar.restore(store, f, lrcBefore);
          return '歌词文件写入失败，已还原原文件：$lrcErr';
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
        // lyrics 刻意不在 Tags.keys 里，但要单独记进日志：
        // 否则写了歌词再撤销，歌词不会被还原（before/after 里没有它）
        for (final String k in <String>[...Tags.keys, Tags.lyrics]) {
          entry.before[k] = before.get(k);
          entry.after[k] = after.get(k);
        }
        if (lrcText != null) {
          // 空串 = 当时没有这个文件；b64: 前缀 = 原始字节，撤销时按字节还原
          entry.before[LrcSidecar.journalKey] = LrcSidecar.encode(lrcBefore);
          entry.after[LrcSidecar.journalKey] = LrcSidecar.encode(lrcAfter);
        }
        entry.status = 'applied';
        final bool logged = await journal.append(entry);
        if (!logged) {
          // 标签已经写入原文件，不能因为日志失败就回滚；但要留下痕迹，
          // 否则用户以为「还能撤销」，实际撤销记录已经丢了。
          Log.warn('撤销日志写入失败：${f.name}（本次写入不可撤销）');
        }
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
    // 必须连同 lyrics 一起比：它不在 Tags.keys 里（怕撑大编辑器和日志），
    // 但写了歌词再撤销如果不回退它，就等于「只撤销了半次改动」。
    for (final String k in <String>[...Tags.keys, Tags.lyrics]) {
      final String oldV = entry.before[k] ?? '';
      final String newV = entry.after[k] ?? '';
      if (oldV != newV) {
        updates[k] = oldV;
        has = true;
      }
    }
    // .lrc 也属于这次写入：只改标签不回退歌词，等于撤销了一半。
    final bool hasLrc = entry.before.containsKey(LrcSidecar.journalKey) ||
        entry.after.containsKey(LrcSidecar.journalKey);
    if (!has && !hasLrc) return false;
    final VFile? target = await store.stat(entry.uri);
    if (target == null) return false;
    String err = '';
    if (has) {
      err = await apply(target, updates, record: false);
      if (err.isNotEmpty) return false;
    }
    if (hasLrc) {
      final Uint8List? old =
          LrcSidecar.decode(entry.before[LrcSidecar.journalKey] ?? '');
      final String lrcErr = await LrcSidecar.restore(store, target, old);
      if (lrcErr.isNotEmpty) return false;
    }
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
    return File('${tempDir.path}${Platform.pathSeparator}'
        '${uniqueTempName('mo_tx_', ext)}');
  }
}
