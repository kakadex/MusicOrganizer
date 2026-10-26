import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_focus.dart';
import '../../app/cover_cache.dart';
import '../../app/repo.dart';
import '../../app/ui_kit.dart';
import '../../core/match/match_queue.dart';
import '../../core/match/tag_plan.dart';
import '../../core/model/tags.dart';
import '../../core/model/task_control.dart';
import '../../core/model/partial_sink.dart';
import '../../core/model/vfile.dart';
import '../../core/organize/organizer.dart';
import '../../core/cover/folder_cover.dart';
import '../../core/cover/sidecar_cover.dart';
import '../../core/fs/file_store.dart';
import '../../core/fs/tree_ref.dart';
import '../../core/scan/scanner.dart';
import '../../core/scan/search_index.dart';
import '../../core/scan/search_query.dart';
import '../../core/task/task_center.dart';
import '../covers/covers_page.dart';
import '../editor/editor_page.dart';
import '../lyrics_batch/lyrics_batch_page.dart';
import '../../core/tx/write_preview.dart';
import '../common/write_confirm_sheet.dart';
import '../organize/rename_flow.dart';
import '../lyrics_batch/lyrics_tool_sheet.dart';
import '../tag_batch/batch_edit.dart';
import 'preview_sheet.dart';

/// 曲库页：搜索 + 筛选 + 排序 + 多选 + 批量匹配。
///
/// 列表从 [Repo.index] 取（内存索引，字段预先归一），滚到哪读到哪；
/// 封面按需从文件头取，读不到就显示音符占位，绝不阻塞滚动。
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  static const List<String> _filters = <String>['全部', '无标签', '无封面', '无歌词'];
  static const List<String> _sorts = <String>[
    '文件名', '标题', '歌手', '专辑', '大小', '修改时间', '标签完整度',
  ];

  final TextEditingController _search = TextEditingController();
  List<Entry> _shown = <Entry>[];
  int _filter = 0;
  int _sort = 0;
  bool _desc = false;
  bool _selectMode = false;

  /// 长按后是否处于「拖动连选」状态。
  bool _dragSelecting = false;

  /// 每行一个 key，拖选时用来判断手指落在哪一行。
  final Map<String, GlobalKey> _rowKeys = <String, GlobalKey>{};
  final Set<String> _selected = <String>{};
  bool _busy = false;
  String _status = '';
  String _query = '';
  /// 当前检索词（命中高亮用）。
  List<String> _terms = <String>[];

  @override
  void initState() {
    super.initState();
    _filter = Repo.instance.settings.get<int>('filter', fallback: 0) ?? 0;
    _sort = Repo.instance.settings.get<int>('sort_key', fallback: 0) ?? 0;
    _desc = Repo.instance.settings.get<bool>('sort_desc', fallback: false) ?? false;
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoScan());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _autoScan() async {
    final repo = Repo.instance;
    if (!repo.hasRoot) {
      setState(() {});
      return;
    }
    if (repo.files.isNotEmpty) {
      _applyFilter();
      return;
    }
    await _scan();
  }

  Future<void> _scan() async {
    final repo = Repo.instance;
    setState(() {
      _busy = true;
      _status = '正在扫描…';
    });
    final ScanOutcome out = await repo.rescan();
    if (!mounted) return;
    if (!out.ok) {
      setState(() {
        _busy = false;
        _status = out.error;
      });
      return;
    }
    setState(() => _status = '读取标签…');
    await repo.loadMeta(onProgress: (int done, int total) {
      if (!mounted) return;
      setState(() => _status = '读取标签 $done/$total');
    });
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = '';
    });
    _applyFilter();
    moSnack(context, out.summary());
  }

  Future<void> _pickRoot() async {
    final repo = Repo.instance;
    final bool ok = await repo.pickRoot();
    if (!mounted) return;
    if (!ok) return;
    repo.files = <VFile>[];
    await _scan();
  }

  void _applyFilter() {
    final repo = Repo.instance;
    final SearchQuery q = SearchQuery.parse(_query);
    _terms = q.raw;
    final List<Entry> all = repo.index.search(q);
    final List<Entry> out = <Entry>[];
    for (final Entry e in all) {
      switch (_filter) {
        case 1:
          if (e.tagComplete()) continue;
        case 2:
          if (e.hasCover) continue;
        case 3:
          if (e.hasLyrics) continue;
        default:
          break;
      }
      out.add(e);
    }
    out.sort((Entry a, Entry b) {
      int r;
      switch (_sort) {
        case 1:
          r = a.displayTitle().toLowerCase().compareTo(b.displayTitle().toLowerCase());
        case 2:
          r = a.artist.toLowerCase().compareTo(b.artist.toLowerCase());
        case 3:
          r = a.album.toLowerCase().compareTo(b.album.toLowerCase());
        case 4:
          r = a.size.compareTo(b.size);
        case 5:
          r = a.modified.compareTo(b.modified);
        case 6:
          // 标签不完整的排前面（先补齐再收工）
          r = (a.tagComplete() ? 1 : 0) - (b.tagComplete() ? 1 : 0);
        default:
          r = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      }
      if (_desc) r = -r;
      // 同分时按 docId 兜底，避免每次刷新顺序乱跳
      return r != 0 ? r : a.docId.compareTo(b.docId);
    });
    setState(() => _shown = out);
  }

  void _toggleSelect(Entry e) {
    setState(() {
      if (!_selected.add(e.docId)) _selected.remove(e.docId);
      if (_selected.isEmpty) _selectMode = false;
    });
  }

  /// 删除选中的文件（不可撤销，先确认再删）。
  Future<void> _deleteSelected(List<VFile> files) async {
    if (files.isEmpty) return;
    // 统一预览：逐个列出，用户可取消勾选不想删的
    final List<WriteTarget> targets = files
        .map(
          (VFile f) => WriteTarget(
            docId: f.docId,
            name: f.name,
            path: f.pathAfterRoot(),
            kind: WriteKind.delete,
            risky: true,
            lines: <WriteLine>[WriteLineX.delete(f.name)],
            file: f,
          ),
        )
        .toList();
    final List<WriteTarget>? picked = await WriteConfirmSheet.show(
      context,
      title: '删除文件',
      subtitle: '删除不可撤销，回收站也没有',
      warning: '确认前请核对：勾中的文件会直接从磁盘删除',
      targets: targets,
      commitLabel: '确认删除',
      unit: '个',
      verb: '删除',
      expandAll: true,
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    final FileStore? store = Repo.instance.store;
    if (store == null) {
      moSnack(context, '还没有准备好文件访问');
      return;
    }
    setState(() => _busy = true);
    int ok = 0;
    int fail = 0;
    for (final WriteTarget t in picked) {
      final VFile? f = t.file as VFile?;
      if (f == null) continue;
      if (await store.delete(f)) {
        ok++;
      } else {
        fail++;
      }
    }
    await Repo.instance.rescan();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _selected.clear();
      _selectMode = false;
    });
    moSnack(context, '已删除 $ok 个${fail > 0 ? '，失败 $fail 个' : ''}');
  }

  /// 手动把一首歌搬到「歌手」目录（认不出歌手就不动）。
  Future<void> _classifyToArtist(VFile f) async {
    final repo = Repo.instance;
    final store = repo.store;
    final TreeRef? ref = repo.rootOf(f);
    if (store == null || ref == null) return;
    Tags tags = f.cachedTags ?? Tags();
    try {
      tags = await Scanner.readTags(store, f);
    } catch (_) {
      // 读不到就用缓存
    }
    final VFile probe = VFile(docId: f.docId, name: f.name, dir: false)
      ..cachedTags = tags;
    final List<MovePlan> plans = Organizer.plan(
      <VFile>[probe],
      rootDocId: ref.rootDocId,
      byAlbum: false,
      onlyUnorganized: false,
    );
    if (!mounted) return;
    if (plans.isEmpty) {
      moSnack(context, '认不出歌手（标签里没有艺术家，文件名也解析不出）');
      return;
    }
    final MovePlan p = plans.first;
    final List<WriteTarget>? picked = await WriteConfirmSheet.show(
      context,
      title: '归类到歌手目录',
      subtitle: '勾中后会把文件搬到下面这个位置',
      targets: <WriteTarget>[
        WriteTarget(
          docId: f.docId,
          name: f.name,
          path: repo.relPath(f),
          kind: WriteKind.move,
          note: p.conflict ? '同目录已有同名文件，会跳过' : p.reason,
          lines: <WriteLine>[
            WriteLine(
              label: '位置',
              oldText: repo.relPath(f),
              newText: '${p.targetPath}/${f.name}',
            ),
          ],
          file: f,
          data: p,
        ),
      ],
      commitLabel: '归类',
      unit: '首',
      verb: '移动',
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    if (p.conflict) {
      moSnack(context, '目标目录已有同名文件，没动');
      return;
    }
    TaskCenter.start('归类到歌手目录');
    final OrganizeResult r = await Organizer.execute(store, <MovePlan>[p]);
    TaskCenter.finish();
    if (!mounted) return;
    await repo.rescan();
    if (!mounted) return;
    moSnack(context, r.ok > 0
        ? '已归类到 ${p.targetPath}'
        : '没搬动：${r.errors.isNotEmpty ? r.errors.first : r.summary()}');
  }

  Future<void> _matchSelected({bool ignoreMemory = false}) async {
    final repo = Repo.instance;
    final runner = repo.runner;
    if (runner == null) return;
    final List<VFile> files = <VFile>[];
    for (final Entry e in _shown) {
      final VFile? f = e.file;
      if (f != null && _selected.contains(e.docId)) files.add(f);
    }
    if (files.isEmpty) return;
    setState(() => _busy = true);
    // 边跑边存已完成的结果：中途暂停 / 取消时也能把「已获取的部分」拿出来看
    final PartialSink<FilePlan> partial = PartialSink<FilePlan>();
    final RunningTask? task = TaskCenter.start('匹配标签', partial: partial as PartialSink<Object>);
    final TaskControl? control = task?.control;
    final Map<String, int> indexOf = <String, int>{
      for (int i = 0; i < files.length; i++) files[i].docId: i,
    };
    if (ignoreMemory) {
      // 用户明确要重来：清掉这些文件的续跑条目，否则又会拿到上次的结论
      for (final VFile f in files) {
        runner.queue?.mark(f.docId, MatchQueue.skipped);
      }
      runner.queue?.clearFinished();
    }
    final List<FilePlan> plans = await runner.match(
      files,
      control: control,
      modes: repo.tagModes(),
      ignoreMemory: ignoreMemory,
      onPlan: (int done, int total, FilePlan plan) {
        partial.addAt(indexOf[plan.file.docId] ?? done, plan);
        control?.report(done, total, plan.file.name);
      },
    );
    final bool stopped = control?.isCancelled() ?? false;
    TaskCenter.finish();
    if (!mounted) return;
    setState(() => _busy = false);
    // 中途停下来的：把已经拿到的部分交出来给用户，别让跑到一半的活儿白费
    final List<FilePlan> usable =
        plans.isNotEmpty ? plans : partial.snapshot().where((FilePlan p) => p.hasChange).toList();
    if (plans.isEmpty && usable.isNotEmpty) {
      final bool? go = await showMoSheet<bool>(
        context,
        title: stopped ? '已停止，先看已获取的部分' : '已暂停，先看已获取的部分',
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 4, MoKit.pagePad, 8),
            child: Text('还剩 ${files.length - usable.length} 首没跑完；'
                '现在可以把这 ${usable.length} 首的结果先写进去。',
                style: TextStyle(fontSize: MoKit.fsBody, color: MoKit.sub(context))),
          ),
          Padding(
            padding: const EdgeInsets.all(MoKit.pagePad),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: MoButton('不要了', primary: false,
                      onPressed: () => Navigator.of(context).pop(false)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: MoButton('查看这 ${usable.length} 首',
                      onPressed: () => Navigator.of(context).pop(true)),
                ),
              ],
            ),
          ),
        ],
      );
      if (go != true || !mounted) return;
      final bool? wrote = await PreviewSheet.show(context, usable);
      if (wrote == true && mounted) {
        setState(() => _selected.clear());
        _applyFilter();
      }
      return;
    }
    if (plans.isEmpty) {
      if (runner.errors.isNotEmpty) {
        final String why = runner.errors.values.first;
        moSnack(context,
            '联网匹配失败：$why。请检查网络连接或代理设置（设置 → 网络与并发）');
      } else {
        moSnack(context, '没有匹配结果（可能都已经是完整标签）');
      }
      return;
    }
    final bool? wrote = await PreviewSheet.show(context, plans);
    if (wrote == true && mounted) {
      setState(() => _selected.clear());
      _applyFilter();
    }
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        // Ctrl+F 聚焦搜索；Ctrl+A 全选（先进多选态）；Esc 退多选 / 清空搜索
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): AppFocus.focusSearch,
        const SingleActivator(LogicalKeyboardKey.keyA, control: true): _selectAll,
        const SingleActivator(LogicalKeyboardKey.escape): _escape,
      },
      // 整页先接住焦点，快捷键才能在没点任何控件时生效（点搜索框后仍向上冒泡）
      child: Focus(autofocus: true, child: _build(context)),
    );
  }

  /// Ctrl+A：没进多选就先进入，然后把当前筛选结果全选。
  void _selectAll() {
    if (_shown.isEmpty) return;
    setState(() {
      _selectMode = true;
      _selected
        ..clear()
        ..addAll(_shown.map((Entry e) => e.docId));
    });
  }

  /// Esc：优先退多选，其次清空搜索。
  void _escape() {
    if (_selectMode) {
      setState(() {
        _selectMode = false;
        _selected.clear();
      });
      return;
    }
    if (_query.isNotEmpty) {
      _search.clear();
      _query = '';
      _applyFilter();
      AppFocus.unfocusAll();
    }
  }

  Widget _build(BuildContext context) {
    final Repo repo = Repo.instance;
    return Column(
      children: <Widget>[
        PageHeader(
          title: '音乐库',
          subtitle: repo.hasRoot
              ? '${_shown.length} 首${_status.isEmpty ? '' : ' · $_status'}'
              : '还没有选择曲库目录',
          actions: <Widget>[
            _icon(Icons.sort, '排序', _showSort),
            _icon(Icons.refresh, '重新扫描', _busy ? null : _scan),
          ],
        ),
        if (repo.hasRoot) _searchBar(),
        if (repo.hasRoot) _chipRow(),
        Expanded(child: _body(repo)),
        if (_selectMode) _selectionBar(),
      ],
    );
  }

  Widget _icon(IconData icon, String tip, VoidCallback? onTap) {
    return IconButton(
      tooltip: tip,
      onPressed: onTap,
      icon: Icon(icon, size: 20, color: onTap == null ? MoKit.faint(context) : MoKit.text(context)),
    );
  }

  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 0, MoKit.pagePad, 8),
      child: Container(
        height: 40,
        decoration: BoxDecoration(
            color: MoKit.card(context), borderRadius: BorderRadius.circular(999)),
        child: Row(
          children: <Widget>[
            const SizedBox(width: 12),
            Icon(Icons.search, size: 18, color: MoKit.faint(context)),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _search,
                focusNode: AppFocus.search,
                style: TextStyle(fontSize: MoKit.fsBody, color: MoKit.text(context)),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: '搜索歌名 / 歌手 / 专辑 / 路径',
                  hintStyle: TextStyle(fontSize: MoKit.fsBody, color: MoKit.faint(context)),
                ),
                onChanged: (String v) {
                  _query = v;
                  _applyFilter();
                },
              ),
            ),
            if (_query.isNotEmpty)
              IconButton(
                onPressed: () {
                  _search.clear();
                  _query = '';
                  _applyFilter();
                },
                icon: Icon(Icons.close, size: 16, color: MoKit.faint(context)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _chipRow() {
    return SizedBox(
      height: 34,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: MoKit.pagePad),
        itemCount: _filters.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (BuildContext c, int i) => MoChip(
          label: _filters[i],
          selected: _filter == i,
          onTap: () {
            setState(() => _filter = _filter == i ? 0 : i);
            Repo.instance.setSetting('filter', _filter);
            _applyFilter();
          },
        ),
      ),
    );
  }

  Widget _body(Repo repo) {
    if (!repo.hasRoot) {
      return EmptyState(
        icon: Icons.folder_open,
        text: '还没有选择曲库目录',
        hint: Repo.isDesktop
            ? '选一个装着音乐的文件夹，所有读写都只在这个目录内进行'
            : '用系统文件选择器授权一个文件夹，应用只在你授权的范围内读写',
        action: MoButton('选择目录', icon: Icons.add, onPressed: _pickRoot),
      );
    }
    if (_shown.isEmpty) {
      final bool failed = _status.contains('失败') || _status.contains('E_');
      return EmptyState(
        icon: failed ? Icons.error_outline : Icons.music_off,
        text: _busy ? '正在扫描…' : (failed ? _status : '这个筛选下没有曲目'),
        hint: _busy
            ? null
            : (failed ? '目录授权可能已失效，重新选一次目录即可' : '换个筛选条件，或点右上角重新扫描'),
        action: failed
            ? MoButton('重新选择目录', icon: Icons.folder_open, onPressed: _pickRoot)
            : null,
      );
    }
    return RefreshIndicator(
      onRefresh: _scan,
      child: Listener(
        // 长按进入多选后，手指继续滑动即可连续勾选（Listener 不参与手势竞争，
        // 所以不会影响正常滚动）。
        onPointerMove: _onDragSelectMove,
        onPointerUp: (_) => _dragSelecting = false,
        onPointerCancel: (_) => _dragSelecting = false,
        child: ListView.builder(
          padding: const EdgeInsets.only(bottom: 12),
          // 快速滑动优化：离屏行不再保活，避免一次性为大量行保留状态、触发过多封面 I/O。
          addAutomaticKeepAlives: false,
          itemCount: _shown.length,
          itemBuilder: (BuildContext c, int i) => _row(_shown[i]),
        ),
      ),
    );
  }

  Widget _row(Entry e) {
    final bool selected = _selected.contains(e.docId);
    return _CoverRow(
      key: _rowKeys.putIfAbsent(e.docId, () => GlobalKey()),
      entry: e,
      terms: _terms,
      selected: selected,
      selectMode: _selectMode,
      onTap: () {
        if (_selectMode) {
          _toggleSelect(e);
        } else {
          _showDetail(e);
        }
      },
      onLongPress: () {
        setState(() {
          _selectMode = true;
          _selected.add(e.docId);
          _dragSelecting = true;
        });
      },
    );
  }

  /// 手指滑到哪一行就把哪一行勾上（长按进入多选后生效）。
  void _onDragSelectMove(PointerMoveEvent event) {
    if (!_dragSelecting || !_selectMode) return;
    for (final Entry e in _shown) {
      final GlobalKey? key = _rowKeys[e.docId];
      final RenderObject? box = key?.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached) continue;
      final Offset local = box.globalToLocal(event.position);
      if (local.dx < 0 || local.dy < 0 || local.dx > box.size.width || local.dy > box.size.height) {
        continue;
      }
      if (!_selected.contains(e.docId)) {
        setState(() => _selected.add(e.docId));
      }
      break;
    }
  }

  Widget _selectionBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 8, MoKit.pagePad, 8),
      color: MoKit.card(context),
      child: Row(
        children: <Widget>[
          Text('已选 ${_selected.length}',
              style: TextStyle(
                  fontSize: MoKit.fsBody,
                  fontWeight: FontWeight.w600,
                  color: MoKit.primary(context))),
          const SizedBox(width: 12),
          TextButton(
            onPressed: () => setState(() {
              if (_selected.length == _shown.length) {
                _selected.clear();
              } else {
                _selected
                  ..clear()
                  ..addAll(_shown.map((Entry e) => e.docId));
              }
            }),
            child: Text(_selected.length == _shown.length ? '取消全选' : '全选'),
          ),
          const Spacer(),
          TextButton(
            onPressed: () => setState(() {
              _selectMode = false;
              _selected.clear();
            }),
            child: const Text('关闭'),
          ),
          const SizedBox(width: 6),
          TextButton(
            onPressed: _busy ? null : _moreForSelection,
            child: const Text('更多'),
          ),
          MoButton('匹配标签', busy: _busy, onPressed: _matchSelected),
        ],
      ),
    );
  }

  /// 选中后的其它动作（补封面 / 补歌词）。
  void _moreForSelection() {
    final List<VFile> files = <VFile>[];
    for (final Entry e in _shown) {
      final VFile? f = e.file;
      if (f != null && _selected.contains(e.docId)) files.add(f);
    }
    if (files.isEmpty) return;
    showMoSheet<void>(
      context,
      title: '对选中的 ${files.length} 首',
      children: <Widget>[
        MoTile(
          title: '批量补封面',
          subtitle: '多源取图写入内嵌封面',
          icon: Icons.image_outlined,
          onTap: () {
            Navigator.of(context).pop();
            _push(CoversPage(files: files));
          },
        ),
        MoTile(
          title: '批量补歌词',
          subtitle: '五源并发，按打分取最优',
          icon: Icons.lyrics_outlined,
          onTap: () {
            Navigator.of(context).pop();
            _push(LyricsBatchPage(files: files));
          },
        ),
        MoTile(
          title: '忽略上次结果，重新匹配',
          subtitle: '清掉这批的续跑队列与「无命中」记忆，重头问一遍',
          icon: Icons.refresh,
          onTap: () {
            Navigator.of(context).pop();
            _matchSelected(ignoreMemory: true);
          },
        ),
        MoTile(
          title: '歌词工具',
          subtitle: '清洗歌词、整体偏移时间轴、查看原词',
          icon: Icons.lyrics_outlined,
          onTap: () {
            Navigator.of(context).pop();
            runLyricsTool(context, files);
          },
        ),
        MoTile(
          title: '批量改标签',
          subtitle: '统一设专辑 / 流派 / 年份等，可重排音轨号',
          icon: Icons.edit_note_outlined,
          onTap: () {
            Navigator.of(context).pop();
            runBatchEdit(context, files);
          },
        ),
        MoTile(
          title: '按标签改名',
          subtitle: '用标签里的歌名 / 艺人拼文件名，先出计划再动手',
          icon: Icons.drive_file_rename_outline,
          onTap: () {
            Navigator.of(context).pop();
            runRenameFlow(context, files);
          },
        ),
        MoTile(
          title: '删除选中的文件',
          subtitle: '不可撤销，删前会再确认一次',
          icon: Icons.delete_outline,
          danger: true,
          onTap: () {
            Navigator.of(context).pop();
            _deleteSelected(files);
          },
        ),
        MoTile(
          title: '全选当前筛选结果',
          icon: Icons.select_all,
          onTap: () {
            Navigator.of(context).pop();
            setState(() => _selected
              ..clear()
              ..addAll(_shown.map((Entry e) => e.docId)));
          },
        ),
      ],
    );
  }

  void _push(Widget page) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (BuildContext _) => page),
    );
  }

  void _showSort() {
    showMoSheet<void>(
      context,
      title: '排序',
      children: <Widget>[
        for (int i = 0; i < _sorts.length; i++)
          MoTile(
            title: _sorts[i],
            trailing: _sort == i
                ? Icon(Icons.check, size: 18, color: MoKit.primary(context))
                : null,
            onTap: () {
              Navigator.of(context).pop();
              setState(() {
                if (_sort == i) {
                  _desc = !_desc;
                } else {
                  _sort = i;
                  _desc = false;
                }
              });
              Repo.instance.setSetting('sort_key', _sort);
              Repo.instance.setSetting('sort_desc', _desc);
              _applyFilter();
            },
          ),
      ],
    );
  }

  void _showDetail(Entry e) {
    showMoSheet<void>(
      context,
      title: e.displayTitle(),
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: MoKit.pagePad),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _kv('歌手', e.artist),
              _kv('专辑', e.album),
              _kv('年份', e.year),
              _kv('流派', e.genre),
              _kv('文件', e.name),
              _kv('路径', e.relPath),
              _kv('大小', '${(e.size / 1024 / 1024).toStringAsFixed(2)} MB'),
              _kv('封面', e.hasCover ? '有' : '无'),
              _kv('歌词', e.hasLyrics ? '有' : '无'),
              const SizedBox(height: 6),
              MoButton('编辑标签', icon: Icons.edit_outlined, onPressed: () async {
                final VFile? f = e.file;
                if (f == null) return;
                Navigator.of(context).pop();
                final bool? changed = await EditorPage.show(context, f);
                if (changed == true && mounted) _applyFilter();
              }),
              const SizedBox(height: 8),
              MoButton('归类到歌手目录', primary: false,
                  icon: Icons.drive_file_move_outline,
                  onPressed: () async {
                final VFile? f = e.file;
                if (f == null) return;
                Navigator.of(context).pop();
                await _classifyToArtist(f);
              }),
            ],
          ),
        ),
      ],
    );
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 56,
            child: Text(k, style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
          ),
          Expanded(
            child: Text(v.isEmpty ? '（空）' : v,
                style: TextStyle(fontSize: MoKit.fsBody, color: MoKit.text(context))),
          ),
        ],
      ),
    );
  }
}

