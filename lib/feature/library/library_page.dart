import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_focus.dart';
import '../../app/cover_cache.dart';
import '../../app/repo.dart';
import '../../app/ui_kit.dart';
import '../../core/match/match_queue.dart';
import '../../core/match/tag_plan.dart';
import '../../core/model/task_control.dart';
import '../../core/model/vfile.dart';
import '../../core/scan/search_index.dart';
import '../../core/scan/search_query.dart';
import '../../core/task/task_center.dart';
import '../covers/covers_page.dart';
import '../editor/editor_page.dart';
import '../lyrics_batch/lyrics_batch_page.dart';
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
  final Set<String> _selected = <String>{};
  bool _busy = false;
  String _status = '';
  String _query = '';

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
    final RunningTask? task = TaskCenter.start('匹配标签');
    final TaskControl? control = task?.control;
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
      ignoreMemory: ignoreMemory,
      onPlan: (int done, int total, FilePlan plan) {
        control?.report(done, total, plan.file.name);
      },
    );
    TaskCenter.finish();
    if (!mounted) return;
    setState(() => _busy = false);
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
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 12),
      itemCount: _shown.length,
      itemBuilder: (BuildContext c, int i) => _row(_shown[i]),
    );
  }

  Widget _row(Entry e) {
    final bool selected = _selected.contains(e.docId);
    return _CoverRow(
      key: ValueKey<String>(e.docId),
      entry: e,
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
        });
      },
    );
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
    required this.selected,
    required this.selectMode,
    required this.onTap,
    required this.onLongPress,
  });

  final Entry entry;
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
    if (CoverCache.instance.knownMiss(file)) return;
    final Uint8List? art = await CoverCache.instance.load(file);
    if (mounted && art != null) setState(() => _cover = art);
  }

  @override
  Widget build(BuildContext context) {
    final Entry e = widget.entry;
    final String sub = e.displaySub().isEmpty ? '未知歌手' : e.displaySub();
    return SongRow(
      title: e.displayTitle(),
      subtitle: sub,
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
