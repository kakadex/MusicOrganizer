/// 单文件标签编辑器：七个字段 + 封面（查看 / 替换 / 移除 / 导出）。
///
/// 写盘一律走 `TagTransaction`：先把本次改动的字段拼成 updates，封面只在
/// 用户动过时传字节（空字节 = 删除），其余情况不碰。保存成功返回 true，
/// 调用方据此刷新列表。
library;

import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../app/cover_cache.dart';
import '../../app/repo.dart';
import '../../app/ui_kit.dart';
import '../../core/fs/raw_write.dart';
import '../../core/model/tags.dart';
import '../../core/model/vfile.dart';
import '../../core/scan/scanner.dart';
import 'editor_cover_card.dart';
import 'editor_online_cover.dart';
import 'editor_online_match.dart';
import 'editor_encoding_sheet.dart';
import 'editor_tag_fields.dart';
import 'encoding_fix.dart';

/// 单文件编辑器页面。
class EditorPage extends StatefulWidget {
  const EditorPage({super.key, required this.file});

  final VFile file;

  /// 打开编辑器；返回 true 表示确实写入过（调用方需要刷新）。
  static Future<bool?> show(BuildContext context, VFile file) {
    return Navigator.of(context).push<bool>(MaterialPageRoute<bool>(
      builder: (BuildContext _) => EditorPage(file: file),
    ));
  }

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  final Map<String, TextEditingController> _ctl =
      <String, TextEditingController>{};
  /// 歌词单独一个控制器（歌词不进 [Tags.keys]：不进撤销日志、也不当普通字段处理）。
  final TextEditingController _lyricsCtl = TextEditingController();

  Tags _initial = Tags();
  bool _loading = true;
  bool _saving = false;
  String _error = '';
  Uint8List? _cover;
  bool _hasCover = false;
  bool _coverTouched = false;

  @override
  void initState() {
    super.initState();
    for (final String key in Tags.keys) {
      final TextEditingController c = TextEditingController();
      c.addListener(_onEdited);
      _ctl[key] = c;
    }
    _lyricsCtl.addListener(_onEdited);
    _load();
  }

