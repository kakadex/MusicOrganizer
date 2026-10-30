/// 同名 `.lrc` 的读写与还原（歌词文件是标签事务的**附属产物**）。
///
/// 为什么要放进事务：音频文件里的内嵌歌词写成功了、同名 `.lrc` 写失败时，
/// 以前的做法是「音频留下新歌词、.lrc 还是旧的」，两处对不上；撤销也只
/// 回退内嵌歌词，`.lrc` 永远停在最后一次写入的状态。这里把 `.lrc` 的
/// 原始字节一起纳入事务快照，写入失败能还原、撤销能同进同退。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../fs/file_store.dart';
import '../fs/raw_write.dart';
import '../fs/temp_name.dart';
import '../model/vfile.dart';

/// 同名 `.lrc` 读写。
abstract final class LrcSidecar {
  /// 事务日志里记 `.lrc` 的键（不在 [Tags.keys] 里，撤销时单独处理）。
  static const String journalKey = '__lrc';

  /// 日志里的编码前缀：`b64:` + base64。空串表示「当时没有这个文件」。
  static const String _prefix = 'b64:';

  /// 与音频同主名的 `.lrc`。
  static String nameFor(VFile audio) => '${audio.stem()}.lrc';

  /// 找到已存在的 `.lrc`（大小写不敏感）；没有返回 null。
  static Future<VFile?> locate(FileStore store, VFile audio) async {
    final String? parentId = audio.parentId;
    if (parentId == null) return null;
    final VFile? dir = await store.stat(parentId);
    if (dir == null) return null;
    final String want = nameFor(audio).toLowerCase();
    for (final VFile c in await store.children(dir)) {
      if (!c.dir && c.name.toLowerCase() == want) return c;
    }
    return null;
  }

  /// 批量找出「有同名 `.lrc`」的音频，返回这些音频的 docId 集合。
  ///
  /// 为什么不做成循环里逐首 [locate]：它每次都要 `stat` 父目录再整份列一遍。
  /// 900 首就是上千次跨进程查询，安卓上会长时间毫无反应（用户实测：单首能删、
  /// 全选 900 首点下去像没点到）。这里按父目录归并，一个目录只列一次。
  ///
  /// 单个目录读不出来（授权抖动 / 目录刚被删）只影响该目录，不中断整批。
  static Future<Set<String>> withSidecar(
      FileStore store, List<VFile> audios) async {
    final Map<String, List<VFile>> byDir = <String, List<VFile>>{};
    for (final VFile a in audios) {
      final String? p = a.parentId;
      if (p == null) continue;
      (byDir[p] ??= <VFile>[]).add(a);
    }
    final Set<String> out = <String>{};
    for (final MapEntry<String, List<VFile>> e in byDir.entries) {
      try {
        final VFile? dir = await store.stat(e.key);
        if (dir == null) continue;
        final Set<String> names = <String>{};
        for (final VFile c in await store.children(dir)) {
          if (!c.dir) names.add(c.name.toLowerCase());
        }
        for (final VFile a in e.value) {
          if (names.contains(nameFor(a).toLowerCase())) out.add(a.docId);
        }
      } catch (_) {
        // 这个目录读不出来：它的音频先按「没有 .lrc」处理，不影响其它目录
      }
    }
    return out;
  }

  /// 读出原始字节；文件不存在返回 null（空文件返回空数组）。
  static Future<Uint8List?> readBytes(FileStore store, VFile audio) async {
    final VFile? f = await locate(store, audio);
    if (f == null) return null;
    final File tmp = _temp();
    try {
      await store.copyToLocal(f, tmp);
      return await tmp.readAsBytes();
    } catch (_) {
      return null;
    } finally {
      _drop(tmp);
    }
  }

  /// 写入歌词文本（UTF-8）。返回空串表示成功，否则是原因。
  static Future<String> writeText(
      FileStore store, VFile audio, String text) async {
    return writeBytes(store, audio, Uint8List.fromList(utf8.encode(text)));
  }

  /// 用给定字节覆盖（不存在就新建）。
  static Future<String> writeBytes(
      FileStore store, VFile audio, Uint8List bytes) async {
    try {
      final String? parentId = audio.parentId;
      if (parentId == null) return '找不到文件所在目录';
      final VFile? dir = await store.stat(parentId);
      if (dir == null) return '找不到文件所在目录';
      final VFile target = await RawWrite.ensureFile(
          store, dir, nameFor(audio), 'text/plain');
      await RawWrite.bytes(store, target, bytes);
      return '';
    } catch (e) {
      return '$e';
    }
  }

  /// 还原到事务前状态：[bytes] 为 null 表示「当时没有这个文件」，需要删掉。
  static Future<String> restore(
      FileStore store, VFile audio, Uint8List? bytes) async {
    if (bytes != null) return writeBytes(store, audio, bytes);
    final VFile? existing = await locate(store, audio);
    if (existing == null) return '';
    try {
      final bool ok = await store.delete(existing);
      return ok ? '' : '撤销时删不掉 ${nameFor(audio)}';
    } catch (e) {
      return '$e';
    }
  }

  /// 日志编码：null → 空串（当时没有文件）。
  static String encode(Uint8List? bytes) =>
      bytes == null ? '' : '$_prefix${base64Encode(bytes)}';

  /// 日志解码：空串 → null（当时没有文件）。
  static Uint8List? decode(String raw) {
    if (raw.isEmpty) return null;
    if (!raw.startsWith(_prefix)) return Uint8List.fromList(utf8.encode(raw));
    try {
      return base64Decode(raw.substring(_prefix.length));
    } catch (_) {
      return null;
    }
  }

  static File _temp() => File('${Directory.systemTemp.path}'
      '${Platform.pathSeparator}${uniqueTempName('mo_lrc_')}');

  static void _drop(File f) {
    try {
      f.deleteSync();
    } catch (_) {}
  }
}
