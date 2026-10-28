import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/cover/folder_cover.dart';
import '../core/cover/sidecar_cover.dart';
import '../core/fs/desktop_file_store.dart';
import '../core/fs/file_store.dart';
import '../core/fs/saf_file_store.dart';
import '../core/fs/tree_ref.dart';
import '../core/match/batch_memory.dart';
import '../core/match/tag_fill.dart';
import '../core/match/match_queue.dart';
import '../core/model/cancel_token.dart';
import '../core/model/tags.dart';
import '../core/model/vfile.dart';
import 'repo_changes.dart';
import '../core/net/http_client.dart';
import '../core/net/net.dart';
import '../core/net/proxy_settings.dart';
import '../core/scan/library_cache.dart';
import '../core/scan/scan_filter.dart';
import '../core/scan/scan_merge.dart';
import '../core/scan/scan_stats.dart';
import '../core/scan/scanner.dart';
import '../core/scan/search_index.dart';
import '../core/settings/settings.dart';
import '../core/source/endpoints.dart';
import '../core/task/match_runner.dart';
import '../core/tx/journal.dart';
import '../core/tx/tag_transaction.dart';
import '../platform/media_refresh.dart';
import 'theme/theme_controller.dart';

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
class Repo extends ChangeNotifier {
  Repo._();

  /// 按域拆分的变更源：页面订阅自己关心的域，避免无关变更整页重建。
  final RepoChanges changes = RepoChanges();

  /// 发一次域通知，同时保留整体通知（旧监听方不会因此「不动」）。
  void _emit(RepoDomain domain) {
    changes.emit(domain);
    notifyListeners();
  }

  /// 进程内全局单例。
  static final Repo instance = Repo._();

  /// 文件系统抽象（安卓 SAF / 桌面 dart:io）。
  FileStore? store;

  /// 已登记的曲库目录（可为空 = 还没授权）。第一个是「当前」目录。
  final List<TreeRef> roots = <TreeRef>[];

  /// 当前曲库目录（可空 = 还没授权）；[roots] 为空时为 null。
  TreeRef? get root => roots.isEmpty ? null : roots.first;

  /// 上次确实登记过目录，但这次没能恢复（授权失效）——界面据此给提示。
  bool rootLost = false;

  /// 目录记录还在、只是这次读不到（外置存储没插、目录被移走、系统授权表
  /// 暂时读不出来）。与 [rootLost] 的区别：这种情况**不引导重新授权**，
  /// 记录一直保留，下次启动自动再试。
  bool rootUnavailable = false;

  /// 最近一次选目录失败的原因（空 = 没失败）；界面据此给出准确提示，
  /// 而不是笼统的「取消 / 已登记过」。
  String? pickError;

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

  /// 主题控制器（main 创建后挂上来，设置页切换主题用）。
  ThemeController? themeController;

  bool _initialized = false;
  bool _scanning = false;
  bool _metaLoading = false;
  final List<Completer<void>> _metaWaiters = <Completer<void>>[];

