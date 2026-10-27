/// 曲库目录管理：可以同时登记多个目录，扫描时一起进曲库。
///
/// 安卓走 SAF 授权（移除目录 = 连系统授权一起放掉），桌面只是记住路径。
/// 列表第一项就是「当前」目录：切换目录不用重新授权，直接排到最前。
library;

import 'package:flutter/material.dart';

import '../../app/repo.dart';
import '../../app/ui_kit.dart';
import '../../core/fs/tree_ref.dart';

/// 曲库目录管理页。
class FolderPage extends StatefulWidget {
  const FolderPage({super.key});

  /// 打开目录管理；返回 true 表示目录变了（调用方需要重扫）。
  static Future<bool?> show(BuildContext context) {
    return Navigator.of(context).push<bool>(MaterialPageRoute<bool>(
      builder: (BuildContext _) => const FolderPage(),
    ));
  }

  @override
  State<FolderPage> createState() => _FolderPageState();
}

class _FolderPageState extends State<FolderPage> {
  bool _busy = false;

  Repo get _repo => Repo.instance;

  /// 目录显示名：SAF 的 rootDocId 形如 `primary:Music`，去掉盘符前缀更好认。
  static String _title(TreeRef t) {
    final String id = t.rootDocId;
    final int colon = id.indexOf(':');
    final String rest = colon >= 0 ? id.substring(colon + 1) : id;
    return rest.isEmpty ? id : rest;
  }

  static String _subtitle(TreeRef t) {
    final int colon = t.rootDocId.indexOf(':');
    return colon > 0 ? t.rootDocId.substring(0, colon) : '';
  }

  Future<void> _add() async {
    setState(() => _busy = true);
    final bool ok = await _repo.addRoot();
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) {
      moSnack(context,
          _repo.pickError ?? '没有新增目录（可能已经登记过，或取消了选择）');
      return;
    }
    await _rescan();
  }

  Future<void> _remove(TreeRef t) async {
    final bool? go = await showMoSheet<bool>(
      context,
      title: '移除这个目录？',
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 0, MoKit.pagePad, 8),
          child: Text('「${_title(t)}」会从曲库移除${Repo.isDesktop ? '' : '，并放掉系统授权'}。'
              '文件本身不会删除。',
              style: TextStyle(fontSize: MoKit.fsBody, color: MoKit.text(context))),
        ),
        Padding(
          padding: const EdgeInsets.all(MoKit.pagePad),
          child: MoButton('移除', primary: false,
              onPressed: () => Navigator.of(context).pop(true)),
        ),
      ],
    );
    if (go != true) return;
    setState(() => _busy = true);
    await _repo.removeRoot(t);
    if (!mounted) return;
    setState(() => _busy = false);
    await _rescan();
  }

  Future<void> _switch(TreeRef t) async {
    await _repo.switchRoot(t);
    if (!mounted) return;
    await _rescan();
  }

  Future<void> _rescan() async {
    await _repo.rescan(incremental: false);
    await _repo.loadMeta();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final List<TreeRef> roots = _repo.roots;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: <Widget>[
            PageHeader(
              title: '曲库目录',
              subtitle: roots.isEmpty
                  ? '还没有登记目录'
                  : '${roots.length} 个目录 · 第一个是当前目录',
              actions: <Widget>[
                IconButton(
                  tooltip: '返回',
                  onPressed: () => Navigator.of(context).pop(true),
                  icon: Icon(Icons.arrow_back, size: 20, color: MoKit.text(context)),
                ),
              ],
            ),
            Expanded(
              child: roots.isEmpty
                  ? const EmptyState(
                      icon: Icons.folder_off_outlined,
                      text: '还没有曲库目录',
                      hint: '点下面「添加目录」授权一个音乐文件夹',
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 12),
                      itemCount: roots.length,
                      itemBuilder: (BuildContext c, int i) {
                        final TreeRef t = roots[i];
                        return MoTile(
                          title: _title(t),
                          subtitle: i == 0 ? '当前目录${_subtitle(t).isEmpty ? '' : ' · ${_subtitle(t)}'}' : (_subtitle(t).isEmpty ? '点一下切换为当前' : _subtitle(t)),
                          icon: i == 0 ? Icons.folder_special : Icons.folder_outlined,
                          trailing: IconButton(
                            tooltip: '移除',
                            icon: Icon(Icons.close, size: 18, color: MoKit.sub(context)),
                            onPressed: () => _remove(t),
                          ),
                          onTap: i == 0 ? null : () => _switch(t),
                        );
                      },
                    ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 8, MoKit.pagePad, 12),
              color: MoKit.card(context),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '多个目录会一起进曲库：查重、整理、批量处理都跨目录生效。',
                    style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context)),
                  ),
                  const SizedBox(height: 8),
                  MoButton('添加目录', busy: _busy, onPressed: _busy ? null : _add),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
