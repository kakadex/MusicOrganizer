import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/repo.dart';
import '../../app/repo_changes.dart';
import '../../app/ui_kit.dart';
import '../../core/cleanup/cleaner.dart';
import '../../core/cleanup/empty_dirs.dart';
import '../../core/cleanup/junk.dart';
import '../../core/dedupe/content_reader.dart';
import '../../core/dedupe/duplicates.dart';
import '../../core/fs/file_store.dart';
import '../../core/fs/tree_ref.dart';
import '../../core/match/text_util.dart';
import '../../core/model/cancel_token.dart';
import '../../core/model/duplicate_group.dart';
import '../../core/model/progress.dart';
import '../../core/model/tags.dart';
import '../../core/model/task_control.dart';
import '../../core/model/vfile.dart';
import '../../core/organize/folder_template.dart';
import '../../core/organize/organizer.dart';
import '../../core/scan/scanner.dart';
import '../../core/task/task_center.dart';
import '../../core/tx/write_preview.dart';
import '../common/write_confirm_sheet.dart';
import 'rename_flow.dart';

/// 整理页要显示哪一块：全部（旧行为）/ 只显示扫描整理 / 只显示清理与查重。
///
/// 主界面已改成只有音乐库，整理相关功能从「设置 → 整理」两个入口进入：
/// 每个入口带一个 section，页面只渲染对应那张卡，不再平铺全部内容。
enum OrganizeSection { all, organize, cleanup }

/// 整理页：**按 section 显示任务卡**（扫描与整理 / 清理与查重）。
///
/// 危险动作（移动、删除）一律「先出计划 → 用户确认 → 再执行」。
class OrganizePage extends StatefulWidget {
  const OrganizePage({
    super.key,
    this.section = OrganizeSection.all,
    this.embedded = false,
  });

  /// 只渲染哪一块。
  final OrganizeSection section;

  /// 作为二级页从设置推入：顶部显示返回箭头。
  final bool embedded;

  /// 本次运行内的垃圾扫描结果缓存。
  ///
  /// 安卓上 SAF 每次列目录都是一次跨进程往返，整树遍历即使不在主线程做，
  /// 也会让手机持续发热耗电 —— 所以一个曲库目录集合只扫一次，返回再进来
  /// 直接用缓存（要重扫点那一行右侧的刷新按钮）。换目录时键变了，自然重扫。
  static List<VFile>? _junkCache;
  static String _junkCacheKey = '';

  /// 清掉扫描结果缓存（单测之间需要互不影响）。
  @visibleForTesting
  static void resetJunkCacheForTest() {
    _junkCache = null;
    _junkCacheKey = '';
  }

  @override
  State<OrganizePage> createState() => _OrganizePageState();
}

/// 整理页正在跑的任务类型。
///
/// 只用一个 bool 的话，「扫描统计」转圈时「自动整理」按钮也会跟着转，
/// 看起来就像是自动整理被触发了。分开之后每个按钮只转自己的圈。
enum _BusyOn { none, scan, organize, other }

class _OrganizePageState extends State<OrganizePage> {
  _BusyOn _busyOn = _BusyOn.none;
  String _status = '';

  /// 有任务在跑：防重入、置灰按钮。
  bool get _busy => _busyOn != _BusyOn.none;

  /// 垃圾文件候选：走全量遍历（含非音频），不是曲库列表里挑。
  List<VFile> _junkFiles = <VFile>[];
  bool _junkScanning = false;

  /// 是否已经扫过一次（没扫过时「垃圾文件」那行显示「准备扫描」）。
  bool _junkScanned = false;
  _FlagToken? _junkCancel;

  /// 扫描进度：本次已经走过多少个文件（只在扫描期间显示）。
  int _junkChecked = 0;

  Repo get _repo => Repo.instance;