  bool get isInitialized => _initialized;
  bool get scanning => _scanning;
  bool get metaLoading => _metaLoading;
  bool get hasRoot => roots.isNotEmpty;

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
    Endpoints.install(_RepoEndpoints(this));
    applyProxy();
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
      'proxy_mode',
      'proxy_host',
      'proxy_port',
      'scan_exclude',
      'scan_ignore_video',
    ]) {
      final Object? v = prefs.get(key);
      if (v != null) settings.set(key, v);
    }
    // 数据源地址（ep:）/ 源开关（ep_on:）/ 逐字段策略（fp:）键名不固定，按前缀捞。
    for (final String key in prefs.getKeys()) {
      if (!key.startsWith('ep:') &&
          !key.startsWith('ep_on:') &&
          !key.startsWith('fp:')) {
        continue;
      }
      final Object? v = prefs.get(key);
      if (v != null) settings.set(key, v);
    }
  }

  /// 把设置写回持久化（界面改了之后调用）。
  Future<void> setSetting(String key, Object? value) async {
    settings.set(key, value);
    _emit(RepoDomain.settings);
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

  /// 应用代理设置（启动时 + 设置页改动后调用）。
  ///
  /// 顺手重建 HTTP 客户端：连接池里是旧代理建的连接，不重建等于设置没生效。
  void applyProxy() {
    final int mode = settings.get<int>('proxy_mode', fallback: 0) ?? 0;
    final String host = settings.get<String>('proxy_host', fallback: '') ?? '';
    final int port = settings.get<int>('proxy_port', fallback: 0) ?? 0;
    NetworkProxy.configure(
      ProxyMode.values[mode.clamp(0, ProxyMode.values.length - 1)],
      host: host,
      port: port > 0 ? '$port' : '',
    );
    Http.reset();
  }

  /// 恢复上次的目录（有就静默恢复，没有返回 false）。
  ///
  /// 关键：**不能只从设置里读 treeUri 就当真**。真正能读写的前提是系统还记着
  /// 这棵树的持久授权；重装、清数据、换设备后授权会消失，此时 listRoots 为空，
  /// 直接拿旧 treeUri 去读会报「不属于任何已授权目录树」（E_NOT_FOUND）。
  /// 所以这里以 [FileStore.roots] 为准：有授权才恢复，没有就返回 false 让界面引导重新授权。
  Future<bool> restoreRoot() async {
    final FileStore? st = store;
    if (st == null) return false;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    List<String> order = _savedOrder(prefs);
    List<TreeRef> mirror = <TreeRef>[];
    if (order.isEmpty) {
      // prefs 没了（被杀在写一半 / 被清数据）：用镜像里的顺序兜底
      mirror = await _readRootsMirror();
      order = <String>[for (final TreeRef t in mirror) t.rootDocId];
    } else {
      mirror = await _readRootsMirror();
    }

    if (isDesktop) {
      // 桌面没有「授权」概念：登记过的目录还在就直接用（不存在的顺手忘掉）。
      //
      // 曾经这里做过一次「升级后首次启动清掉记住的目录」的迁移，结果是用户
      // 更新一次就丢一次曲库。已经删掉：升级不该动用户的数据，只有目录真的
      // 不存在了才忘掉（由下面的 existsSync 判断）。
      final List<String> kept = <String>[];
      void keep(String raw) {
        final String p = raw.replaceAll('\\', '/').trim();
        if (p.isEmpty || !Directory(p).existsSync()) return;
        if (!kept.contains(p)) kept.add(p);
      }
      for (final String path in order) {
        keep(path);
      }
      if (kept.isEmpty) {
        for (final TreeRef t in mirror) {
          keep(t.rootDocId);
        }
      }
      final String? legacy = prefs.getString('root_doc_id');
      if (kept.isEmpty && legacy != null) {
        keep(legacy);
      }
      if (kept.isEmpty) {
        // 记住的目录这次不可用（被删 / 改名 / 外接盘没插）：**只提示，不清记录**。
        // 清掉就意味着「移动硬盘拔一次，曲库目录就永久没了」。
        if (legacy != null || order.isNotEmpty) rootLost = true;
        return false;
      }
      // DesktopFileStore 自己也有一份 _roots（路径白名单），两套记录必须同步，
      // 否则重启恢复出来的目录会被自己的越界校验挡住。
      if (st is DesktopFileStore) {
        for (final String p in kept) {
          st.addRoot(p);
        }
      }
      setRoots(kept.map((String p) => TreeRef(treeUri: 'file://$p', rootDocId: p)).toList());
      rootLost = false;
      unawaited(_writeRootsMirror());
      return true;
    }

    List<TreeRef> granted;
    try {
      granted = await st.roots();
    } catch (_) {
      // 通道暂时不可用 ≠ 没授权：崩溃恢复、平台通道还没就绪时这里会抖一下。
      // 稍等重试一次，仍失败才按「系统侧无授权」处理，避免误报授权失效。
      await Future<void>.delayed(const Duration(milliseconds: 300));
      try {
        granted = await st.roots();
      } catch (_) {
        granted = <TreeRef>[];
      }
    }
    if (granted.isEmpty) {
      final bool everSaved = order.isNotEmpty ||
          (prefs.getString('root_doc_id') ?? '').isNotEmpty;
      final String saved = prefs.getString('root_tree_uri') ?? '';
      // 「授权真被撤销」「存储暂时读不到」「系统授权表还没就绪」三种情况
      // 应对完全不同：只有第一种才该让用户重新选，后两种清掉记录就永久丢了
      // 用户的曲库目录（拔一次移动硬盘就没了）。
      final String state = saved.isEmpty ? 'REVOKED' : await st.authState(saved);
      if (state != 'NOT_READY' && state != 'UNAVAILABLE') {
        rootLost = everSaved;
        rootUnavailable = false;
        return false;
      }
      // 再等一拍确认：启动极早期、外置存储刚插上都可能只是暂时读不到
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final String again = saved.isEmpty ? 'REVOKED' : await st.authState(saved);
      if (again == 'VALID') {
        try {
          granted = await st.roots();
        } catch (_) {
          granted = <TreeRef>[];
        }
      }
      if (granted.isEmpty) {
        // 复查之后仍然读不到授权表，说明不是「启动早期还没就绪」，而是真被撤销了
        // —— 这时候必须让用户重选，不能一直说「暂时读不到」把人晾着。
        // 只有 UNAVAILABLE（授权在、盘读不到）才保留记录等下次。
        rootLost = again != 'UNAVAILABLE' && everSaved;
        rootUnavailable = again == 'UNAVAILABLE';
        return false;
      }
      rootLost = false;
      rootUnavailable = false;
    }
    // 按上次登记的顺序排：先当前目录，再其余
    final List<TreeRef> ordered = <TreeRef>[];
    for (final String id in order) {
      for (final TreeRef t in granted) {
        if (t.rootDocId == id && !ordered.any((TreeRef x) => x.rootDocId == id)) {
          ordered.add(t);
        }
      }
    }
    for (final TreeRef t in granted) {
      if (!ordered.any((TreeRef x) => x.rootDocId == t.rootDocId)) ordered.add(t);
    }
    setRoots(ordered);
    rootLost = false;
    rootUnavailable = false;
    // 顺手把镜像补齐：下次 prefs 出问题还能靠它恢复
    unawaited(_writeRootsMirror());
    return true;
  }

  /// 路径归一：桌面端根目录记的是 `/`、文档 docId 记的是 `\`，比较前必须统一。
  static String _normPath(String p) => p.replaceAll('\\', '/');

  /// 曲库缓存文件（上次扫到的条目 + 读过的标签）。
  Future<File> _libraryCacheFile() async {
    final Directory dir = await _dataDir();
    return File('${dir.path}${Platform.pathSeparator}library_cache.json');
  }

  /// 文件属于哪个根目录（都不匹配返回 null）。
  String? _rootOf(VFile f) {
    final String id = _normPath(f.docId);
    for (final TreeRef r in roots) {
      final String root = _normPath(r.rootDocId);
      final String prefix = root.endsWith('/') ? root : '$root/';
      if (id.startsWith(prefix)) return root;
    }
    return null;
  }

  /// 用上次的缓存先把列表撑起来，不等后台扫描。
  ///
  /// 返回恢复的条目数；0 表示没有可用缓存，调用方照旧走全量扫描。
  /// 缓存里只有音频条目，目录树由随后的增量扫描补齐——界面看的是音频列表，
  /// 组织类操作等扫描完成即可用。
  Future<int> restoreLibraryCache() async {
    if (roots.isEmpty) return 0;
    try {
      final File f = await _libraryCacheFile();
      if (!f.existsSync()) return 0;
      final Map<String, List<VFile>> byRoot =
          LibraryCache.decode(jsonDecode(await f.readAsString()));
      if (byRoot.isEmpty) return 0;
      final List<VFile> restored = <VFile>[];
      final Set<String> seen = <String>{};
      for (final TreeRef r in roots) {
        final List<VFile>? list = byRoot[_normPath(r.rootDocId)];
        if (list == null) continue;
        for (final VFile item in list) {
          if (seen.add(item.docId)) restored.add(item);
        }
      }
      if (restored.isEmpty) return 0;
      files = restored;
      _rebuildIndex();
      _emit(RepoDomain.library);
      return restored.length;
    } catch (_) {
      // 缓存坏了就当没有：最坏是这次多扫一遍，绝不能让启动卡在这里
      return 0;
    }
  }

  /// 缓存写入串行化：并发保存会踩同一个文件，后来的等前一次写完再补一次。
  bool _savingCache = false;
  bool _cacheDirty = false;

  /// 把当前曲库写进缓存（临时产物 → 自检 → 覆盖）。
  ///
  /// 会被并发调用（扫描结束一次 + 读标签途中分批多次），所以串行化 + 唯一临时名，
  /// 否则写出来的缓存会缺条目。
  Future<void> saveLibraryCache() async {
    if (roots.isEmpty) return;
    if (_savingCache) {
      // 已经有一轮在写：标记「写完了再补一次」，并且**等到它真的落盘**——
      // 调用方 await 这个方法时期望缓存已经是最新的
      _cacheDirty = true;
      while (_savingCache || _cacheDirty) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      return;
    }
    _savingCache = true;
    try {
      final Map<String, List<VFile>> byRoot = <String, List<VFile>>{};
      for (final VFile f in files) {
        final String? owner = _rootOf(f);
        if (owner == null) continue;
        byRoot.putIfAbsent(owner, () => <VFile>[]).add(f);
      }
      final String text = jsonEncode(LibraryCache.encode(byRoot));
      // 自检：解不回来就别写，写坏的文件只会让下次启动白白多扫一遍
      if (LibraryCache.decode(jsonDecode(text)).isEmpty &&
          files.any((VFile f) => !f.dir && f.audio())) {
        return;
      }
      final File target = await _libraryCacheFile();
      // 临时名必须唯一：扫描结束的保存与读标签途中的分批保存会同时发起，
      // 共用同一个 .tmp 会互相截断，写出的缓存文件条目数会莫名其妙地少。
      final File tmp = File(
          '${target.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
      await tmp.writeAsString(text);
      await tmp.rename(target.path);
    } catch (_) {
      // 缓存写不进去不影响主流程
    } finally {
      _savingCache = false;
    }
    // 保存期间又有人要存：立刻补一次，别把最后一次改动丢了
    if (_cacheDirty) {
      _cacheDirty = false;
      await saveLibraryCache();
    }
  }

  /// 上次登记的目录顺序（换行分隔）。
  static List<String> _savedOrder(SharedPreferences prefs) {
    final String raw = prefs.getString('roots_order') ?? '';
    if (raw.isEmpty) return <String>[];
    return raw.split('\n').where((String s) => s.trim().isNotEmpty).toList();
  }

  /// 登记多个曲库目录（第一个成为当前目录）。
  void setRoots(List<TreeRef> list) {
    roots
      ..clear()
      ..addAll(list);
    _emit(RepoDomain.root);
  }

  /// 追加一个曲库目录；已存在则返回 false。
  Future<bool> addRoot([TreeRef? picked]) async {
    if (store == null) return false;
    TreeRef? pickedRef;
    try {
      pickedRef = picked ?? await store!.pickTree();
    } on FileStoreException catch (e) {
      // 选目录失败（最常见：系统没给持久授权）要把原因透给界面，
      // 不能吞成「没选」，否则下次启动表现为莫名其妙的丢目录。
      pickError = e.message;
      return false;
    }
    // 重新赋给新的局部变量：try 里赋值的变量不做类型提升
    final TreeRef? t = pickedRef;
    if (t == null) {
      pickError = null;
      return false;
    }
    if (roots.any((TreeRef x) => x.rootDocId == t.rootDocId)) return false;
    // 新加的目录排到最前，立刻成为当前目录，省得再点一次切换
    setRoots(<TreeRef>[t, ...roots]);
    await _persistRoots();
    return true;
  }

  /// 移除一个曲库目录（安卓连系统授权一起放掉）。
  Future<void> removeRoot(TreeRef t) async {
    final FileStore? st = store;
    if (st != null) {
      try {
        await st.releaseTree(t);
      } catch (_) {
        // 释放失败不阻塞：至少从登记列表里去掉
      }
    }
    setRoots(roots.where((TreeRef x) => x.rootDocId != t.rootDocId).toList());
    files = <VFile>[];
    index.clear();
    await _persistRoots();
    _emit(RepoDomain.root);
    _emit(RepoDomain.library);
  }

  /// 把某个已登记目录设为当前（排到最前）。
  Future<void> switchRoot(TreeRef t) async {
    if (roots.length < 2) return;
    setRoots(<TreeRef>[t, ...roots.where((TreeRef x) => x.rootDocId != t.rootDocId)]);
    await _persistRoots();
  }

  /// 曲库目录的镜像文件（prefs 之外多存一份，防「刚好在写 prefs 时被杀」）。
  Future<File> _rootsMirror() async {
    final Directory dir = await _dataDir();
    return File('${dir.path}${Platform.pathSeparator}roots.json');
  }

  /// 读镜像（没有 / 坏了返回空）。
  Future<List<TreeRef>> _readRootsMirror() async {
    try {
      final File f = await _rootsMirror();
      if (!f.existsSync()) return <TreeRef>[];
      final Object? raw = jsonDecode(await f.readAsString());
      if (raw is! Map) return <TreeRef>[];
      final Object? list = raw['roots'];
      if (list is! List) return <TreeRef>[];
      return <TreeRef>[
        for (final Object? item in list)
          if (item is Map)
            TreeRef(
              treeUri: '${item['treeUri'] ?? ''}',
              rootDocId: '${item['rootDocId'] ?? ''}',
            ),
      ].where((TreeRef t) => t.rootDocId.isNotEmpty).toList();
    } catch (_) {
      return <TreeRef>[];
    }
  }

  /// 只写镜像文件（原子替换）；失败不影响主流程。
  Future<void> _writeRootsMirror() async {
    try {
      final File f = await _rootsMirror();
      final File tmp = File('${f.path}.tmp');
      await tmp.writeAsString(
        jsonEncode(<String, Object?>{
          'roots': <Map<String, String>>[
            for (final TreeRef t in roots)
              <String, String>{'treeUri': t.treeUri, 'rootDocId': t.rootDocId},
          ],
        }),
        flush: true,
      );
      await tmp.rename(f.path);
    } catch (_) {
      // 镜像写不进去不影响主流程
    }
  }

  Future<void> _persistRoots() async {
    // 镜像先写，再写 prefs：两边都成功才算稳
    await _writeRootsMirror();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    if (roots.isEmpty) {
      try {
        final File f = await _rootsMirror();
        if (f.existsSync()) await f.delete();
      } catch (_) {
        // 删不掉不影响
      }
      await prefs.remove('roots_order');
      await prefs.remove('root_tree_uri');
      await prefs.remove('root_doc_id');
      return;
    }
    await prefs.setString(
        'roots_order', roots.map((TreeRef t) => t.rootDocId).join('\n'));
    await prefs.setString('root_tree_uri', roots.first.treeUri);
    await prefs.setString('root_doc_id', roots.first.rootDocId);
  }

  /// 移除所有曲库目录：释放授权、清空列表。
  Future<void> clearRoot() async {
    final FileStore? st = store;
    for (final TreeRef t in List<TreeRef>.of(roots)) {
      if (st == null) break;
      try {
        await st.releaseTree(t);
      } catch (_) {
        // 释放失败不阻塞：至少把本地记住的目录清掉
      }
    }
    setRoots(<TreeRef>[]);
    files = <VFile>[];
    index.clear();
    await _persistRoots();
    _emit(RepoDomain.root);
    _emit(RepoDomain.library);
  }

  /// 让用户选目录；成功后登记为当前目录并返回 true。
  Future<bool> pickRoot() async {
    if (store == null) return false;
    TreeRef? pickedRef;
    try {
      pickedRef = await store!.pickTree();
    } on FileStoreException catch (e) {
      // 同 addRoot：授权拿不到要透传原因。
      pickError = e.message;
      return false;
    }
    final TreeRef? t = pickedRef;
    if (t == null) {
      pickError = null;
      return false;
    }
    rootLost = false;
    final bool has = roots.any((TreeRef x) => x.rootDocId == t.rootDocId);
    if (!has) {
      setRoots(<TreeRef>[t, ...roots]);
    } else {
      await switchRoot(t);
    }
    await _persistRoots();
    _emit(RepoDomain.root);
    return true;
  }

  /// 直接把某个目录设为曲库根（桌面拖放用；等价于「选择目录」）。
  ///
  /// 会持久化，下次启动自动恢复。
  Future<bool> useDirectory(String path) async {
    final String p = path.trim().replaceAll('\\', '/');
    if (p.isEmpty) return false;
    if (!Directory(p).existsSync()) return false;
    // DesktopFileStore 自己也有一份 _roots：只改 Repo 会让两套记录不一致
    final FileStore? st = store;
    if (st is DesktopFileStore) st.addRoot(p);
    setRoots(<TreeRef>[TreeRef(treeUri: 'file://$p', rootDocId: p)]);
    files = <VFile>[];
    index.clear();
    await _persistRoots();
    _emit(RepoDomain.root);
    _emit(RepoDomain.library);
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
    final ScanMergeResult empty =
        ScanMergeResult(files: <VFile>[], reused: 0, fresh: 0, removed: 0);
    if (st == null || roots.isEmpty) {
      return ScanOutcome(<VFile>[], ScanStats(), empty, 0, '还没有选择曲库目录');
    }
    if (_scanning) {
      return ScanOutcome(<VFile>[], ScanStats(), empty, 0, '正在扫描中，请稍候');
    }
    _scanning = true;
    try {
      // 多目录：逐个走一遍再合并（docId 本来就带树前缀，不会撞）
      final List<VFile> all = <VFile>[];
      int dup = 0;
      for (final TreeRef r in roots) {
        final VFile rootDir =
            VFile(docId: r.rootDocId, name: r.rootDocId, dir: true);
        final WalkResult walk = await Scanner.scanMusicFiles(st, rootDir,
            cancel: cancel, filter: scanFilter());
        all.addAll(walk.files);
        dup += walk.duplicates;
      }
      final ScanMergeResult merge =
          ScanMerge.merge(incremental ? files : null, all);
      // 一个文件都没扫到时，要分清「目录里真的没音乐」和「目录读不到」：
      // 后者（外置盘没插、目录被移走）如果只说「没有曲目」，用户会以为曲库被吞了。
      if (all.isEmpty) {
        bool readable = true;
        try {
          readable = await st.stat(roots.first.rootDocId) != null;
        } catch (_) {
          readable = false;
        }
        rootUnavailable = !readable;
      } else {
        rootUnavailable = false;
      }
      FolderCover.invalidate();
      SidecarCover.invalidate();
      files = merge.files;
      _rebuildIndex();
      _emit(RepoDomain.root);
      _emit(RepoDomain.library);
      // 扫完就落盘：下次启动直接拿它撑起列表，不必再等这一轮
      unawaited(saveLibraryCache());
      final ScanStats stats = Scanner.statsOf(files);
      return ScanOutcome(
        files,
        stats,
        merge,
        dup,
        rootUnavailable ? '曲库目录暂时读不到' : '',
      );
    } catch (e) {
      return ScanOutcome(<VFile>[], ScanStats(), empty, 0, '扫描失败：$e');
    } finally {
      _scanning = false;
    }
  }

  /// 文件相对「它所属那棵树」的路径。
  ///
  /// 多目录时每棵树的 rootDocId 不同，按当前根去截会截错，这里逐个根试。
  String relPath(VFile f) {
    for (final TreeRef r in roots) {
      final String prefix = r.rootDocId.endsWith('/') ? r.rootDocId : '${r.rootDocId}/';
      if (f.docId.startsWith(prefix)) return f.docId.substring(prefix.length);
    }
    return f.relativePath(roots.isEmpty ? '' : roots.first.rootDocId);
  }

  /// 逐字段的写入策略（三态）。
  ///
  /// 键名用 `fp:<字段>`（与设置备份格式一致，导出时能直接带走）；没配过的字段
  /// 退回旧的单开关 `fill_overwrite`，保证老配置行为不变。
  Map<String, int> tagModes() {
    final bool overwrite =
        settings.get<bool>('fill_overwrite', fallback: false) ?? false;
    final int fallbackMode = overwrite ? TagFill.overwrite : TagFill.supplement;
    final Map<String, int> out = <String, int>{};
    for (final String f in TagFill.candidateFields) {
      out[f] = settings.get<int>('fp:$f', fallback: fallbackMode) ?? fallbackMode;
    }
    return out;
  }

  /// 写入某一字段的策略（设置页逐字段选择）。
  Future<void> setTagMode(String field, int mode) async {
    await setSetting('fp:$field', mode);
    // 老的全局开关跟着一起动，避免别处（旧入口 / 备份）读到的值与这里不一致
    final Map<String, int> m = tagModes();
    final bool allOverwrite =
        m.length == TagFill.candidateFields.length &&
        TagFill.candidateFields.every((String f) => m[f] == TagFill.overwrite);
    await setSetting('fill_overwrite', allOverwrite);
  }

  /// 某个文件属于哪一棵树（多目录时用它决定整理 / 扁平化落到哪儿）。
  TreeRef? rootOf(VFile f) {
    for (final TreeRef r in roots) {
      final String prefix = r.rootDocId.endsWith('/') ? r.rootDocId : '${r.rootDocId}/';
      if (f.docId.startsWith(prefix) || f.docId == r.rootDocId) return r;
    }
    return roots.isEmpty ? null : roots.first;
  }

  /// 当前的扫描过滤（路径关键字 + 忽略视频），没配规则返回 null。
  ScanFilter? scanFilter() {
    final String text = settings.get<String>('scan_exclude', fallback: '') ?? '';
    final bool ignoreVideo =
        settings.get<bool>('scan_ignore_video', fallback: false) ?? false;
    if (text.trim().isEmpty && !ignoreVideo) return null;
    return ScanFilter.parse(text, ignoreVideo: ignoreVideo);
  }

  /// 重建搜索索引（只重建骨架，标签留给 [loadMeta] 逐首填）。
  void _rebuildIndex() {
    index.clear();
    for (final VFile f in files) {
      if (f.dir || !f.audio()) continue;
      final Entry e = Entry(
        docId: f.docId,
        name: f.name,
        relPath: relPath(f),
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
    if (st == null) return;
    // 正在加载时**等待**而不是直接返回：否则并发刷新会以为加载完了，
    // 列表里只剩文件名、元数据一直不出现
    if (_metaLoading) {
      _metaWaiters.add(Completer<void>());
      await _metaWaiters.last.future;
      return;
    }
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
        // 分批落盘：长任务中途被取消 / 被杀，已经读过的部分仍然留得下，
        // 下次启动不必从零开始
        if (done % 100 == 0) unawaited(saveLibraryCache());
        onProgress?.call(done, todo.length);
        return true;
      });
    } finally {
      _metaLoading = false;
      for (final Completer<void> c in _metaWaiters) {
        if (!c.isCompleted) c.complete();
      }
      _metaWaiters.clear();
      _emit(RepoDomain.meta);
      _emit(RepoDomain.library);
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
    roots.clear();
    rootLost = false;
    files = <VFile>[];
    index.clear();
    journal = null;
    tx = null;
    runner = null;
    _initialized = false;
  }
}

/// 数据源的用户设置（改过的接口地址 + 源开关），落在普通偏好里。
///
/// 键名与设置备份格式一致：`ep:<端点>` 存地址、`ep_on:<源>` 存开关，
/// 这样「导出设置」能带上它们，换机也能还原。
class _RepoEndpoints implements EndpointsConfig {
  _RepoEndpoints(this.repo);

  final Repo repo;

  @override
  String? overrideUrl(String endpointKey) =>
      repo.settings.get<String>('ep:$endpointKey');

  @override
  bool enabled(String sourceKey) =>
      repo.settings.get<bool>('ep_on:$sourceKey', fallback: true) ?? true;

  @override
  void setOverride(String endpointKey, String? url) {
    // 留空 = 恢复默认地址（用默认值请求）。
    unawaited(repo.setSetting('ep:$endpointKey', (url == null || url.isEmpty) ? null : url));
  }

  @override
  void setEnabled(String sourceKey, bool enabled) {
    unawaited(repo.setSetting('ep_on:$sourceKey', enabled));
  }
}
