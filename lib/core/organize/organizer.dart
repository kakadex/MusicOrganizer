/// 自动整理：目录规划 + 执行。
///
/// 三条不可违反的约束（改代码前先读一遍）：
/// 1. **只在授权根目录内动**：[MovePlan.targetPath] 永远是相对根目录的路径，
///    执行时逐段从根往下创建，不解析绝对路径，也不跨出根目录；
/// 2. **绝不覆盖已存在文件**：目标目录里已有同名文件就跳过并记账，不改名、
///    不生成「(1)」副本，用户自己决定怎么处理；
/// 3. **必须先出计划让用户确认**：[plan] 只算不动盘，[execute] 只执行已确认的计划。
library;

import '../fs/file_store.dart';
import '../match/artist_rules.dart';
import '../match/name_parser.dart';
import '../match/text_util.dart';
import '../model/cancel_token.dart';
import '../model/vfile.dart';

/// 一次移动的计划条目。
class MovePlan {
  MovePlan({required this.file, required this.rootDocId, required this.fromDir,
      required this.targetPath, required this.reason, this.conflict = false});

  final VFile file;
  /// 授权根目录 docId：所有目标目录都从它往下逐段创建。
  final String rootDocId;
  /// 源父目录 docId（空串表示根目录）。
  final String fromDir;
  /// 目标目录（相对根目录，`/` 分隔；空串表示根目录本身）。
  final String targetPath;
  /// 目标目录的由来，界面直接显示。
  final String reason;
  /// 批内已有同名文件要落到同一个目标目录 —— 冲突，默认不执行。
  final bool conflict;

  /// 目标文件名（整理不改名，沿用原名）。
  String get targetName => file.name;

  @override
  String toString() =>
      '${file.name} → ${targetPath.isEmpty ? '（根目录）' : targetPath}';
}

/// 一次整理的结果汇总。
class OrganizeResult {
  /// 计划总数。
  int total = 0;
  /// 成功移动。
  int ok = 0;
  /// 跳过（已在该目录 / 冲突 / 取消）。
  int skipped = 0;
  /// 失败（带原因）。
  int failed = 0;
  /// 执行中途被取消。
  bool cancelled = false;
  /// 失败原因（每个失败一条）。
  final List<String> errors = <String>[];
  /// 跳过原因（冲突等，属于提示而非错误）。
  final List<String> notes = <String>[];

  String summary() {
    final String tail = cancelled ? '（已中断）' : '';
    return '成功 $ok 个 · 跳过 $skipped 个 · 失败 $failed 个$tail';
  }

  @override
  String toString() => summary();
}

abstract final class Organizer {
  /// 单段目录名长度上限（太长的专辑名在文件管理器里看不到结尾）。
  static const int maxSegment = 60;

  /// 生成移动计划（纯计算，不碰文件系统）。
  ///
  /// 目标目录：`歌手` 或 `歌手/专辑`（[byAlbum] 且有专辑标签时）。认不出歌手的
  /// 文件保持原位、不出计划 —— 「识别不准就别搬」，把几百首倒进
  /// 一个目录，用户只能手工找回。
  ///
  /// [onlyUnorganized] 为 true 时跳过「已经在目标目录里」的文件，重复预览不产噪音。
  ///
  /// 冲突只在批内判断（同目标目录 + 同名）；目标目录里是否已有同名文件，由
  /// [execute] 按目录实况再判一次，两处都不覆盖。
  static List<MovePlan> plan(List<VFile> files, {required String rootDocId,
      bool byAlbum = true, bool onlyUnorganized = true}) {
    final List<MovePlan> out = <MovePlan>[];
    final Set<String> taken = <String>{};
    // 曲库里已有的一级目录 = 已经确认过的歌手目录。用来纠正「歌名-歌手」这种
    // 把歌手写在后面的命名：两侧候选里命中已有目录的那个才是歌手。
    final Set<String> knownDirs = _knownArtistDirs(files, rootDocId);
    for (final VFile f in files) {
      if (f.dir || !f.music()) continue;
      final String artistSeg = _segment(_artistOf(f, knownDirs));
      if (artistSeg.isEmpty) continue;
      String path = artistSeg;
      String reason = '按歌手归位';
      if (byAlbum) {
        final String albumSeg = _segment(_albumOf(f));
        if (albumSeg.isNotEmpty) {
          path = '$artistSeg/$albumSeg';
          reason = '按歌手 / 专辑归位';
        }
      }
      if (onlyUnorganized && _samePath(_dirOf(f, rootDocId), path)) continue;
      final String slot = '${path.toLowerCase()}/${f.name.toLowerCase()}';
      out.add(MovePlan(
        file: f,
        rootDocId: rootDocId,
        fromDir: f.parentId ?? '',
        targetPath: path,
        reason: reason,
        conflict: !taken.add(slot),
      ));
    }
    return out;
  }