  @override
  void dispose() {
    // 返回上级时立刻停掉垃圾扫描：整树遍历在主 isolate 上跑，
    // 不取消的话返回动画会被磁盘 IO 拖住（用户实测的「返回卡顿」）。
    _junkCancel?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // 0.2.58 起「垃圾文件」不再需要先点一下：进页面就在后台自动扫一次。
    //
    // 仍然等首帧之后再排（转场动画约 300ms），而且结果按「曲库目录集合」
    // 缓存在本次运行里 —— 安卓上 SAF 是跨进程查询，整树遍历很贵，返回再进来
    // 不重扫（见 [_autoJunkScan]）。只想看扫描整理那半页时不扫。
    if (widget.section != OrganizeSection.organize) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_autoJunkScan());
      });
    }
  }

  /// 自动扫描的入口：有缓存就直接用，没有才真的遍历一遍。
  Future<void> _autoJunkScan() async {
    if (_junkKey().isEmpty) return; // 还没选曲库目录
    final List<VFile>? cached = OrganizePage._junkCacheKey == _junkKey()
        ? OrganizePage._junkCache
        : null;
    if (cached != null) {
      setState(() {
        _junkFiles = cached;
        _junkScanned = true;
      });
      return;
    }
    // 先让转场动画走完再碰磁盘：首帧和成百上千次目录查询挤在一起就是卡顿。
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!mounted || _junkScanning || _junkScanned) return;
    await _scanJunk();
  }

  /// 缓存键：曲库目录集合（换目录 / 多选目录变了就要重扫）。
  String _junkKey() =>
      _repo.roots.map((TreeRef r) => r.rootDocId).join('|');

  @override
  Widget build(BuildContext context) {
    // 只订阅「曲目 + 目录」两域：设置项变化不该让整理页整页重建。
    //
    // 外层必须是 Scaffold：本页现在由「设置 → 整理」push 进来，不再是 shell 的
    // 一个 tab。少了它，卡片里的 InkWell 一悬停就会 Material.of(null) 崩掉。
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: _repo.changes.of(
              <RepoDomain>[RepoDomain.library, RepoDomain.root]),
          builder: (BuildContext context, Widget? _) => _body(context),
        ),
      ),
    );
  }

  /// 遍历整棵目录树找垃圾（Thumbs.db / .bak / .tmp 都不是音频，不在曲库列表里）。
  ///
  /// 0.2.58 起由 [initState] 自动触发，也可以点那一行 / 右侧刷新手动触发。
  /// 遍历过程中每 20 个文件回一次进度，界面显示「已扫过 N 个文件」和一条进度条；
  /// 随时可以点「停止」，离开页面（[dispose]）也会取消。
  Future<void> _scanJunk() async {
    final FileStore? st = _repo.store;
    if (st == null || _repo.roots.isEmpty) return;
    if (!mounted || _junkScanning) return;
    final _FlagToken token = _FlagToken();
    _junkCancel = token;
    setState(() {
      _junkScanning = true;
      _junkChecked = 0;
    });
    try {
      final List<VFile> all = <VFile>[];
      final _JunkProgress progress = _JunkProgress((int done, String _) {
        if (!mounted || token.isCancelled()) return;
        setState(() => _junkChecked = done);
      });
      for (final TreeRef r in _repo.roots) {
        if (token.isCancelled()) return;
        final VFile rootDir = VFile(docId: r.rootDocId, name: r.rootDocId, dir: true);
        all.addAll(await Scanner.walkAll(st, rootDir,
            filter: _repo.scanFilter(),
            cancel: token,
            progress: progress,
            progressEvery: 20));
        if (token.isCancelled()) return;
      }
      if (!mounted || token.isCancelled()) return;
      final List<VFile> junk = all.where(Junk.isJunk).toList();
      OrganizePage._junkCache = junk;
      OrganizePage._junkCacheKey = _junkKey();
      if (!mounted) return;
      setState(() {
        _junkFiles = junk;
        _junkScanning = false;
        _junkChecked = 0;
        _junkScanned = true;
      });
    } catch (_) {
      if (mounted && !token.isCancelled()) {
        setState(() {
          _junkScanning = false;
          _junkChecked = 0;
        });
      }
    }
  }

  /// 停止正在跑的扫描（结果作废，下次进来会重扫）。
  void _stopJunkScan() {
    _junkCancel?.cancel();
    if (!mounted) return;
    setState(() {
      _junkScanning = false;
      _junkChecked = 0;
    });
  }

  /// 删完垃圾后重新扫一遍（保持「发现 N 个」是新数）。
  Future<void> _refreshJunk() async {
    OrganizePage._junkCache = null;
    OrganizePage._junkCacheKey = '';
    await _scanJunk();
  }

  Widget _body(BuildContext context) {
    // 只遍历一次：audio 与「待归类」都用同一份列表算，避免大曲库下每次
    // 重建都跑两遍全表（之前是 _body 一遍、_scanCard 又一遍）。
    final List<VFile> audioFiles = _repo.audioFiles();
    final int audio = audioFiles.length;
    final int unorganized = audioFiles
        .where((VFile f) => !_repo.relPath(f).contains('/'))
        .length;
    final bool showOrganize = widget.section != OrganizeSection.cleanup;
    final bool showCleanup = widget.section != OrganizeSection.organize;
    final String title = switch (widget.section) {
      OrganizeSection.cleanup => '清理与查重',
      OrganizeSection.organize => '扫描与整理',
      OrganizeSection.all => '整理',
    };
    return Column(
      children: <Widget>[
        PageHeader(
          title: title,
          subtitle: _repo.hasRoot
              ? '$audio 首 · ${_status.isEmpty ? '待整理' : _status}'
              : '还没有选择曲库目录',
          leading: widget.embedded
              ? IconButton(
                  tooltip: '返回',
                  iconSize: 28,
                  icon: Icon(Icons.arrow_back,
                      size: 28, color: MoKit.text(context)),
                  onPressed: () => Navigator.of(context).maybePop(),
                )
              : null,
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 16),
            children: <Widget>[
              if (showOrganize)
                _scanCard(audio,
                    unorganized: unorganized,
                    showTitle: widget.section == OrganizeSection.all),
              if (showCleanup)
                _cleanCard(showTitle: widget.section == OrganizeSection.all),
            ],
          ),
        ),
      ],
    );
  }

  /// [showTitle] 为 false 时不画卡片标题 —— 二级页顶部已经有同名标题了，
  /// 再画一次会出现两个「清理与查重」。
  Widget _scanCard(int audio, {int? unorganized, bool showTitle = true}) {
    final int pending = unorganized ??
        _repo.audioFiles().where((VFile f) {
          final rel = _repo.relPath(f);
          return !rel.contains('/');
        }).length;
    return SectionCard(
      title: showTitle ? '扫描与整理' : null,
      subtitle: _repo.hasRoot ? '$audio 首 · 待归类 $pending 首' : '先选一个曲库目录',
      children: <Widget>[
        // 扫描与整理合并成一个动作：点一次先重扫曲库，再按规则出移动计划，
        // 确认后执行，结束后弹统计。原来的「扫描统计」按钮不再单独存在。
        MoButton(
          '自动整理',
          busy: _busy,
          onPressed: _busy ? null : _organize,
        ),
        const SizedBox(height: 8),
        MoButton(
          '目录规则：${FolderTemplate.of(_template).name}',
          primary: false,
          onPressed: _busy ? null : _pickTemplate,
        ),
        const SizedBox(height: 8),
        Text(
          '点一次做完整套：先重新扫描曲库，再按上面的规则算目标目录并给出移动计划，'
          '你在预览里逐首确认后才动文件；整理完弹一份统计。'
          '认不出歌手的不搬，同名文件一律跳过，绝不覆盖。',
          style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context)),
        ),
      ],
    );
  }

  /// [showTitle] 为 false 时不画卡片标题（二级页顶部已有同名标题）。
  Widget _cleanCard({bool showTitle = true}) {
    final List<VFile> all = _repo.files;
    final int junk = _junkFiles.length;
    return SectionCard(
      title: showTitle ? '清理与查重' : null,
      subtitle: '只看不改，列出来再决定',
      children: <Widget>[
        MoTile(
          title: '文件名清理',
          subtitle: '去污染后缀 / 重编码标记 / 多余空格，或按标签改名',
          icon: Icons.drive_file_rename_outline,
          onTap: all.isEmpty ? null : () => _renameFiles(all),
        ),
        MoTile(
          title: '重复文件筛选',
          subtitle: '内容一致的重复份，按时长 / 码率 / 体积挑出最该删的那份',
          icon: Icons.copy_all_outlined,
          onTap: all.isEmpty ? null : () => _dedupe(all),
        ),
        MoTile(
          title: '扁平化文件夹',
          subtitle: '把所有子目录里的曲子搬到当前目录这一层（撞名自动加 _2，不覆盖）',
          icon: Icons.account_tree_outlined,
          onTap: all.isEmpty ? null : _flatten,
        ),
        MoTile(
          title: '清理空文件夹',
          subtitle: '递归删除没有任何文件的子目录（根目录与「未识别」保留）',
          icon: Icons.folder_delete_outlined,
          onTap: all.isEmpty && !_repo.hasRoot ? null : _emptyDirs,
        ),
        MoTile(
          title: '垃圾文件',
          // 0.2.58：进页面自动在后台扫，不用先点一下；扫过就复用本次运行的结果。
          // 扫描中显示进度条与已扫过的数量，点一下即停止；扫完右侧有刷新按钮。
          subtitle: _junkScanning
              ? '正在后台扫描… 已扫过 $_junkChecked 个文件（点一下停止）'
              : (!_junkScanned
                  ? '准备扫描（Thumbs.db / .bak / .tmp / 0 字节）'
                  : (junk == 0
                      ? '没有发现'
                      : '发现 $junk 个（.bak / Thumbs.db / 0 字节…）')),
          icon: Icons.delete_outline,
          trailing: _junkScanning
              ? const SizedBox(
                  width: 72,
                  child: LinearProgressIndicator(minHeight: 3),
                )
              : (!_junkScanned
                  ? null
                  : IconButton(
                      tooltip: '重新扫描',
                      icon: Icon(Icons.refresh,
                          size: 20, color: MoKit.sub(context)),
                      onPressed: _scanJunk,
                    )),
          onTap: _junkScanning
              ? _stopJunkScan
              : (!_junkScanned
                  ? () => _scanJunk()
                  : (junk == 0 ? null : () => _junk())),
        ),
      ],
    );
  }

  /// 当前目录规则；没设过、或存的不是内置模板时，回到默认的「歌手」。
  ///
  /// 旧版本存过已下线的模板（「年代 / 歌手」「专辑 / 歌手」）时按默认处理：
  /// 否则界面会把这串占位符原样当名字显示，选项列表里也找不到它。
  String get _template {
    final String? saved = _repo.settings.get<String>('organize_template');
    if (saved == null) return FolderTemplate.builtin.first.pattern;
    final bool known =
        FolderTemplate.builtin.any((FolderTemplate t) => t.pattern == saved);
    if (!known || FolderTemplate.validate(saved) != null) {
      return FolderTemplate.builtin.first.pattern;
    }
    return saved;
  }

  Future<void> _pickTemplate() async {
    final String current = _template;
    final String? picked = await showMoSheet<String>(
      context,
      title: '归类目录规则',
      children: <Widget>[
        for (final FolderTemplate t in FolderTemplate.builtin)
          ListTile(
            title: Text(t.name),
            subtitle: Text(t.pattern),
            trailing: t.pattern == current
                ? Icon(Icons.check, color: MoKit.primary(context))
                : null,
            onTap: () => Navigator.of(context).pop(t.pattern),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 8, MoKit.pagePad, 12),
          child: Text(
            '认不出歌手的曲目一律不搬；同一目标目录里有同名文件时跳过，绝不覆盖。',
            style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context)),
          ),
        ),
      ],
    );
    if (picked == null || !mounted) return;
    await _repo.setSetting('organize_template', picked);
    if (mounted) setState(() {});
  }

  Future<void> _organize() async {
    if (_busy) return;
    if (TaskCenter.isBusy()) {
      moSnack(context, '已有任务在跑，先等它结束');
      return;
    }
    final String rootId = _repo.root?.rootDocId ?? '';
    if (rootId.isEmpty) {
      moSnack(context, '先选一个曲库目录');
      return;
    }

    // ① 先重新扫描（原「扫描统计」那一步并进来了）：整理前的目录状态必须是新的，
    //    否则会按上一次的列表算目标位置。
    setState(() {
      _busyOn = _BusyOn.scan;
      _status = '正在扫描…';
    });
    final ScanOutcome out = await _repo.rescan();
    if (!mounted) return;
    if (!out.ok) {
      setState(() {
        _busyOn = _BusyOn.none;
        _status = '';
      });
      moSnack(context, '扫描失败：${out.error}');
      return;
    }
    await _repo.loadMeta();
    if (!mounted) return;
    setState(() {
      _busyOn = _BusyOn.none;
      _status = '';
    });

    // ② 按目录规则算移动计划
    final List<VFile> files = _repo.audioFiles();
    if (files.isEmpty) {
      moSnack(context, '曲库里还没有曲目');
      return;
    }
    final List<MovePlan> plans = Organizer.plan(
      files,
      rootDocId: rootId,
      onlyUnorganized: true,
      template: _template,
    );
    if (plans.isEmpty) {
      moSnack(context, '没有需要归位的曲目');
      return;
    }
    final int conflicts = plans.where((MovePlan p) => p.conflict).length;
    // 移动也是写盘：逐首列出「现在在哪 → 要搬到哪」，由用户勾选后再执行
    final List<WriteTarget> targets = <WriteTarget>[
      for (final MovePlan p in plans)
        WriteTarget(
          docId: p.file.docId,
          name: p.file.name,
          path: _repo.relPath(p.file),
          kind: WriteKind.move,
          note: p.conflict ? '目标已有同名文件，会跳过' : p.reason,
          risky: p.conflict,
          lines: <WriteLine>[
            WriteLine(
              label: '位置',
              oldText: _repo.relPath(p.file),
              newText: '${p.targetPath}/${p.file.name}',
            ),
          ],
          file: p.file,
          data: p,
        ),
    ];
    final List<WriteTarget>? picked = await WriteConfirmSheet.show(
      context,
      title: '整理计划',
      subtitle: conflicts > 0
          ? '其中 $conflicts 首目标位置已有同名文件，会跳过（不覆盖）'
          : '目标位置没有同名文件，可以安全执行',
      targets: targets,
      commitLabel: '执行移动',
      unit: '首',
      verb: '移动',
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    final Set<String> keep = <String>{for (final WriteTarget t in picked) t.docId};
    final List<MovePlan> doList =
        plans.where((MovePlan p) => keep.contains(p.file.docId)).toList();

    setState(() => _busyOn = _BusyOn.organize);
    final RunningTask? task = TaskCenter.start('自动整理');
    final TaskControl? control = task?.control;
    try {
      final OrganizeResult r = await Organizer.execute(_repo.store!, doList,
          onProgress: (int done, int total) => control?.report(done, total, '移动中'),
          cancel: control);
      if (!mounted) return;
      setState(() => _busyOn = _BusyOn.none);
      if (r.ok > 0) await _repo.rescan();
      if (!mounted) return;
      // ③ 结束弹统计（移动 / 跳过 / 失败 + 整理后的曲库状况），替代原来的一行提示
      await _showOrganizeSummary(r);
    } finally {
      TaskCenter.finish();
    }
  }

  /// 整理完成后的统计弹窗。
  Future<void> _showOrganizeSummary(OrganizeResult r) async {
    final List<VFile> files = _repo.audioFiles();
    final int audio = files.length;
    final int pending =
        files.where((VFile f) => !_repo.relPath(f).contains('/')).length;
    final bool moved = r.ok > 0;
    await showMoSheet<void>(
      context,
      title: moved ? '整理完成' : '没有移动文件',
      actionLabel: '知道了',
      onAction: () => Navigator.of(context).maybePop(),
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 0, MoKit.pagePad, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _summaryRow('已移动', '${r.ok} 首'),
              _summaryRow('跳过', '${r.skipped} 首'),
              if (r.failed > 0) _summaryRow('失败', '${r.failed} 首'),
              if (r.cancelled) _summaryRow('状态', '中途停止，已移动的不回滚'),
              const SizedBox(height: 10),
              Container(height: 1, color: MoKit.line(context)),
              const SizedBox(height: 10),
              _summaryRow('曲库', '共 $audio 首'),
              _summaryRow('仍待归类', '$pending 首'),
              const SizedBox(height: 6),
              Text(
                '跳过通常是目标目录已有同名文件，或曲目已经在该目录下；'
                '认不出歌手的曲目不会被移动。',
                style: TextStyle(
                    fontSize: MoKit.fsCaption, color: MoKit.sub(context)),
              ),
              if (r.errors.isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                Text('失败原因（前 ${r.errors.length} 条）：',
                    style: TextStyle(
                        fontSize: MoKit.fsCaption, color: MoKit.err(context))),
                for (final String e in r.errors.take(5))
                  Text('· $e',
                      style: TextStyle(
                          fontSize: MoKit.fsCaption,
                          color: MoKit.err(context))),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _summaryRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 76,
            child: Text(label,
                style: TextStyle(
                    fontSize: MoKit.fsBody, color: MoKit.sub(context))),
          ),
          Expanded(
            child: Text(value,
                style: TextStyle(
                    fontSize: MoKit.fsBody,
                    fontWeight: FontWeight.w600,
                    color: MoKit.text(context))),
          ),
        ],
      ),
    );
  }

  /// 文件名清理 / 改名：先选规则或模板，出计划，确认后才动盘。
  Future<void> _renameFiles(List<VFile> files) async {
    await runRenameFlow(context, files);
  }

  Future<void> _dedupe(List<VFile> files) async {
    if (_busy) return;
    if (TaskCenter.isBusy()) {
      moSnack(context, '已有任务在跑，先等它结束');
      return;
    }
    final FileStore? store = _repo.store;
    // 第一遍：只比文件名（不读标签，秒出）。把「同名但文件名没写艺人」的候选挑出来，
    // 读它们内嵌标签里的艺人，用来区分翻唱 / 重名 —— 与 Java 版一致，避免把不同歌手的
    // 同名歌曲误判为重复。
    List<DuplicateGroup> groups = Duplicates.find(files);
    if (!mounted) return;
    if (groups.isNotEmpty) {
      final Map<String, VFile> byDoc = <String, VFile>{};
      for (final VFile f in files) {
        byDoc[f.docId] = f;
      }
      final Set<String> need = <String>{};
      for (final DuplicateGroup g in groups) {
        for (final DuplicateItem it in g.files) {
          if (DuplicateGroup.artistKeyOf(it.file.stem()).isEmpty) {
            need.add(it.file.docId);
          }
        }
      }
      if (need.isNotEmpty) {
        final Map<String, String> artistMap = <String, String>{};
        await _readTagArtists(byDoc, need, artistMap);
        if (!mounted) return;
        groups = Duplicates.find(files,
            tagArtist: (VFile f) => artistMap[f.docId] ?? '');
      }
    }
    // 第二遍：拿不准的组去比对内容（大小 + 首尾各 64KB）。文件名只给线索，内容才给结论：
    // 内容对不上的说明只是名字像（不同版本 / 翻唱），不是重复。
    if (groups.isNotEmpty && store != null) {
      setState(() => _busyOn = _BusyOn.other);
      await Duplicates.verifyContent(groups, (VFile f) => ContentReader.sample(store, f));
      if (!mounted) return;
      setState(() => _busyOn = _BusyOn.none);
    }
    if (groups.isEmpty) {
      moSnack(context, '没有发现相似文件名');
      return;
    }
    // 内容不同的组不算重复：单列出来，免得把别人的歌当成重复删了。
    final List<DuplicateGroup> dups = groups
        .where((DuplicateGroup g) => g.content != DuplicateGroup.contentDiff)
        .toList();
    final List<DuplicateGroup> lookalikes = groups
        .where((DuplicateGroup g) => g.content == DuplicateGroup.contentDiff)
        .toList();
    if (dups.isEmpty && lookalikes.isEmpty) {
      moSnack(context, '没有发现重复文件');
      return;
    }
    // 默认勾选：确证重复里「不是建议保留那份」的；疑似与「内容不同」的一律不勾
    // （查重是提示，误删不可逆）。
    // 默认勾选：每组只勾「最该删的那一份」—— 时长最短、码率最低、体积最小
    // 的那个（[DuplicateGroup.recommendRemove]）；其余默认保留。
    // 疑似组与「内容不同」组一律不勾（查重是提示，误删不可逆）。
    final Map<String, bool> picked = <String, bool>{};
    for (final DuplicateGroup g in dups) {
      final int drop = g.suspect ? -1 : DuplicateGroup.recommendRemove(g);
      for (int i = 0; i < g.files.length; i++) {
        final DuplicateItem it = g.files[i];
        picked[it.file.docId] = i == drop && drop >= 0;
      }
    }
    for (final DuplicateGroup g in lookalikes) {
      for (final DuplicateItem it in g.files) {
        picked[it.file.docId] = false;
      }
    }
    int pickedCount() => picked.values.where((bool b) => b).length;
    // 底栏不参与滚动：勾选数变了要能实时刷新
    final ValueNotifier<int> pickedNow = ValueNotifier<int>(pickedCount());

    final bool? go = await showMoSheet<bool>(
      context,
      title: dups.isEmpty
          ? '没有发现重复文件'
          : '重复 ${dups.length} 组'
              '${lookalikes.isEmpty ? '' : ' · 另有 ${lookalikes.length} 组只是名字像'}',
      footer: Builder(
        builder: (BuildContext fctx) => ValueListenableBuilder<int>(
          valueListenable: pickedNow,
          builder: (BuildContext _, int n, Widget? _) => Row(
            children: <Widget>[
              Expanded(
                child: Text('已勾选 $n 个（每组默认只删最差的那份）',
                    style: TextStyle(
                        fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
              ),
              MoButton('删除勾选的 $n 个',
                  primary: false,
                  onPressed: n == 0 ? null : () => Navigator.of(fctx).pop(true)),
            ],
          ),
        ),
      ),
      children: <Widget>[
        StatefulBuilder(builder: (BuildContext _, StateSetter setSheet) {
          // 每次勾选都同步刷新底栏计数
          void sync(VoidCallback fn) => setSheet(() {
                fn();
                pickedNow.value = pickedCount();
              });
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (dups.isNotEmpty)
                Padding(
                  padding:
                      const EdgeInsets.fromLTRB(MoKit.pagePad, 0, MoKit.pagePad, 4),
                  child: Text('大小与首尾各 64KB 一致，确认为同一份文件：',
                      style: TextStyle(
                          fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
                ),
              for (final DuplicateGroup g in dups.take(50))
                _dupGroup(g, false, picked, sync),
              if (lookalikes.isNotEmpty) ...<Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      MoKit.pagePad, 14, MoKit.pagePad, 4),
                  child: Text('只是名字像，内容对不上，不是重复（不勾选）：',
                      style: TextStyle(
                          fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
                ),
                for (final DuplicateGroup g in lookalikes.take(50))
                  _dupGroup(g, true, picked, sync),
              ],
            ],
          );
        }),
      ],
    );
    if (go != true) return;
    if (!mounted) return;
    // 校验：每组至少留一个，别把唯一一份删了
    for (final DuplicateGroup g in groups) {
      int remain = 0;
      for (final DuplicateItem it in g.files) {
        if (picked[it.file.docId] != true) remain++;
      }
      if (remain == 0) {
        moSnack(context, '有整组都被勾上了，每组至少要留一个 —— 取消后重试');
        return;
      }
    }
    int ok = 0;
    int fail = 0;
    for (final DuplicateGroup g in groups) {
      for (final DuplicateItem it in g.files) {
        if (picked[it.file.docId] != true) continue;
        if (await _repo.store!.delete(it.file)) {
          ok++;
        } else {
          fail++;
        }
      }
    }
    if (!mounted) return;
    await _repo.rescan();
    if (!mounted) return;
    moSnack(context, '已删除 $ok 个${fail > 0 ? '，失败 $fail 个' : ''}');
  }

  /// 查重结果里的一组。[lookalike] 为 true 表示「名字像但内容不同」。
  Widget _dupGroup(DuplicateGroup g, bool lookalike, Map<String, bool> picked,
      StateSetter setSheet) {
    final Color tag = lookalike ? MoKit.sub(context) : MoKit.ok(context);
    // 「建议保留」= 组里最好的一份（时长最长 / 码率最高 / 体积最大）
    final int keep = DuplicateGroup.recommendKeepBest(g);
    return Padding(
      padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 6, MoKit.pagePad, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                margin: const EdgeInsets.only(right: 6),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                    color: tag.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(6)),
                child: Text(lookalike ? '内容不同' : '内容一致',
                    style: TextStyle(fontSize: 10, color: tag)),
              ),
              if (g.suspect)
                Container(
                  margin: const EdgeInsets.only(right: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                      color: MoKit.warn(context).withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(6)),
                  child: Text('疑似',
                      style: TextStyle(fontSize: 10, color: MoKit.warn(context))),
                ),
              Expanded(
                child: Text('${g.files.length} 个文件 · 相似度 ${(g.score * 100).round()}%',
                    style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
              ),
            ],
          ),
          for (int i = 0; i < g.files.length; i++)
            _dupFileRow(g, i, keep, picked, setSheet),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(lookalike
                ? '首尾采样对不上 —— 不是同一份内容（可能是不同版本或别人的翻唱）。'
                : '重复占用约 ${TextUtil.formatSize(g.wastedBytes())}',
                style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
          ),
        ],
      ),
    );
  }

  /// 组里的一行（带勾选框）。
  Widget _dupFileRow(DuplicateGroup g, int index, int keep,
      Map<String, bool> picked, StateSetter setSheet) {
    final DuplicateItem it = g.files[index];
    final bool isKeep = index == keep;
    final bool on = picked[it.file.docId] == true;
    // 目录与文件名分开显示：文件名要完整（不截断），目录单独一行小字
    final String rel = it.relative;
    final String dir = rel.endsWith(it.file.name)
        ? rel.substring(0, rel.length - it.file.name.length)
        : '';
    final int durMs = it.file.cachedDurationMs;
    final int brKbps = it.file.cachedBitrateKbps;
    final List<String> meta = <String>[
      if (it.size > 0) TextUtil.formatSize(it.size),
      if (durMs > 0) TextUtil.formatDuration(durMs / 1000.0),
      if (brKbps > 0) '$brKbps kbps',
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 28,
            height: 28,
            child: Checkbox(
              value: on,
              onChanged: (bool? v) =>
                  setSheet(() => picked[it.file.docId] = v == true),
              visualDensity: VisualDensity.compact,
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                // 完整文件名：换行显示，不截断
                Text(it.file.name,
                    style: TextStyle(
                        fontSize: MoKit.fsBody, color: MoKit.text(context))),
                if (dir.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text(dir.trim(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: MoKit.fsCaption, color: MoKit.faint(context))),
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    <String>[
                      if (meta.isNotEmpty) meta.join('  ·  '),
                      if (isKeep) '建议保留',
                      if (on) '将删除',
                    ].join('  ·  '),
                    style: TextStyle(
                        fontSize: MoKit.fsCaption,
                        color: on ? MoKit.err(context) : MoKit.sub(context)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 给候选文件补读内嵌标签艺人（只限 [docIds]，带缓存、限并发 8），让查重能用艺人区分
  /// 翻唱 / 重名。结果写进 [out]（docId → 原始艺人串，由 [Duplicates.find] 归一）。
  Future<void> _readTagArtists(Map<String, VFile> byDoc, Set<String> docIds,
      Map<String, String> out) async {
    final List<VFile> targets = docIds
        .where((String id) => byDoc.containsKey(id))
        .map((String id) => byDoc[id]!)
        .toList();
    const int k = 8;
    for (int i = 0; i < targets.length; i += k) {
      final int end = i + k < targets.length ? i + k : targets.length;
      final List<VFile> batch = targets.sublist(i, end);
      await Future.wait(batch.map((VFile f) async {
        try {
          final Tags t = await Scanner.readTags(_repo.store!, f);
          final String a = t.get('artist').trim();
          if (a.isNotEmpty) out[f.docId] = a;
        } catch (_) {
          // 读不到就当没有艺人，退回文件名 + 时长判定
        }
      }));
    }
  }

  /// 扁平化：子目录里的音频 → 当前曲库目录这一层。
  Future<void> _flatten() async {
    if (_busy) return;
    if (TaskCenter.isBusy()) {
      moSnack(context, '已有任务在跑，先等它结束');
      return;
    }
    final FileStore? st = _repo.store;
    if (st == null || _repo.roots.isEmpty) return;
    final List<FlattenPlan> plans = <FlattenPlan>[];
    for (final TreeRef r in _repo.roots) {
      final VFile rootDir = VFile(docId: r.rootDocId, name: r.rootDocId, dir: true);
      List<VFile> all = <VFile>[];
      try {
        all = await Scanner.walkAll(st, rootDir, filter: _repo.scanFilter());
      } catch (e) {
        if (mounted) moSnack(context, '遍历失败：$e');
        return;
      }
      plans.addAll(Flattener.plan(all, rootDocId: r.rootDocId));
    }
    if (!mounted) return;
    if (plans.isEmpty) {
      moSnack(context, '没有需要扁平化的文件（都已经在根目录这一层）');
      return;
    }
    final List<WriteTarget> targets = <WriteTarget>[
      for (final FlattenPlan p in plans)
        WriteTarget(
          docId: p.source.docId,
          name: p.source.name,
          path: p.fromDir.isEmpty ? '(根目录)' : p.fromDir,
          kind: WriteKind.move,
          note: p.renamed ? '搬到根目录并改名为 ${p.targetName}' : '搬到根目录',
          lines: <WriteLine>[
            WriteLine(
              label: '位置',
              oldText: p.fromDir.isEmpty ? '(根目录)' : p.fromDir,
              newText: p.renamed ? '(根目录) / ${p.targetName}' : '(根目录)',
            ),
          ],
          file: p.source,
          data: p,
        ),
    ];
    final List<WriteTarget>? picked = await WriteConfirmSheet.show(
      context,
      title: '扁平化预览',
      subtitle: '勾中的曲目会搬到曲库目录这一层；搬空的子目录会被删掉',
      targets: targets,
      commitLabel: '开始移动',
      unit: '个',
      verb: '移动',
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    final Set<String> keep = <String>{
      for (final WriteTarget t in picked) t.docId,
    };
    final Map<String, List<FlattenPlan>> byRoot = <String, List<FlattenPlan>>{};
    for (final FlattenPlan p in plans) {
      if (!keep.contains(p.source.docId)) continue;
      // 按目标根分组：同一批里每个文件只属于它自己那棵树
      String rootId = _repo.roots.first.rootDocId;
      for (final TreeRef r in _repo.roots) {
        final String prefix = r.rootDocId.endsWith('/') ? r.rootDocId : '${r.rootDocId}/';
        if (p.source.docId.startsWith(prefix) || p.source.docId == r.rootDocId) {
          rootId = r.rootDocId;
          break;
        }
      }
      byRoot.putIfAbsent(rootId, () => <FlattenPlan>[]).add(p);
    }
    final RunningTask? task = TaskCenter.start('扁平化文件夹');
    final TaskControl? control = task?.control;
    int moved = 0;
    int removedDirs = 0;
    int keptDirs = 0;
    int failed = 0;
    try {
      for (final MapEntry<String, List<FlattenPlan>> e in byRoot.entries) {
        final VFile rootDir = VFile(docId: e.key, name: e.key, dir: true);
        final FlattenResult r = await Flattener.execute(
          st,
          root: rootDir,
          plans: e.value,
          onProgress: (int done, int total) =>
              control?.report(done, total, '移动中'),
        );
        moved += r.moved;
        removedDirs += r.removedDirs;
        keptDirs += r.failedDirs;
        failed += r.failed;
      }
      if (!mounted) return;
      await _repo.rescan();
      if (!mounted) return;
      moSnack(context, '已移动 $moved 个 · 删空目录 $removedDirs 个'
          '${keptDirs > 0 ? ' · $keptDirs 个里还有封面 / 歌词等文件，未删' : ''}'
          '${failed > 0 ? ' · 失败 $failed 个' : ''}');
    } finally {
      TaskCenter.finish();
    }
  }

  /// 清理空文件夹：整棵树找出「子树里没有任何文件」的目录，预览后删除。
  ///
  /// 和扁平化自带的那一步是同一套逻辑（`EmptyDirs`）：删除后逐个复查，
  /// 只按「确实不在了」计数 —— 安卓 SAF 上有过「返回成功但目录还在」，
  /// 老代码按返回值报数，界面就成了「提示已清理、实际没少」。
  Future<void> _emptyDirs() async {
    if (_busy) return;
    if (TaskCenter.isBusy()) {
      moSnack(context, '已有任务在跑，先等它结束');
      return;
    }
    final FileStore? st = _repo.store;
    final TreeRef? root = _repo.root;
    if (st == null || root == null) {
      moSnack(context, '还没有选择曲库目录');
      return;
    }
    final VFile rootDir = VFile(docId: root.rootDocId, name: '', dir: true);

    final RunningTask? scanTask = TaskCenter.start('扫描空文件夹');
    final TaskControl? scanControl = scanTask?.control;
    EmptyDirPlan plan;
    try {
      plan = await EmptyDirs.plan(
        st,
        rootDir,
        cancel: scanControl,
        onProgress: (int n) => scanControl?.report(n, 0, '已检查 $n 个目录'),
      );
    } finally {
      TaskCenter.finish();
    }
    if (!mounted) return;
    if (plan.cancelled) return;
    if (plan.count == 0) {
      moSnack(context, '没有空文件夹（${plan.scannedDirs} 个目录都有内容）');
      return;
    }

    const int maxShow = 300;
    final List<EmptyDir> shown =
        plan.empty.length > maxShow ? plan.empty.sublist(0, maxShow) : plan.empty;
    final bool? go = await showMoSheet<bool>(
      context,
      title: '空文件夹（${plan.count} 个）',
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 0, MoKit.pagePad, 6),
          child: Text(
            '这些目录里没有任何文件（含子目录），删除后不可恢复。'
            '${plan.protectedDirs.isEmpty ? '' : '「${TextUtil.unrecognizedDir}」已保留。'}',
            style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context)),
          ),
        ),
        for (final EmptyDir e in shown)
          Padding(
            padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 3, MoKit.pagePad, 3),
            child: Row(
              children: <Widget>[
                Icon(Icons.folder_outlined, size: 16, color: MoKit.faint(context)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(e.relPath,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: MoKit.fsBody, color: MoKit.text(context))),
                ),
              ],
            ),
          ),
        if (plan.empty.length > maxShow)
          Padding(
            padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 6, MoKit.pagePad, 4),
            child: Text('另有 ${plan.empty.length - maxShow} 个未列出，会一起删除',
                style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.faint(context))),
          ),
      ],
      footer: SizedBox(
        width: double.infinity,
        child: MoButton('删除这 ${plan.count} 个空文件夹',
            primary: false, onPressed: () => Navigator.of(context).pop(true)),
      ),
    );
    if (go != true || !mounted) return;

    final RunningTask? delTask = TaskCenter.start('删除空文件夹');
    final TaskControl? delControl = delTask?.control;
    EmptyDeleteResult result;
    try {
      result = await EmptyDirs.delete(
        st,
        plan.empty,
        cancel: delControl,
        onProgress: (int done, int total) =>
            delControl?.report(done, total, '删除中'),
      );
    } finally {
      TaskCenter.finish();
    }
    await _repo.rescan();
    if (!mounted) return;
    moSnack(context, result.summary());
  }

  Future<void> _junk() async {
    if (_busy) return;
    if (TaskCenter.isBusy()) {
      moSnack(context, '已有任务在跑，先等它结束');
      return;
    }
    final List<VFile> junk = _junkFiles;
    if (junk.isEmpty) return;
    // 统一预览：列出每个文件与判定原因，用户可取消勾选不想删的
    final List<WriteTarget> targets = junk
        .map(
          (VFile f) => WriteTarget(
            docId: f.docId,
            name: f.name,
            path: _repo.relPath(f),
            kind: WriteKind.delete,
            note: Junk.reasonOf(f),
            risky: true,
            lines: <WriteLine>[WriteLineX.delete(f.name)],
            file: f,
          ),
        )
        .toList();
    final List<WriteTarget>? picked = await WriteConfirmSheet.show(
      context,
      title: '删除垃圾文件',
      subtitle: '删除后无法恢复，取消勾选的会保留',
      warning: '确认前请核对：判定为垃圾的文件会直接从磁盘删除',
      targets: targets,
      commitLabel: '删除',
      unit: '个',
      verb: '删除',
      expandAll: true,
    );
    if (picked == null || picked.isEmpty) return;
    int ok = 0;
    for (final WriteTarget t in picked) {
      final VFile? f = t.file as VFile?;
      if (f == null) continue;
      if (await _repo.store!.delete(f)) ok++;
    }
    if (!mounted) return;
    await _repo.rescan();
    await _refreshJunk();
    if (!mounted) return;
    moSnack(context, '已删除 $ok 个');
  }
}

/// 极简取消令牌：只承载「该停了」这一个状态。
///
/// 项目里的 [CancelToken] 是纯接口（只有 isCancelled），这里给整理页的
/// 垃圾扫描补一个可置位的实现；`dispose()` 时置位，`Scanner.walkAll`
/// 每进一个目录都会查一次，从而在返回上级时尽快退出遍历。
class _FlagToken implements CancelToken {
  bool _cancelled = false;

  void cancel() => _cancelled = true;

  @override
  bool isCancelled() => _cancelled;

  @override
  bool isCancelledNow() => _cancelled;
}

/// 把 [Scanner.walkAll] 的三参数进度回调收窄成「已扫过多少个 + 当前文件名」。
///
/// 垃圾扫描不关心总数（遍历前不知道树有多大），只要一个能显示进度的计数。
class _JunkProgress implements Progress {
  _JunkProgress(this.onTick);

  final void Function(int done, String name) onTick;

  @override
  void onProgress(int done, int total, String message) => onTick(done, message);
}
