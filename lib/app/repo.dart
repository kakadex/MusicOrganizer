import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/fs/desktop_file_store.dart';
import '../core/fs/file_store.dart';
import '../core/fs/saf_file_store.dart';
import '../core/fs/tree_ref.dart';
import '../core/match/batch_memory.dart';
import '../core/match/match_queue.dart';
import '../core/model/cancel_token.dart';
import '../core/model/tags.dart';
import '../core/model/vfile.dart';
import '../core/net/net.dart';
import '../core/scan/scan_merge.dart';
import '../core/scan/scan_stats.dart';
import '../core/scan/scanner.dart';
import '../core/scan/search_index.dart';
import '../core/settings/settings.dart';
import '../core/task/match_runner.dart';
import '../core/tx/journal.dart';
import '../core/tx/tag_transaction.dart';
import '../platform/media_refresh.dart';

/// 一次扫描的结果。
class ScanOutcome {
  ScanOutcome(this.files, this.stats, this.merge, this.duplicates, this.error);

  final List<VFile> files;
  final ScanStats stats;
  final ScanMergeResult merge;

  /// provider 重复返回而忽略的条目数。
  final int duplicates;

  /// 出错信息（空串 = 成功）。
  final String error;

  bool get ok => error.isEmpty;

  String summary() {
    if (!ok) return error;
    return '${stats.summary()}（${merge.summary()}）';
  }
}

/// 全局仓库：文件系统 / 库索引 / 事务 / 任务编排的唯一持有者。
///
/// 页面只跟它打交道：取 [store] 读写、取 [files] 展示、取 [runner] 跑批量。
/// 单例，进程内共享（Dart 单线程，不需要额外加锁）。
class Repo {
  Repo._();

  /// 进程内全局单例。
  static final Repo instance = Repo._();

  /// 文件系统抽象（安卓 SAF / 桌面 dart:io）。
  FileStore? store;

  /// 当前曲库目录（可空 = 还没授权）。
  TreeRef? root;

  /// 扫描结果（音频 + 歌词，按目录名排序）。
  List<VFile> files = <VFile>[];

  /// 内存搜索索引。
  final SearchIndex index = SearchIndex();

  /// 撤销日志与事务。
  Journal? journal;
  TagTransaction? tx;
  MatchRunner? runner;

  /// 设置。
  final SettingsStore settings = SettingsStore();

  bool _initialized = false;
  bool _scanning = false;
  bool _metaLoading = false;

  bool get isInitialized => _initialized;
  bool get scanning => _scanning;
  bool get metaLoading => _metaLoading;
  bool get hasRoot => root != null;

  /// 当前平台是桌面（dart:io 直读写）。
  static bool get isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  /// 初始化（幂等）。桌面直接用 dart:io，安卓走 SAF 通道。
  Future<void> init({FileStore? storeOverride}) async {
    if (_initialized) return;
    store = storeOverride ?? (isDesktop ? DesktopFileStore() : SafFileStore());
    final Directory dir = await _dataDir();
    journal = Journal(File('${dir.path}/tag_journal.jsonl'));
    tx = TagTransaction(
      store: store!,
      journal: journal!,
      onRefresh:
          isDesktop ? null : (VFile f) async => AndroidMediaRefresh().scan(f),
    );
    runner = MatchRunner(
      store: store!,
      tx: tx!,
      queue: MatchQueue.open(dir, 'tags'),
      memory: BatchMemory.open(dir, 'tags'),
    );
    await _loadSettings();
    _initialized = true;
  }

  Future<Directory> _dataDir() async {
    final Directory base = await getApplicationSupportDirectory();
    if (!base.existsSync()) base.createSync(recursive: true);
    return base;
  }