  /// 串行执行计划：建目录（已存在则复用）→ 移动 → 记账。
  ///
  /// [FileStore.move] 内部已处理「优先 moveDocument，失败回退复制 + 校验 + 删除」，
  /// 这里只按返回值记账，不重复实现搬迁逻辑。
  static Future<OrganizeResult> execute(FileStore store, List<MovePlan> plans,
      {void Function(int done, int total)? onProgress,
      CancelToken? cancel}) async {
    final OrganizeResult result = OrganizeResult()..total = plans.length;
    // 目录 docId → (子目录名 → VFile)：整轮共用，避免每组都列一遍上层目录
    final Map<String, Map<String, VFile>> index = <String, Map<String, VFile>>{};
    // 目录 docId → 已有子项名：判重名与冲突
    final Map<String, Set<String>> names = <String, Set<String>>{};
    int done = 0;
    for (final MovePlan p in plans) {
      if (cancel?.isCancelled() ?? false) {
        result.cancelled = true;
        break;
      }
      done++;
      onProgress?.call(done, plans.length);
      if (p.conflict) {
        result.skipped++;
        result.notes.add('${p.file.name}：批内重名，已跳过（不覆盖）');
        continue;
      }
      try {
        final VFile dir = await _ensureDir(store, p, index, names);
        if ((p.file.parentId ?? '') == dir.docId) {
          result.skipped++;
          continue;
        }
        final Set<String> existing = names[dir.docId] ?? <String>{};
        names[dir.docId] = existing;
        if (existing.contains(p.file.name)) {
          result.skipped++;
          result.notes.add('${p.file.name}：目标已有同名文件，已跳过（不覆盖）');
          continue;
        }
        final String? why = await store.move(p.file, dir);
        if (why == null) {
          result.ok++;
          existing.add(p.file.name);
        } else {
          result.failed++;
          result.errors.add('${p.file.name}：$why');
        }
      } catch (e) {
        result.failed++;
        result.errors.add('${p.file.name}：${TextUtil.shortError(e)}');
      }
    }
    return result;
  }

  /// 逐段创建（或复用）目标目录；每层都走缓存，整轮只列一次上层目录。
  static Future<VFile> _ensureDir(FileStore store, MovePlan p,
      Map<String, Map<String, VFile>> index, Map<String, Set<String>> names) async {
    VFile cur = VFile(docId: p.rootDocId, name: '', dir: true);
    for (final String seg in _segments(p.targetPath)) {
      Map<String, VFile>? dirs = index[cur.docId];
      if (dirs == null) {
        dirs = <String, VFile>{};
        final Set<String> all = <String>{};
        for (final VFile k in await store.children(cur)) {
          all.add(k.name);
          if (k.dir) dirs[k.name] = k;
        }
        index[cur.docId] = dirs;
        names[cur.docId] = all;
      }
      VFile? next = dirs[seg];
      if (next == null) {
        next = await store.createDir(cur, seg);
        dirs[seg] = next;
        names[next.docId] = <String>{};
      }
      cur = next;
    }
    // 目标目录已存在时它的子项还没列过：补列一次，否则同名文件会被当成可搬。
    if (!names.containsKey(cur.docId)) {
      names[cur.docId] = <String>{
        for (final VFile k in await store.children(cur)) k.name,
      };
    }
    return cur;
  }

