import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app/cover_cache.dart';
import '../../app/repo.dart';
import '../../app/ui_kit.dart';
import '../../core/match/tag_plan.dart';
import '../../core/model/task_control.dart';
import '../../core/model/vfile.dart';
import '../../core/scan/search_index.dart';
import '../../core/scan/search_query.dart';
import '../../core/task/task_center.dart';
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
  static const List<String> _sorts = <String>['文件名', '标题', '歌手', '专辑', '大小'];

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
        default:
          r = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      }
      return _desc ? -r : r;
    });
    setState(() => _shown = out);
  }

  void _toggleSelect(Entry e) {
    setState(() {
      if (!_selected.add(e.docId)) _selected.remove(e.docId);
      if (_selected.isEmpty) _selectMode = false;
    });
  }

  Future<void> _matchSelected() async {
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
    final List<FilePlan> plans = await runner.match(
      files,
      control: control,
      onPlan: (int done, int total, FilePlan plan) {
        control?.report(done, total, plan.file.name);
      },
    );
    TaskCenter.finish();
    if (!mounted) return;
    setState(() => _busy = false);
    if (plans.isEmpty) {
      moSnack(context, '没有匹配结果（可能都已经是完整标签）');
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
      return EmptyState(
        icon: Icons.music_off,
        text: _busy ? '正在扫描…' : '这个筛选下没有曲目',
        hint: _busy ? null : '换个筛选条件，或点右上角重新扫描',
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
          MoButton('匹配标签', busy: _busy, onPressed: _matchSelected),
        ],
      ),
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
