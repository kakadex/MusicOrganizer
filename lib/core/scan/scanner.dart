/// 目录遍历 + 标签 / 封面读取（可离线单测部分）。
///
/// 要点（改之前先跑 test/core/scan_test.dart）：
/// 1. **同一个 docId 只收一次**：部分 provider 的 SAF 查询会把同一文档返回多次，
///    不去重会让整棵子树走两遍、库页把同一首列两条、曲目数翻倍；
/// 2. **读标签先复制头部**：标签（ID3 / Vorbis Comment）都在文件头，
///    先 512KB，不够扩到 2MB，还不够才整文件复制 —— 绝大多数文件在第一档就够；
/// 3. **写盘后必须 [invalidate]**：VFile 的 size / lastModified 不可变，
///    缓存键不变会一直命中写入前的旧标签。
library;

import 'dart:typed_data';

import '../fs/file_store.dart';
import '../model/cancel_token.dart';
import '../model/progress.dart';
import '../model/tags.dart';
import '../model/vfile.dart';
import '../tag/cover_reader.dart';
import '../tag/tag_io.dart';
import 'scan_stats.dart';

/// 遍历结果。
class WalkResult {
  WalkResult(this.files, this.duplicates);

  /// 收集到的文件（音频 + 歌词）。
  final List<VFile> files;

  /// 被 provider 重复返回而忽略的条目数。
  final int duplicates;
}

/// 标签 + 封面一次读完的结果。
class ScannerHead {
  ScannerHead()
      : tags = Tags(),
        cover = null,
        ok = false;

  Tags tags;

  /// 内嵌封面字节；没有或读不出为 null。
  Uint8List? cover;

  /// 是否真的读到（文件打不开时为 false）。
  bool ok;
}

/// 扫描器（纯 Dart；IO 通过 [FileStore] 抽象）。
abstract final class Scanner {
  /// 先试这么多字节（标签通常都在里面）；不够再扩展。
  static const int headSmall = 512 * 1024;

  /// 常规上限：标签 + 封面一般都落在 2MB 内。
  static const int headBytes = 2 * 1024 * 1024;

  /// 目录深度上限，防御符号链接环之类的异常深树。
  static const int maxDepth = 64;

  /// 缓存键里最多留多少个条目，超了整体清空（避免长期运行无限增长）。
  static const int maxCacheEntries = 2048;

  static final Map<String, Tags> _tagCache = <String, Tags>{};
  static final Map<String, bool> _coverCache = <String, bool>{};
  static final Set<String> _lyricsProbed = <String>{};

  /// 遍历音乐文件（音频 + 歌词）；递归进非隐藏子目录。
  static Future<WalkResult> walkMusic(
    FileStore st,
    VFile root, {
    bool recursive = true,
    CancelToken? cancel,
    Progress? progress,
  }) async {
    final List<VFile> out = <VFile>[];
    final Set<String> visited = <String>{};
    int dup = 0;

    Future<void> collect(VFile dir, int depth) async {
      if (cancel?.isCancelled() ?? false) return;
      for (final VFile c in await st.children(dir)) {
        if (cancel?.isCancelled() ?? false) return;
        if (!visited.add(c.docId)) {
          dup++;
          continue;
        }
        if (c.dir) {
          if (recursive && !c.isHidden() && depth < maxDepth) {
            await collect(c, depth + 1);
          }
        } else if (c.music() && !c.isHidden()) {
          out.add(c);
          if (progress != null && out.length % 200 == 0) {
            progress.onProgress(out.length, 0, c.name);
          }
        }
      }
    }

    await collect(root, 0);
    return WalkResult(out, dup);
  }

  /// 递归列出目录下所有文件（含非音乐文件），用于垃圾清理之类的全量遍历。
  ///
  /// 与 [walkMusic] 不同：这里不排除 `.lrc.bak` / `.tmp` / `Thumbs.db` 之类，
  /// 垃圾清理恰恰要在它们里面找候选；隐藏文件与目录照例跳过。
  static Future<List<VFile>> walkAll(
    FileStore st,
    VFile root, {
    CancelToken? cancel,
    Progress? progress,
  }) async {
    final List<VFile> out = <VFile>[];

    Future<void> walk(VFile dir, int depth) async {
      if ((cancel?.isCancelled() ?? false) || depth > maxDepth) return;
      for (final VFile c in await st.children(dir)) {
        if (cancel?.isCancelled() ?? false) return;
        if (c.dir) {
          if (!c.isHidden()) await walk(c, depth + 1);
        } else if (!c.isHidden()) {
          out.add(c);
          if (progress != null && out.length % 200 == 0) {
            progress.onProgress(out.length, out.length, c.name);
          }
        }
      }
    }

    await walk(root, 0);
    return out;
  }