  /// 歌手：标签优先 → 文件名（命中已有歌手目录的优先）→ 认不出就留原位。
  ///
  /// 刻意**不**拿所在目录名当歌手：「收藏」「新歌」这类目录会变成歌手目录，
  /// 把曲库结构搞乱。认不出歌手的文件留在原位（与 0.1.100 默认一致）。
  static String _artistOf(VFile f, Set<String> knownDirs) {
    final String byTag =
        ArtistRules.normalizeCandidate(f.cachedTags?.get('artist') ?? '');
    if (byTag.isNotEmpty && !ArtistRules.isGenericArtist(byTag)) return byTag;
    final NameSplit? split = NameParser.splitArtistTitle(f.stem());
    if (split != null) {
      String fallback = '';
      for (final List<String> side in <List<String>>[
        <String>[split.left, split.right],
        <String>[split.right, split.left],
      ]) {
        final String artist = ArtistRules.normalizeCandidate(side[0]);
        if (ArtistRules.isGenericArtist(artist)) continue;
        if (!ArtistRules.isReasonableArtistReturn(artist, side[1], f.stem(), null)) {
          continue;
        }
        // 与曲库里已有的歌手目录对得上 → 更可信（「歌名-歌手」就靠这一步纠正方向）
        if (knownDirs.contains(ArtistRules.folderKey(artist))) return artist;
        if (fallback.isEmpty) fallback = artist;
      }
      if (fallback.isNotEmpty) return fallback;
    }
    return '';
  }

  /// 曲库里已有的一级目录名（归一后的键），排除占位目录。
  static Set<String> _knownArtistDirs(List<VFile> files, String rootDocId) {
    final Set<String> out = <String>{};
    for (final VFile f in files) {
      if (f.dir) continue;
      final String name = _topDirName(f, rootDocId);
      if (name.isEmpty) continue;
      if (ArtistRules.isGenericArtist(name)) continue;
      // Music / 下载 / 歌曲 这类容器目录不是歌手，混进来会污染「谁是歌手」的判断
      if (ArtistRules.isGenericFolder(name)) continue;
      out.add(ArtistRules.folderKey(name));
    }
    return out;
  }

  /// 文件所在的一级目录名（相对根目录的第一段）；不在一级目录里返回空串。
  static String _topDirName(VFile f, String rootDocId) {
    final String rel = f.relativePath(rootDocId);
    final int slash = rel.indexOf('/');
    if (slash <= 0) return '';
    return rel.substring(0, slash);
  }

  /// 专辑：只读缓存标签（本模块不碰 IO）；占位专辑（未知专辑 / 群星合辑）当没有。
  static String _albumOf(VFile f) {
    final String album =
        ArtistRules.normalizeCandidate(f.cachedTags?.get('album') ?? '');
    return album.isEmpty || ArtistRules.isGenericArtist(album) ? '' : album;
  }

  /// 目录名清洗：非法字符（[TextUtil.illegalFilenameChars]）与控制字符换空格，
  /// 折叠连续空格，去首尾点与空格，超长截断；`.` / `..` 直接丢弃。
  static String _segment(String raw) {
    final StringBuffer sb = StringBuffer();
    for (final int c in raw.trim().codeUnits) {
      final bool bad =
          c < 0x20 || TextUtil.illegalFilenameChars.codeUnits.contains(c);
      sb.writeCharCode(bad ? 0x20 : c);
    }
    String s = sb.toString().replaceAll(RegExp(r'\s{2,}'), ' ').trim();
    s = s.replaceAll(RegExp(r'^[. ]+'), '').replaceAll(RegExp(r'[. ]+$'), '');
    if (s == '.' || s == '..') return '';
    if (s.length > maxSegment) s = s.substring(0, maxSegment).trim();
    return s;
  }

  static List<String> _segments(String path) => path
      .split('/')
      .map((String s) => s.trim())
      .where((String s) => s.isNotEmpty)
      .toList();

  /// 文件当前所在目录（相对根目录）；不在根目录之下时返回空串。
  static String _dirOf(VFile f, String rootDocId) {
    final String rel = f.relativePath(rootDocId);
    final int idx = rel.lastIndexOf('/');
    return idx <= 0 ? '' : rel.substring(0, idx);
  }

  static bool _samePath(String a, String b) => a.toLowerCase() == b.toLowerCase();
}