  /// 任一输入框变了就重画：「已改」标记与「保存（N 项）」计数要跟着动。
  void _onEdited() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final TextEditingController c in _ctl.values) {
      c.removeListener(_onEdited);
      c.dispose();
    }
    _lyricsCtl.removeListener(_onEdited);
    _lyricsCtl.dispose();
    super.dispose();
  }

  /// 改过的字段数（含歌词与封面）。
  int get _changedCount {
    int n = 0;
    for (final String key in Tags.keys) {
      if (_ctl[key]!.text.trim() != _initial.get(key).trim()) n++;
    }
    if (_lyricsCtl.text.trim() != _initial.get(Tags.lyrics).trim()) n++;
    if (_coverTouched) n++;
    return n;
  }

  /// 单项回滚：把某个字段还原成打开时的值。
  void _revert(String key) {
    final TextEditingController? c = _ctl[key];
    if (c == null) return;
    c.text = _initial.get(key);
  }

  Future<void> _load() async {
    final store = Repo.instance.store;
    if (store == null) {
      setState(() {
        _loading = false;
        _error = '还没有准备好文件访问';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final ScannerHead head = await Scanner.readHead(store, widget.file);
      if (!mounted) return;
      setState(() {
        _initial = head.tags;
        for (final String key in Tags.keys) {
          _ctl[key]!.text = head.tags.get(key);
        }
        _lyricsCtl.text = head.tags.get(Tags.lyrics);
        _cover = head.cover;
        _hasCover = head.cover != null && head.cover!.isNotEmpty;
        _coverTouched = false;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '读取标签失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: <Widget>[
            PageHeader(
              title: '编辑标签',
              subtitle: widget.file.name,
              actions: <Widget>[
                IconButton(
                  tooltip: '返回',
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: Icon(Icons.arrow_back,
                      size: 20, color: MoKit.text(context)),
                ),
                MoButton(_changedCount == 0 ? '保存' : '保存（$_changedCount 项）',
                    busy: _saving,
                    onPressed: _loading || _error.isNotEmpty ? null : _save),
              ],
            ),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error.isNotEmpty) {
      return EmptyState(
        icon: Icons.error_outline,
        text: _error,
        action: MoButton('重试', onPressed: _load),
      );
    }
    final List<String> broken = <String>[
      for (final String key in Tags.keys)
        if (EncodingFix.looksMojibake(_ctl[key]!.text.trim())) key,
    ];
    return ListView(
      padding: const EdgeInsets.only(top: 4, bottom: 24),
      children: <Widget>[
        EditorCoverCard(
          cover: _cover,
          hasCover: _hasCover,
          onPick: _pickCover,
          onOnline: _pickOnlineCover,
          onRemove: _hasCover ? _removeCover : null,
          onExport: _exportCover,
        ),
        EditorTagFields(
          controllers: _ctl,
          initial: _initial,
          lyricsController: _lyricsCtl,
          onRevert: _revert,
          onClearLyrics: () => setState(() => _lyricsCtl.clear()),
        ),
        _onlineMatchCard(),
        if (broken.isNotEmpty)
          EncodingFixHint(count: broken.length, onFix: _showFix),
      ],
    );
  }

  Future<void> _showFix() async {
    final Map<String, List<FieldFix>> byCharset = <String, List<FieldFix>>{};
    for (final String key in Tags.keys) {
      final String before = _ctl[key]!.text.trim();
      if (!EncodingFix.looksMojibake(before)) continue;
      for (final EncodingCandidate c in EncodingFix.candidates(before)) {
        byCharset.putIfAbsent(c.charset, () => <FieldFix>[]).add(FieldFix(
              key: key,
              label: Tags.labels[key] ?? key,
              before: before,
              after: c.text,
            ));
      }
    }
    final String? chosen = await EncodingFixSheet.show(context, byCharset);
    if (!mounted || chosen == null) return;
    setState(() {
      for (final FieldFix fix in byCharset[chosen] ?? const <FieldFix>[]) {
        _ctl[fix.key]!.text = fix.after;
      }
    });
    moSnack(context, '已按 $chosen 重解，确认无误后再保存');
  }

  Future<void> _pickCover() async {
    const XTypeGroup images = XTypeGroup(
      label: '图片',
      extensions: <String>['jpg', 'jpeg', 'png', 'webp'],
      mimeTypes: <String>['image/jpeg', 'image/png', 'image/webp'],
    );
    try {
      final XFile? picked = await openFile(acceptedTypeGroups: <XTypeGroup>[images]);
      if (picked == null) return;
      final Uint8List bytes = await picked.readAsBytes();
      if (bytes.isEmpty) {
        if (mounted) moSnack(context, '这个文件读不出内容');
        return;
      }
      if (!mounted) return;
      setState(() {
        _cover = bytes;
        _hasCover = true;
        _coverTouched = true;
      });
    } catch (e) {
      if (mounted) moSnack(context, '选择封面失败：$e');
    }
  }

  /// 在线取封面：多源查候选，挑一张写进内存（保存时才落盘）。
  Future<void> _pickOnlineCover() async {
    final Uint8List? bytes =
        await pickOnlineCover(context, widget.file, _currentTags());
    if (bytes == null || !mounted) return;
    setState(() {
      _cover = bytes;
      _hasCover = true;
      _coverTouched = true;
    });
  }

  /// 当前输入框里的标签（在线匹配按它去查）。
  Tags _currentTags() {
    final Tags t = Tags();
    for (final String key in Tags.keys) {
      t.put(key, _ctl[key]!.text.trim());
    }
    return t;
  }

  /// 在线匹配卡片：查候选，逐字段勾选后填回输入框。
  Widget _onlineMatchCard() {
    return SectionCard(
      title: '在线匹配',
      subtitle: '多源查候选，只填你勾中的字段',
      children: <Widget>[
        MoButton('在线匹配', primary: false, onPressed: _runOnlineMatch),
      ],
    );
  }

  Future<void> _runOnlineMatch() async {
    final Map<String, String>? picked =
        await showOnlineMatch(context, widget.file, _currentTags());
    if (picked == null || !mounted) return;
    setState(() {
      for (final MapEntry<String, String> e in picked.entries) {
        final TextEditingController? c = _ctl[e.key];
        if (c != null) c.text = e.value;
      }
    });
    moSnack(context, '已填入 ${picked.length} 个字段，确认后再保存');
  }

  void _removeCover() {
    setState(() {
      _cover = null;
      _hasCover = false;
      _coverTouched = true;
    });
  }

  Future<void> _exportCover() async {
    final store = Repo.instance.store;
    if (store == null) {
      moSnack(context, '还没有准备好文件访问');
      return;
    }
    try {
      // 动过封面就只认内存里的状态：移除后不要又从磁盘把旧图导出来
      Uint8List? art = _cover;
      if (art == null && !_coverTouched) {
        art = await Scanner.readCover(store, widget.file);
      }
      if (art == null || art.isEmpty) {
        if (mounted) moSnack(context, '没有可导出的封面');
        return;
      }
      final String? parentId = widget.file.parentId;
      final VFile? dir = parentId == null ? null : await store.stat(parentId);
      if (dir == null) {
        if (mounted) moSnack(context, '找不到文件所在目录');
        return;
      }
      final VFile target =
          await RawWrite.ensureFile(store, dir, 'cover.jpg', 'image/jpeg');
      await RawWrite.bytes(store, target, art);
      CoverCache.instance.clear();
      if (mounted) moSnack(context, '已导出到同目录 cover.jpg');
    } catch (e) {
      if (mounted) moSnack(context, '导出失败：$e');
    }
  }

  Future<void> _save() async {
    final tx = Repo.instance.tx;
    if (tx == null) {
      moSnack(context, '还没有准备好写盘通道');
      return;
    }
    final Map<String, String> updates = <String, String>{};
    for (final String key in Tags.keys) {
      String now = _ctl[key]!.text.trim();
      // 年份只留四位（与 Tags.put / 读回校验口径一致）
      if (key == 'year' && now.length > 4) now = now.substring(0, 4);
      if (now != _initial.get(key)) updates[key] = now;
    }
    final String lyrics = _lyricsCtl.text.trim();
    if (lyrics != _initial.get(Tags.lyrics).trim()) {
      updates[Tags.lyrics] = lyrics;
    }
    final Uint8List? coverArg =
        _coverTouched ? (_cover ?? Uint8List(0)) : null;
    if (updates.isEmpty && coverArg == null) {
      moSnack(context, '没有需要保存的修改');
      return;
    }
    setState(() => _saving = true);
    final String err = await tx.apply(
      widget.file,
      updates,
      cover: coverArg,
      batchId: 'editor-${DateTime.now().millisecondsSinceEpoch}',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (err.isNotEmpty) {
      moSnack(context, '保存失败：$err');
      return;
    }
    Repo.instance.invalidate(widget.file);
    CoverCache.instance.clear();
    moSnack(context, '已保存');
    Navigator.of(context).pop(true);
  }
}