/// 一行曲目：封面异步加载 + 标题/副标题 + 时长。
class _CoverRow extends StatefulWidget {
  const _CoverRow({
    super.key,
    required this.entry,
    this.terms = const <String>[],
    required this.selected,
    required this.selectMode,
    required this.onTap,
    required this.onLongPress,
  });

  final Entry entry;
  /// 检索命中词（高亮用）。
  final List<String> terms;
  final bool selected;
  final bool selectMode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  State<_CoverRow> createState() => _CoverRowState();
}

class _CoverRowState extends State<_CoverRow> {
  Uint8List? _cover;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final file = widget.entry.file;
    if (file == null) return;
    final Uint8List? hit = CoverCache.instance.peek(file);
    if (hit != null) {
      setState(() => _cover = hit);
      return;
    }
    Uint8List? art;
    if (!CoverCache.instance.knownMiss(file)) {
      art = await CoverCache.instance.load(file);
    }
    // 自己没有封面 → 找旁边的同名图片 → 再找专辑目录里的 cover.jpg
    final FileStore? store = Repo.instance.store;
    if (art == null && store != null) {
      try {
        art = await SidecarCover.find(store, file);
      } catch (_) {
        art = null;
      }
    }
    if (art == null && store != null) {
      final String? parentId = file.parentId;
      if (parentId != null && parentId.isNotEmpty) {
        try {
          art = await FolderCover.find(
              store, VFile(docId: parentId, name: parentId, dir: true));
        } catch (_) {
          art = null;
        }
      }
    }
    if (mounted && art != null) setState(() => _cover = art);
  }

  @override
  Widget build(BuildContext context) {
    final Entry e = widget.entry;
    final String sub = e.displaySub().isEmpty ? '未知歌手' : e.displaySub();
    return SongRow(
      title: e.displayTitle(),
      subtitle: sub,
      terms: widget.terms,
      cover: _cover,
      selected: widget.selected,
      selectionMode: widget.selectMode,
      highlight: !e.metaLoaded,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      trailing: e.metaLoaded
          ? Text(e.hasLyrics ? '词' : '',
              style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context)))
          : null,
    );
  }
}
