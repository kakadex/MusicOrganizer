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
  if (tracks.isEmpty) {
    moSnack(context, '系统媒体库里没找到可导入的音频');
    return;
  }
  await showMoSheet<void>(
    context,
    title: '系统媒体库（${tracks.length} 首）',
    children: <Widget>[
      const Padding(
        padding: EdgeInsets.fromLTRB(MoKit.pagePad, 0, MoKit.pagePad, 4),
        child: Text('勾选后复制进曲库的「导入/」目录；原文件不动。',
            style: TextStyle(fontSize: MoKit.fsCaption)),
      ),
      _PickList(tracks: tracks),
    ],
  );
}

/// 勾选 + 导入。
class _PickList extends StatefulWidget {
  const _PickList({required this.tracks});

  final List<MediaTrack> tracks;

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
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
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
        Padding(
          padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 4, MoKit.pagePad, 0),
          child: Text(
            _busy
                ? '正在导入 $_done / ${_picked.length}…'
                : (_failed.isEmpty ? '' : '有 $_failed 首没导入成功'),
            style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(MoKit.pagePad),
          child: Row(
            children: <Widget>[
              Expanded(
                child: MoButton('全选', primary: false, onPressed: _busy
                    ? null
                    : () => setState(() {
                          _picked
                            ..clear()
                            ..addAll(widget.tracks.map((MediaTrack t) => t.id));
                        })),
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
        ),
      ],
    );
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
