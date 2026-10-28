/// 标签事务写入（七步事务）。
///
/// 流程（R-04：任何标签写入必须走本类）：
///   before 快照 → 复制到本地缓存副本 → 在副本上写 → 读回校验副本
///   → 备份当前原文件 → 写回 → 回读校验（失败自动恢复备份）
///   → journal 追加 applied 记录。
/// 写盘串行：async 互斥队列保证同一文件 / 批量任务不会并发写。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../fs/file_store.dart';
import '../fs/temp_name.dart';
import '../log/log.dart';
import '../model/journal_entry.dart' show JournalEntry, JournalOp;
import '../model/tags.dart';
import '../model/vfile.dart';
import '../tag/tag_io.dart';
import 'journal.dart';
import 'lrc_sidecar.dart';

/// 批次备份：批内每首歌「写之前那份」的落点。
class _Backup {
  _Backup(this.file, this.backup, this.size, this.lrcBefore, this.lrcTouched,
      this.entryId, this.op);

  final VFile file;
  final File backup;

  /// 这份备份占了多少字节（配额算账用；摘掉时要原数减回去）。
  final int size;

  /// 写之前的同名 `.lrc` 内容（没碰过歌词时为 null）。
  final Uint8List? lrcBefore;
  final bool lrcTouched;

  /// 这次写入对应的 journal 记录 id（回滚后要把它标成已撤销）；
  /// 在事务的第 7 步（追加日志）之后才回填，所以不是 final。
  String entryId;
  final String op;
}

/// 一个进行中的批次。
class _Batch {
  _Batch(this.id, this.maxBytes);

  final String id;
  final int maxBytes;
  final List<_Backup> items = <_Backup>[];
  int bytes = 0;
  bool truncated = false;

  /// 还能不能为 [size] 字节的文件留备份。
  bool canHold(int size) {
    if (bytes + size > maxBytes) {
      truncated = true;
      return false;
    }
    return true;
  }

  /// 摘掉一份备份时把字节数还回去——否则配额会被「已经不存在的备份」占着，
  /// 后面的歌明明还有空间却被告知「到上限」、悄悄不再留备份。
  void release(int size) {
    bytes -= size;
    if (bytes < 0) bytes = 0;
  }

