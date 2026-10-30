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

import '../concurrency.dart';
import '../fs/file_store.dart';
import '../model/cancel_token.dart';
import '../model/progress.dart';
import '../model/tags.dart';
import '../model/vfile.dart';
import '../tag/cover_art.dart';
import '../tag/cover_reader.dart';
import '../tag/tag_io.dart';
import 'scan_filter.dart';
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

  /// 缓存键里最多留多少个条目（与字节上限共同生效，取先到者）。
  static const int maxCacheEntries = 2048;

  /// 标签缓存的内存天花板：歌词 / 注释这类长文本很容易把缓存撑到几十 MB。
  static const int maxCacheBytes = 8 * 1024 * 1024;

  /// 同一时刻最多几个文件在读标签。
  ///
  /// 批量任务、封面预览、编辑器可能同时在读，各入口各按自己的并发跑，叠加
  /// 起来就是几十个文件一起读 —— 闸门放在这里，任何调用方都压不到内存。
  static const int maxConcurrentReads = 4;

  static final ConcurrencyGate _readGate = ConcurrencyGate(maxConcurrentReads);

  static final BoundedMap<String, Tags> _tagCache = BoundedMap<String, Tags>(
    maxEntries: maxCacheEntries,
    maxBytes: maxCacheBytes,
    sizeOf: (Tags t) => estimateTagsBytes(t.values),
  );
  static final Map<String, bool> _coverCache = <String, bool>{};
  static final Set<String> _lyricsProbed = <String>{};

  /// 探针集合也有天花板：长期运行不能无限增长。
  static const int maxLyricsProbed = 4096;

  /// 遍历音乐文件（音频 + 歌词）；递归进非隐藏子目录。
  static Future<WalkResult> walkMusic(
    FileStore st,
    VFile root, {
    bool recursive = true,
    CancelToken? cancel,
    Progress? progress,
    ScanFilter? filter,
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
          final bool skip = filter?.skipDir(c) ?? false;
          if (recursive && !c.isHidden() && !skip && depth < maxDepth) {
            await collect(c, depth + 1);
          }
        } else if (c.music() && !c.isHidden() && !(filter?.skip(c) ?? false)) {
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
  /// [progressEvery] 每收多少个文件报一次进度：默认 200（曲库扫描够用），
  /// 垃圾清理这类要显示「已扫过多少个」的入口传小一点（如 20），界面才动得起来。
  static Future<List<VFile>> walkAll(
    FileStore st,
    VFile root, {
    CancelToken? cancel,
    Progress? progress,
    ScanFilter? filter,
    int progressEvery = 200,
  }) async {
    final int every = progressEvery <= 0 ? 1 : progressEvery;
    final List<VFile> out = <VFile>[];

    Future<void> walk(VFile dir, int depth) async {
      if ((cancel?.isCancelled() ?? false) || depth > maxDepth) return;
      for (final VFile c in await st.children(dir)) {
        if (cancel?.isCancelled() ?? false) return;
        if (c.dir) {
          if (!c.isHidden() && !(filter?.skipDir(c) ?? false)) {
            await walk(c, depth + 1);
          }
        } else if (!c.isHidden() && !(filter?.skip(c) ?? false)) {
          out.add(c);
          if (progress != null && out.length % every == 0) {
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
    ScanFilter? filter,
  }) async {
    final WalkResult r = await walkMusic(st, root,
        recursive: recursive, cancel: cancel, progress: progress, filter: filter);
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

  /// 整文件读取的上限：超过它宁可不读标签，也不把一个几百 MB 的文件吞进内存。
  static const int _maxWholeRead = 48 * 1024 * 1024;

  /// 按格式取「够用」的字节。
  ///
  /// MP3/FLAC 靠标签头长度判断；MP4 家族特殊——moov 可能在**文件尾部**，
  /// 所以先看头，找不到再读尾部 2MB 把 moov 切出来，**绝不整文件读**。
  static Future<Uint8List> loadForTags(FileStore st, VFile f, String ext) async {
    Uint8List data = await st.headBytes(f, headSmall);
    if (data.length < headSmall) return data; // 文件本身就这么大，已读完
    if (!TagIO.needsMore(data, ext)) return data;

    data = await st.headBytes(f, headBytes);
    if (data.length < headBytes) return data;
    if (!TagIO.needsMore(data, ext)) return data;

    if (TagIO.isMp4(ext)) {
      final Uint8List tail = await st.tailBytes(f, headBytes);
      final Uint8List? moov = TagIO.mp4MoovFromTail(tail);
      if (moov != null) return moov;
    }
    // 兜底：小文件才允许整读；大文件宁可返回已读到的头，也不 OOM
    if (f.size > _maxWholeRead) return data;
    return st.headBytes(f, f.size > 0 ? f.size : headBytes);
  }

  /// 一次读取同时得到标签与封面（v0.1.54 的旧经验：列表每首复制两次文件头太慢）。
  static Future<ScannerHead> readHead(FileStore st, VFile f) async {
    final ScannerHead out = ScannerHead();
    try {
      final String ext = TagIO.extOf(f.name);
      final Uint8List data = await loadForTags(st, f, ext);
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
      // 闸门只包真正的读盘：命中缓存 / 索引缓存时不占名额，不会拖慢列表。
      final Uint8List data =
          await _readGate.run(() => loadForTags(st, f, ext));
      tags = TagIO.readLocal(data, ext);
    } catch (_) {
      tags = Tags();
    }
    if (_lyricsProbed.length >= maxLyricsProbed) _lyricsProbed.clear();
    _lyricsProbed.add(key);
    _tagCache.put(key, tags);
    return tags.copy();
  }

  /// 有没有内嵌封面（只对可写格式判断，其它格式写了也不支持）。
  static Future<bool> hasCover(FileStore st, VFile f) async {
    // WMA 只读但能读封面：这里按「可读」判断，不是「可写」
    if (f.dir || !TagIO.canRead(f.ext())) return false;
    if (f.metaCached()) return f.cachedHasCover;
    final String key = _key(f);
    final bool? cached = _coverCache[key];
    if (cached != null) return cached;
    final bool out = await _readCoverBytes(st, f, true) != null;
    if (_coverCache.length > maxCacheEntries) _coverCache.clear();
    _coverCache[key] = out;
    return out;
  }

  /// 封面探测的第一档读多少字节（0.2.59）。
  ///
  /// 绝大多数封面就在文件头这一小段：读 256KB 能解出**完整**图片就直接用，
  /// 省掉后面 2MB 的读盘；解不全（图被截断）再走 [loadForTags] 的老路。
  static const int coverProbeBytes = 256 * 1024;

  /// 读出内嵌封面的字节；没有则返回 null。
  static Future<Uint8List?> readCover(FileStore st, VFile f) async {
    if (f.dir || !TagIO.canRead(f.ext())) return null;
    return _readCoverBytes(st, f, false);
  }

  static Future<Uint8List?> _readCoverBytes(FileStore st, VFile f, bool probeOnly) async {
    try {
      final String ext = TagIO.extOf(f.name);
      if (probeOnly) {
        final Uint8List data = await st.headBytes(f, headBytes);
        return CoverReader.has(data, ext) ? Uint8List(0) : null;
      }
      // 第一档：只读 256KB。
      // 注意单独包一层 try：标签被 256KB 截断时解析会越界，这属于「读少了」，
      // 不是「没有封面」，要落到第二档去补读，不能直接当没有。
      final Uint8List small = await st.headBytes(f, coverProbeBytes);
      Uint8List? quick;
      try {
        quick = CoverReader.read(small, ext);
      } catch (_) {
        quick = null;
      }
      if (quick != null && CoverArt.isComplete(quick)) return quick;
      // 整份文件就这么大，读完了都没有完整封面：不必再读第二遍
      if (small.length < coverProbeBytes) return null;
      // 第二档：按标签格式判断要不要扩到 2MB（MP4 的 moov 可能在文件尾）
      final Uint8List data = await loadForTags(st, f, ext);
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