  Future<void> _loadSettings() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    for (final String key in <String>[
      'filename_weight',
      'fill_overwrite',
      'net_files',
      'net_timeout',
      'theme_id',
      'theme_dark',
      'sort_key',
      'sort_desc',
      'filter',
    ]) {
      final Object? v = prefs.get(key);
      if (v != null) settings.set(key, v);
    }
  }

  /// 把设置写回持久化（界面改了之后调用）。
  Future<void> setSetting(String key, Object? value) async {
    settings.set(key, value);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    if (value == null) {
      await prefs.remove(key);
    } else if (value is int) {
      await prefs.setInt(key, value);
    } else if (value is bool) {
      await prefs.setBool(key, value);
    } else if (value is double) {
      await prefs.setDouble(key, value);
    } else {
      await prefs.setString(key, '$value');
    }
  }

  /// 恢复上次的目录（有就静默恢复，没有返回 false）。
  Future<bool> restoreRoot() async {
    if (store == null) return false;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    if (isDesktop) {
      // 桌面没有「授权」概念：上次的目录还在就直接用
      final String? path = prefs.getString('root_doc_id');
      if (path != null && Directory(path).existsSync()) {
        root = TreeRef(treeUri: 'file://$path', rootDocId: path);
        return true;
      }
      return false;
    }
    final String? treeUri = prefs.getString('root_tree_uri');
    final String? rootDocId = prefs.getString('root_doc_id');
    if (treeUri == null || rootDocId == null) return false;
    root = TreeRef(treeUri: treeUri, rootDocId: rootDocId);
    return true;
  }

  /// 让用户选目录；成功后持久化并返回 true。
  Future<bool> pickRoot() async {
    if (store == null) return false;
    final TreeRef? t = await store!.pickTree();
    if (t == null) return false;
    root = t;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString('root_tree_uri', t.treeUri);
    await prefs.setString('root_doc_id', t.rootDocId);
    return true;
  }

  /// 扫描目录。
  ///
  /// 增量：上一次扫到的文件 size / lastModified 都没变，就直接沿用上次读到的标签
  /// （不清缓存重读，否则几千首每次都要重新跑一遍）。
  Future<ScanOutcome> rescan({
    CancelToken? cancel,
    bool incremental = true,
  }) async {
    final FileStore? st = store;
    final TreeRef? r = root;
    final ScanMergeResult empty =
        ScanMergeResult(files: <VFile>[], reused: 0, fresh: 0, removed: 0);
    if (st == null || r == null) {
      return ScanOutcome(<VFile>[], ScanStats(), empty, 0, '还没有选择曲库目录');
    }
    if (_scanning) {
      return ScanOutcome(<VFile>[], ScanStats(), empty, 0, '正在扫描中，请稍候');
    }
    _scanning = true;
    try {
      final VFile rootDir =
          VFile(docId: r.rootDocId, name: r.rootDocId, dir: true);
      final WalkResult walk =
          await Scanner.scanMusicFiles(st, rootDir, cancel: cancel);
      final ScanMergeResult merge =
          ScanMerge.merge(incremental ? files : null, walk.files);
      files = merge.files;
      _rebuildIndex();
      final ScanStats stats = Scanner.statsOf(files);
      return ScanOutcome(files, stats, merge, walk.duplicates, '');
    } catch (e) {
      return ScanOutcome(<VFile>[], ScanStats(), empty, 0, '扫描失败：$e');
    } finally {
      _scanning = false;
    }
  }

  /// 重建搜索索引（只重建骨架，标签留给 [loadMeta] 逐首填）。
  void _rebuildIndex() {
    index.clear();
    for (final VFile f in files) {
      if (f.dir || !f.audio()) continue;
      final Entry e = Entry(
        docId: f.docId,
        name: f.name,
        relPath: f.relativePath(root?.rootDocId ?? ''),
        size: f.size,
        modified: f.lastModified,
        file: f,
      );
      if (f.metaCached()) e.applyTags(f.cachedTags, f.cachedHasCover);
      index.add(e);
    }
  }

  /// 批量读标签 + 封面（并发 4 路），逐首写回缓存与索引。
  Future<void> loadMeta({
    Iterable<VFile>? only,
    CancelToken? cancel,
    void Function(int done, int total)? onProgress,
  }) async {
    final FileStore? st = store;
    if (st == null || _metaLoading) return;
    final List<VFile> todo = (only ?? files)
        .where((VFile f) => !f.dir && f.audio() && !f.metaCached())
        .toList();
    if (todo.isEmpty) return;
    _metaLoading = true;
    int done = 0;
    try {
      await Net.map<VFile, bool>(todo, Net.readThreads, cancel, (VFile f) async {
        final ScannerHead head = await Scanner.readHead(st, f);
        final Tags tags = head.tags;
        f.cacheMeta(tags,
            cover: head.cover != null && head.cover!.isNotEmpty,
            lyrics: tags.get(Tags.lyrics).trim().isNotEmpty);
        index.find(f.docId)?.applyTags(tags, f.cachedHasCover);
        done++;
        onProgress?.call(done, todo.length);
        return true;
      });
    } finally {
      _metaLoading = false;
    }
  }

  /// 库里所有音频（不含歌词文件）。
  List<VFile> audioFiles() =>
      files.where((VFile f) => !f.dir && f.audio()).toList();

  /// 标签写盘之后必须调用：清掉内存缓存，下次才回源。
  void invalidate(VFile f) {
    Scanner.invalidate(f);
    final Entry? e = index.find(f.docId);
    if (e != null) {
      index.add(Entry(
        docId: f.docId,
        name: f.name,
        relPath: e.relPath,
        size: f.size,
        modified: f.lastModified,
        file: f,
      ));
    }
  }

  /// 测试用：重置。
  void resetForTest() {
    store = null;
    root = null;
    files = <VFile>[];
    index.clear();
    journal = null;
    tx = null;
    runner = null;
    _initialized = false;
  }
}