  /// 扫描并排序（目录内按名，目录间按父 docId），供库列表 / 清理 / 查重使用。
  static Future<WalkResult> scanMusicFiles(
    FileStore st,
    VFile root, {
    bool recursive = true,
    CancelToken? cancel,
    Progress? progress,
  }) async {
    final WalkResult r =
        await walkMusic(st, root, recursive: recursive, cancel: cancel, progress: progress);
    r.files.sort((VFile a, VFile b) {
      final int d = (a.parentId ?? '').compareTo(b.parentId ?? '');
      if (d != 0) return d;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return r;
  }

  /// 统计：音频数 / 歌词数 / 文件总数。
  static ScanStats statsOf(List<VFile> files, {int groups = 0}) {
    final ScanStats s = ScanStats();
    for (final VFile f in files) {
      if (f.dir) continue;
      if (f.audio()) {
        s.audio++;
      } else if (f.lyric()) {
        s.lyrics++;
      }
    }
    s.files = files.where((VFile f) => !f.dir).length;
    s.groups = groups;
    return s;
  }

  /// 一次读取同时得到标签与封面（v0.1.54 的旧经验：列表每首复制两次文件头太慢）。
  static Future<ScannerHead> readHead(FileStore st, VFile f) async {
    final ScannerHead out = ScannerHead();
    try {
      final String ext = TagIO.extOf(f.name);
      Uint8List data = await st.headBytes(f, headSmall);
      if (data.length >= headSmall && !TagIO.tagFitsCopy(data, ext)) {
        data = await st.headBytes(f, headBytes);
        if (data.length >= headBytes && !TagIO.tagFitsCopy(data, ext)) {
          data = await st.headBytes(f, f.size > 0 ? f.size : headBytes);
        }
      }
      out.tags = TagIO.readLocal(data, ext);
      out.cover = CoverReader.read(data, ext);
      out.ok = true;
    } catch (_) {
      // 单首读不出来不影响整批：调用方按「空标签」处理
    }
    return out;
  }

  /// 读标签（带缓存）：命中缓存或库索引缓存就不碰磁盘。
  ///
  /// 歌词字段可能没被读进缓存：缓存里没有歌词时重读一次确认（只重读一次）。
  static Future<Tags> readTags(FileStore st, VFile f) async {
    final String key = _key(f);
    if (f.metaCached()) {
      final String lyric = f.cachedTags!.get(Tags.lyrics);
      if (lyric.trim().isNotEmpty) return f.cachedTags!.copy();
      if (_lyricsProbed.contains(key)) return f.cachedTags!.copy();
    }
    final Tags? cached = _tagCache[key];
    if (cached != null) return cached.copy();

    Tags tags = Tags();
    try {
      final String ext = TagIO.extOf(f.name);
      Uint8List data = await st.headBytes(f, headBytes);
      if (data.length >= headBytes && !TagIO.tagFitsCopy(data, ext)) {
        data = await st.headBytes(f, f.size > 0 ? f.size : headBytes);
      }
      tags = TagIO.readLocal(data, ext);
    } catch (_) {
      tags = Tags();
    }
    _lyricsProbed.add(key);
    if (_tagCache.length > maxCacheEntries) _tagCache.clear();
    _tagCache[key] = tags;
    return tags.copy();
  }

  /// 有没有内嵌封面（只对可写格式判断，其它格式写了也不支持）。
  static Future<bool> hasCover(FileStore st, VFile f) async {
    if (f.dir || !TagIO.canWrite(f.ext())) return false;
    if (f.metaCached()) return f.cachedHasCover;
    final String key = _key(f);
    final bool? cached = _coverCache[key];
    if (cached != null) return cached;
    final bool out = await _readCoverBytes(st, f, true) != null;
    if (_coverCache.length > maxCacheEntries) _coverCache.clear();
    _coverCache[key] = out;
    return out;
  }

  /// 读出内嵌封面的字节；没有则返回 null。
  static Future<Uint8List?> readCover(FileStore st, VFile f) async {
    if (f.dir || !TagIO.canWrite(f.ext())) return null;
    return _readCoverBytes(st, f, false);
  }

  static Future<Uint8List?> _readCoverBytes(FileStore st, VFile f, bool probeOnly) async {
    try {
      final String ext = TagIO.extOf(f.name);
      Uint8List data = await st.headBytes(f, headBytes);
      if (!probeOnly && data.length >= headBytes && !TagIO.tagFitsCopy(data, ext)) {
        data = await st.headBytes(f, f.size > 0 ? f.size : headBytes);
      }
      if (probeOnly) return CoverReader.has(data, ext) ? Uint8List(0) : null;
      return CoverReader.read(data, ext);
    } catch (_) {
      return null;
    }
  }

  /// 丢掉单个文件的缓存（标签写入之后必须调用）。
  static void invalidate(VFile f) {
    f.clearMeta();
    invalidateId(f.docId);
  }

  /// 按 docId 丢掉缓存；传 null 表示全清。
  static void invalidateId(String? docId) {
    if (docId == null) {
      clearCaches();
      return;
    }
    final String prefix = '$docId|';
    _tagCache.removeWhere((String k, Tags _) => k.startsWith(prefix));
    _coverCache.removeWhere((String k, bool _) => k.startsWith(prefix));
    _lyricsProbed.removeWhere((String k) => k.startsWith(prefix));
  }

  /// 全清（换目录 / 重新授权时用）。
  static void clearCaches() {
    _tagCache.clear();
    _coverCache.clear();
    _lyricsProbed.clear();
  }

  static String _key(VFile f) => '${f.docId}|${f.size}|${f.lastModified}';
}
