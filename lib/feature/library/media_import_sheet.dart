/// 「从系统媒体库导入」：列出设备媒体库里的音频，勾选后复制进曲库。
///
/// 只在用户点进来时才申请读取音频的权限；不选目录的话本应用仍然不需要任何权限。
library;

import 'package:flutter/material.dart';

import '../../app/repo.dart';
import '../../app/ui_kit.dart';
import '../../core/fs/file_store.dart';
import '../../core/fs/tree_ref.dart';
import '../../core/media/media_import.dart';

/// 打开导入面板。
Future<void> runMediaImport(BuildContext context) async {
  final Repo repo = Repo.instance;
  final FileStore? store = repo.store;
  final root = repo.root;
  if (store == null || root == null) {
    moSnack(context, '先选一个曲库目录');
    return;
  }
  if (!MediaImport.supported) {
    moSnack(context, '这个功能只在安卓上可用（系统媒体库）');
    return;
  }
  if (!await MediaImport.ensurePermission()) {
    if (!context.mounted) return;
    moSnack(context, '没有读取音频的权限，没法扫系统媒体库');
    return;
  }
  if (!context.mounted) return;
  showMoSheet<void>(
    context,
    title: '正在扫系统媒体库…',
    children: <Widget>[
      const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      ),
    ],
  );
  List<MediaTrack> tracks;
  try {
    tracks = await MediaImport.scan();
  } catch (e) {
    tracks = <MediaTrack>[];
  }
  if (!context.mounted) return;
  Navigator.of(context).pop();
  // 已在曲库目录里的（系统媒体库会把它们也扫进来）和已经导入过的都不再列，
  // 否则用户会以为「系统媒体库＝我授权过的那个文件夹」，点一下又复制一份。
  final Set<String> known = <String>{
    for (final f in repo.files) '${f.name}|${f.size}',
  };
  final List<String> rootIds = <String>[
    for (final t in repo.roots) t.rootDocId,
  ];
  int skippedInLibrary = 0;
  int skippedKnown = 0;
  final List<MediaTrack> importable = <MediaTrack>[];
  for (final MediaTrack t in tracks) {
    if (rootIds.any(t.insideRoot)) {
      skippedInLibrary++;
      continue;
    }
    if (known.contains('${t.name}|${t.size}')) {
      skippedKnown++;
      continue;
    }
    importable.add(t);
  }
  if (importable.isEmpty) {
    moSnack(
        context,
        '没有可导入的音频'
        '${skippedInLibrary > 0 ? '（$skippedInLibrary 首已在曲库目录里）' : ''}'
        '${skippedKnown > 0 ? '（$skippedKnown 首已经导入过）' : ''}');
    return;
  }
  tracks = importable;
  final String skipNote = <String>[
    if (skippedInLibrary > 0) '$skippedInLibrary 首已在曲库目录里',
    if (skippedKnown > 0) '$skippedKnown 首已导入过',
  ].join('，');
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: MoKit.bg(context),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (BuildContext ctx) =>
        _PickList(tracks: tracks, skipNote: skipNote),
  );
}

/// 勾选 + 导入。
class _PickList extends StatefulWidget {
  const _PickList({required this.tracks, required this.skipNote});

  final List<MediaTrack> tracks;
  final String skipNote;

  @override
  State<_PickList> createState() => _PickListState();
}

class _PickListState extends State<_PickList> {
  final Set<int> _picked = <int>{};
  bool _busy = false;
  int _done = 0;
  String _failed = '';

  @override
  Widget build(BuildContext context) {
    final Repo repo = Repo.instance;
    final FileStore? store = repo.store;
    final root = repo.root;
    return MoSheetScaffold(
      title: '系统媒体库（${widget.tracks.length} 首）',
      content: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 0, MoKit.pagePad, 4),
          child: Text(
              '勾选后复制进曲库的「导入/」目录；原文件不动。'
              '${widget.skipNote.isEmpty ? '' : '已略过：${widget.skipNote}。'}',
              style: TextStyle(fontSize: MoKit.fsCaption)),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: widget.tracks.length,
            itemBuilder: (BuildContext ctx, int i) {
              final MediaTrack t = widget.tracks[i];
              final bool on = _picked.contains(t.id);
              return CheckboxListTile(
                value: on,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(t.display(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: MoKit.fsBody, color: MoKit.text(ctx))),
                subtitle: Text(t.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: MoKit.fsCaption, color: MoKit.sub(ctx))),
                onChanged: _busy
                    ? null
                    : (bool? v) => setState(() {
                          if (v == true) {
                            _picked.add(t.id);
                          } else {
                            _picked.remove(t.id);
                          }
                        }),
              );
            },
          ),
        ),
      ],
      // 操作区固定：曲目再多也不会把「导入」顶出屏幕
      footer: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (_busy || _failed.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _busy
                      ? '正在导入 $_done / ${_picked.length}…'
                      : '有 $_failed 首没导入成功',
                  style:
                      TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context)),
                ),
              ),
            ),
          Row(
            children: <Widget>[
              Expanded(
                child: MoButton('全选', primary: false, onPressed: _busy ? null : _selectAll),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: MoButton(
                    _busy ? '导入中…' : '导入 ${_picked.length} 首',
                    busy: _busy,
                    onPressed: _busy || _picked.isEmpty || store == null || root == null
                        ? null
                        : () => _import(store, root)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _selectAll() {
    setState(() {
      _picked
        ..clear()
        ..addAll(widget.tracks.map((MediaTrack t) => t.id));
    });
  }

  Future<void> _import(FileStore store, TreeRef root) async {
    setState(() {
      _busy = true;
      _done = 0;
      _failed = '';
    });
    int failed = 0;
    for (final MediaTrack t in widget.tracks) {
      if (!_picked.contains(t.id)) continue;
      final String err = await MediaImport.importOne(store, root, t);
      if (err.isEmpty) {
        _done++;
      } else {
        failed++;
      }
      if (mounted) {
        setState(() => _failed = failed > 0 ? '$failed' : '');
      }
    }
    if (!mounted) return;
    setState(() => _busy = false);
    await Repo.instance.rescan();
    if (!mounted) return;
    moSnack(context, '导入 $_done 首${failed > 0 ? '，失败 $failed 首' : ''}');
  }
}