  /// 收尾备份。[deleteAll] 为 true（commit 用）删掉所有备份；
  /// 为 false（rollback 用）只清列表——成功恢复的已在回滚循环里就地删了，
  /// 失败的要**保留**，否则用户没机会重试。
  Future<void> dispose({bool deleteAll = true}) async {
    for (final _Backup b in items) {
      if (!deleteAll) continue;
      try {
        await b.backup.delete();
      } catch (_) {}
    }
    items.clear();
  }
}

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

  /// 当前开启的批次（整批回滚用）；null = 没有批在用。
  _Batch? _batch;

  /// 批备份的**总量**上限（默认 1.5GB）。
  ///
  /// 整批回滚要留着「写之前那份」，等于批内每首歌多占一份磁盘。曲库动辄
  /// 几千首，不设上限会把磁盘吃穿；超了就停止再留备份，并标记这批是
  /// **部分可回滚**（界面要如实说「只能退回前 N 首」，不要假装全能退）。
  static const int defaultBatchBackupBytes = 1536 * 1024 * 1024;

  /// 写盘串行互斥：任何一次事务完成（成功或失败）后才开始下一次。
  Future<T> _serialized<T>(Future<T> Function() action) {
    final Future<T> result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  /// 开启一个批次：批内每首歌的原文件会留一份备份，直到 [commitBatch]
  /// （成功，删备份）或 [rollbackBatch]（失败，整体退回）。
  ///
  /// 单文件事务只保证「这一首要么全改要么不改」；一批 200 首里第 137 首失败时，
  /// 前 136 首已经落盘了 —— 有了批，才能说「这一批要么全成要么全退」。
  /// 返回的 id 要传给批内每次 [apply] 的 `batchId`。
  ///
  /// 备份不额外读盘：单文件事务本来就要先备份原文件做回读校验，这里只是
  /// **用完不删、留到批结束**，所以开批几乎不增加 IO，只占磁盘。
  String beginBatch(String id, {int maxBytes = defaultBatchBackupBytes}) {
    _Batch? old = _batch;
    if (old != null) unawaited(commitBatch(old.id));
    final _Batch b = _Batch(id, maxBytes);
    _batch = b;
    return id;
  }

  /// 批正常结束：丢掉备份。忘了调也没事——下次 [beginBatch] 会替你收尾。
  Future<void> commitBatch(String id) async {
    final _Batch? b = _batch;
    if (b == null || b.id != id) return;
    _batch = null;
    await b.dispose();
  }

  /// 整批退回：把批内**所有**已写入的文件还原成写之前的样子。
  ///
  /// 返回 (恢复成功数, 失败数)。失败一般是文件被外部删了 / 变只读了，
  /// 这种只能如实报出来：整批回滚的承诺「全退」在磁盘层面已经尽力，
  /// 剩下的是环境原因，界面要把数字显示给用户看。
  Future<(int, int)> rollbackBatch(String id) async {
    final _Batch? b = _batch;
    if (b == null || b.id != id) return (0, 0);
    _batch = null;
    int ok = 0;
    int failed = 0;
    // 逆序：后写的先退回去，中途被打断也最多是「后面没退、前面已退」
    for (int i = b.items.length - 1; i >= 0; i--) {
      final _Backup item = b.items[i];
      try {
        await store.writeFromLocal(item.file, item.backup);
        item.file.clearMeta();
        if (item.lrcTouched) {
          final String lrcErr =
              await LrcSidecar.restore(store, item.file, item.lrcBefore);
          if (lrcErr.isNotEmpty) {
            // 音频退回去了、.lrc 没退回去：这一首只能算失败，备份留着重试
            Log.warn('整批回滚：.lrc 还原失败（${item.file.name}）：$lrcErr');
            failed++;
            continue;
          }
        }
        await onRefresh?.call(item.file);
        // 撤销日志里也要留痕：否则这条 applied 记录还挂着「可撤销」，
        // 用户在历史里再点一次会退到一个不存在的状态
        if (item.entryId.isNotEmpty) {
          await journal.append(JournalEntry()
            ..id = '${DateTime.now().millisecondsSinceEpoch}-rollback-$i'
            ..timestamp = journalTimestamp()
            ..uri = item.file.docId
            ..name = item.file.name
            ..batchId = id
            ..status = 'reverted'
            ..op = item.op
            ..targetId = item.entryId);
        }
        ok++;
        // 这一首已经还原成功，备份用完了，就地删掉
        try {
          await item.backup.delete();
        } catch (_) {}
      } catch (_) {
        failed++;
        // 还原失败：备份**保留**，下次还能重试（不能像成功的那样删）
      }
    }
    await b.dispose(deleteAll: false);
    return (ok, failed);
  }

  /// 这批是不是「部分可回滚」（备份总量到上限后停了）。
  bool batchTruncated(String id) => _batch?.id == id && _batch!.truncated;

  /// 应用字段更新；updates 只含要修改的字段（空串=清除），cover: null=不动/空=删除。
  /// 返回 "" 表示成功，否则为错误信息（原文件保证未被修改）。
  ///
  /// [lrcText] 不为 null 时，同名的 `.lrc` 也纳入本次事务：音频写成功但 `.lrc`
  /// 写失败会把音频回滚并从备份还原 `.lrc`；撤销时两者一起回退。
  /// [removeLrc] 为 true 时，删除同名的 `.lrc`（同样纳入本事务与撤销）。
  Future<String> apply(VFile f, Map<String, String> updates,
      {Uint8List? cover,
      bool record = true,
      String batchId = '',
      String? lrcText,
      bool removeLrc = false,
      String op = JournalOp.tags}) {
    return _serialized(() =>
        _apply(f, updates, cover, record, batchId, lrcText, removeLrc, op));
  }

  /// 与 `Tags.put` 一致的归一化：去首尾空白，year 只留前 4 位。
  static String _normalize(String key, String raw) {
    String v = raw.trim();
    if (key == 'year' && v.length > 4) v = v.substring(0, 4);
    return v;
  }

  Future<String> _apply(VFile f, Map<String, String> updates, Uint8List? cover,
      bool record, String batchId, String? lrcText, bool removeLrc,
      String op) async {
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
    final bool touchLrc = lrcText != null || removeLrc;
    final Uint8List? lrcBefore =
        !touchLrc ? null : await LrcSidecar.readBytes(store, f);
    final Uint8List? lrcAfter = removeLrc
        ? null
        : (lrcText == null ? null : Uint8List.fromList(utf8.encode(lrcText)));

    File? tmp;
    File? backup;
    _Backup? batchItem; // 非空 = 备份要留到批结束（整批回滚用），不能随手删
    String entryId = '';
    // 原文件有没有「已经开始被写」：真正写原文件那一步之前置上。
    // 只有它没置上，才允许对外说「原文件未修改」；置上了，异常时就必须
    // 先拿备份还原，再把「已用备份恢复」如实报出去。
    bool wroteOriginal = false;
    // 还原也失败时（比如盘真的满了）置上：备份不能删，留着现场。
    bool keepBackup = false;
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
      // 批开着且还放得下：这份备份留到批结束（成功 commit 时删、失败 rollback 时
      // 写回去）。不额外读盘——单文件事务本来就要这份备份做回读校验。
      final _Batch? b = _batch;
      if (b != null && b.id == batchId) {
        final int size = await backup.length();
        if (b.canHold(size)) {
          batchItem = _Backup(f, backup, size, lrcBefore, touchLrc, '', op);
          b.items.add(batchItem);
          b.bytes += size;
        }
      }

      // 5. 写回
      //    从这一刻起原文件「已经开始被写」：writeFromLocal 可能写一半就抛
      //    （硬盘满 / U 盘拔了 / 文件被占），所以标记要放在调用**之前**置上，
      //    不能等它成功返回才置——那样写一半抛异常时又会谎报「没动过」。
      wroteOriginal = true;
      await store.writeFromLocal(f, tmp);

      // 6. 回读校验，失败则恢复备份
      f.clearMeta();
      final Tags after = await _readTags(f, ext);
      for (final MapEntry<String, String> e in updates.entries) {
        if (after.get(e.key) != e.value.trim()) {
          await store.writeFromLocal(f, backup);
          f.clearMeta();
          // 已经就地还原了，这项不该再算进「批里已写入的」
          _voidBatchBackup(batchItem);
          batchItem = null;
          return '回读校验失败，已从备份恢复：${e.key}';
        }
      }

      // 6.5 同名 .lrc：与音频同一个事务窗口。写失败就把音频也退回去，
      //     否则会留下「内嵌歌词是新的、.lrc 还是旧的」这种半成品。
      //     restore(bytes!=null)=写入，restore(null)=删除（同进同退）。
      if (touchLrc) {
        final String lrcErr = await LrcSidecar.restore(store, f, lrcAfter);
        if (lrcErr.isNotEmpty) {
          // 音频退回写之前的字节
          await store.writeFromLocal(f, backup);
          f.clearMeta();
          // .lrc 也要退回；这一步失败时不能再说「已还原」，备份得留着
          final String backErr = await LrcSidecar.restore(store, f, lrcBefore);
          if (backErr.isNotEmpty) {
            keepBackup = true;
            _voidBatchBackup(batchItem);
            batchItem = null;
            Log.warn('写歌词失败且还原 .lrc 也失败：${f.name}，'
                '写入：$lrcErr；还原：$backErr');
            return '歌词文件处理失败，还原 .lrc 也失败（备份已保留）：'
                '$lrcErr / $backErr';
          }
          _voidBatchBackup(batchItem);
          batchItem = null;
          return '歌词文件处理失败，已还原原文件：$lrcErr';
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
          ..batchId = batchId
          ..op = op;
        // lyrics 刻意不在 Tags.keys 里，但要单独记进日志：
        // 否则写了歌词再撤销，歌词不会被还原（before/after 里没有它）
        for (final String k in <String>[...Tags.keys, Tags.lyrics]) {
          entry.before[k] = before.get(k);
          entry.after[k] = after.get(k);
        }
        if (touchLrc) {
          // 空串 = 当时没有这个文件；b64: 前缀 = 原始字节，撤销时按字节还原
          entry.before[LrcSidecar.journalKey] = LrcSidecar.encode(lrcBefore);
          entry.after[LrcSidecar.journalKey] = LrcSidecar.encode(lrcAfter);
        }
        entry.status = 'applied';
        entryId = entry.id; // 记下来：整批回滚后要把这条标成「已撤销」
        final bool logged = await journal.append(entry);
        if (!logged) {
          // 标签已经写入原文件，不能因为日志失败就回滚；但要留下痕迹，
          // 否则用户以为「还能撤销」，实际撤销记录已经丢了。
          Log.warn('撤销日志写入失败：${f.name}（本次写入不可撤销）');
        }
      }

      f.clearMeta();
      await onRefresh?.call(f);
      batchItem?.entryId = entryId;
      return '';
    } catch (e) {
      // 原文件可能已经被写坏：先拿备份还原，别谎报「没动过」。
      bool restoreFailed = false;
      if (wroteOriginal && backup != null) {
        try {
          await store.writeFromLocal(f, backup);
          f.clearMeta();
        } catch (_) {
          // 还原也失败（比如盘真的满了）：备份不能删，留现场给用户自己救。
          restoreFailed = true;
          keepBackup = true;
        }
      }
      // 异常路径下这份备份不再参与整批回滚（要么已还原、要么保留作现场），
      // 别把它留在批里当「可回滚」的证据；字节数同步还回去。
      if (batchItem != null) {
        _voidBatchBackup(batchItem);
        batchItem = null;
      }
      // 没动过原文件才是真的「未修改」；动过但还原失败，必须如实说可能坏了，
      // 并把备份的真实路径给出来，否则用户以为没事、文件其实已经废了。
      if (!wroteOriginal) return '写入失败（原文件未修改）：$e';
      if (restoreFailed) {
        final String where = backup?.path ?? '（备份路径不可用）';
        Log.warn('写入失败且还原也失败：${f.name}，原文件可能已损坏，备份：$where');
        return '写入失败，原文件可能已损坏，备份在 $where，'
            '请联系开发者或手动替换：$e';
      }
      return '写入失败，已用备份恢复：$e';
    } finally {
      if (tmp != null) {
        try {
          await tmp.delete();
        } catch (_) {}
      }
      // 备份只有在「确实没动过原文件」或「已经从备份恢复成功」之后才能删；
      // 恢复失败（keepBackup）或还在批里（batchItem）都留着。
      if (backup != null && batchItem == null && !keepBackup) {
        try {
          await backup.delete();
        } catch (_) {}
      }
    }
  }

  /// 把一项备份从批里摘掉（这一首没真正写成，不该被整批回滚碰）。
  ///
  /// 摘掉时**必须把字节数还回去**：配额算的是「当前还留着的备份总量」，
  /// 不是「曾经留过多少」。
  void _voidBatchBackup(_Backup? item) {
    if (item == null) return;
    final _Batch? b = _batch;
    if (b == null) return;
    b.items.remove(item);
    b.release(item.size);
  }

  /// 当前批已占用的备份字节数（测试与诊断用）。
  int batchBytes(String id) => _batch?.id == id ? _batch!.bytes : 0;

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
