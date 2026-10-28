/// 歌词工具：清洗、整体偏移偏移、查看。
///
/// 从曲库选中曲目后进来：读出歌词（内嵌优先，其次同名 .lrc）→ 勾选要做的处理 →
/// 预览 → 确认后写回（内嵌歌词与 .lrc 都写）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app/repo.dart';
import '../../app/ui_kit.dart';
import '../../core/fs/file_store.dart';
import '../../core/lyrics/lyrics_shift.dart';
import '../../core/lyrics/lyrics_tool.dart';
import '../../core/model/tags.dart';
import '../../core/model/vfile.dart';
import '../../core/scan/scanner.dart';
import '../../core/tx/write_preview.dart';
import '../common/write_confirm_sheet.dart';
import 'lyrics_lrc_writer.dart';

/// 打开歌词工具。[files] 是选中的曲目（取第一首）。
Future<void> runLyricsTool(BuildContext context, List<VFile> files) async {
  if (files.isEmpty) return;
  final Repo repo = Repo.instance;
  final FileStore? store = repo.store;
  if (store == null) {
    moSnack(context, '还没有准备好文件访问');
    return;
  }
  final VFile file = files.first;
  final String text = await readLyrics(store, file);
  if (!context.mounted) return;
  if (text.trim().isEmpty) {
    moSnack(context, '这首还没有歌词');
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: MoKit.bg(context),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (BuildContext ctx) =>
        _ToolSheet(store: store, file: file, source: text),
  );
}

/// 读歌词：内嵌标签优先，其次同名 .lrc。
Future<String> readLyrics(FileStore store, VFile file) async {
  try {
    final Tags tags = await Scanner.readTags(store, file);
    final String inline = tags.get(Tags.lyrics).trim();
    if (inline.isNotEmpty) return inline;
  } catch (_) {
    // 读不到标签就退到同名 .lrc
  }
  try {
    final String? parentId = file.parentId;
    if (parentId == null) return '';
    final VFile? dir = await store.stat(parentId);
    if (dir == null) return '';
    final VFile? side =
        await store.stat('${dir.docId}/${file.stem()}.lrc');
    if (side == null || side.name.isEmpty) return '';
    final Uint8List bytes = await store.headBytes(side, 1024 * 1024);
    return utf8.decode(bytes, allowMalformed: true);
  } catch (_) {
    return '';
  }
}

/// 工具面板。
class _ToolSheet extends StatefulWidget {
  const _ToolSheet({required this.store, required this.file, required this.source});

  final FileStore store;
  final VFile file;
  final String source;

  @override
  State<_ToolSheet> createState() => _ToolSheetState();
}

class _ToolSheetState extends State<_ToolSheet> {
  int _ops = LyricsTool.opEmpty | LyricsTool.opHeader | LyricsTool.opDedupe;
  int _deltaMs = 0;

  /// 当前结果 = 先偏移时间轴，再做清洗（预览与写回都用它）。
  String get _result =>
      LyricsTool.apply(LyricsShift.shift(widget.source, _deltaMs), _ops);

  /// 偏移区的提示文字。
  String get _shiftHint {
    final int n = LyricsShift.count(_result);
    if (n == 0) return '没有时间戳，不能偏移';
    return '当前 $n 个时间戳';
  }

  @override
  Widget build(BuildContext context) {
    final bool canShift = LyricsShift.count(_result) > 0;
    return MoSheetScaffold(
      title: '歌词工具 · ${widget.file.stem()}',
      content: <Widget>[
        const Padding(
          padding: EdgeInsets.fromLTRB(MoKit.pagePad, 0, MoKit.pagePad, 4),
          child: Text('清洗（勾选要做的）',
              style: TextStyle(fontSize: MoKit.fsCaption)),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: <Widget>[
            _opChip('删空行', LyricsTool.opEmpty),
            _opChip('去元信息', LyricsTool.opHeader),
            _opChip('去时间轴', LyricsTool.opTimestamp),
            _opChip('规范时间轴', LyricsTool.opNormalize),
            _opChip('去重复行', LyricsTool.opDedupe),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 12, MoKit.pagePad, 4),
          child: Text('整体偏移（$_shiftHint）',
              style: TextStyle(fontSize: MoKit.fsCaption)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: MoKit.pagePad),
          child: Row(
            children: <Widget>[
              MoButton('-1s', primary: false,
                  onPressed: canShift ? () => _shift(-1000) : null),
              const SizedBox(width: 6),
              MoButton('-0.1s', primary: false,
                  onPressed: canShift ? () => _shift(-100) : null),
              const SizedBox(width: 6),
              Text('${_deltaMs > 0 ? '+' : ''}$_deltaMs ms',
                  style: TextStyle(
                      fontSize: MoKit.fsBody, color: MoKit.text(context))),
              const SizedBox(width: 6),
              MoButton('+0.1s', primary: false,
                  onPressed: canShift ? () => _shift(100) : null),
              const SizedBox(width: 6),
              MoButton('+1s', primary: false,
                  onPressed: canShift ? () => _shift(1000) : null),
              const Spacer(),
              MoButton('归零', primary: false,
                  onPressed: canShift ? () => _shift(-_deltaMs) : null),
            ],
          ),
        ),
        if (LyricsShift.collapsesToZero(_result, _deltaMs))
          Padding(
            padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 6, MoKit.pagePad, 0),
            child: Text('这样偏移后所有时间戳都变成 0，播放器会认不出来',
                style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.warn(context))),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 12, MoKit.pagePad, 4),
          child: Text('预览：',
              style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
        ),
        Container(
          constraints: const BoxConstraints(maxHeight: 220),
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: MoKit.bg(context),
            borderRadius: BorderRadius.circular(10),
          ),
          child: SingleChildScrollView(
            child: Text(_result,
                style: TextStyle(
                    fontSize: MoKit.fsBody, color: MoKit.text(context))),
          ),
        ),
      ],
      // 固定底栏：预览再长也不用滚到底才能写回
      footer: Row(
        children: <Widget>[
          Expanded(
            child: MoButton('查看原歌词', primary: false,
                onPressed: () => _showViewer(context, widget.source)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: MoButton('写回', onPressed: _save),
          ),
        ],
      ),
    );
  }

  Widget _opChip(String label, int op) {
    final bool on = _ops & op != 0;
    return GestureDetector(
      onTap: () => setState(() => _ops = on ? (_ops & ~op) : (_ops | op)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: on ? MoKit.primary(context) : MoKit.card(context),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: MoKit.fsCaption,
                color: on ? MoKit.bg(context) : MoKit.text(context))),
      ),
    );
  }

  void _shift(int delta) {
    setState(() {
      _deltaMs += delta;
    });
  }

  /// 歌词预览只显示头一行 + 行数。
  static String _brief(String text) {
    final String t = text.trim();
    if (t.isEmpty) return '';
    final List<String> lines =
        t.split('\n').where((String s) => s.trim().isNotEmpty).toList();
    final String head = lines.isEmpty ? '' : lines.first.trim();
    return lines.length <= 1 ? head : '$head …（共 ${lines.length} 行）';
  }

  Future<void> _save() async {
    final String out = _result;
    if (out == widget.source) {
      if (mounted) moSnack(context, '歌词没有变化');
      return;
    }
    final List<WriteTarget> targets = <WriteTarget>[
      WriteTarget(
        docId: widget.file.docId,
        name: widget.file.name,
        path: Repo.instance.relPath(widget.file),
        kind: WriteKind.lyrics,
        note: '${_brief(widget.source)} → ${_brief(out)}',
        lines: <WriteLine>[
          WriteLine(
            label: '内嵌歌词',
            oldText: _brief(widget.source),
            newText: _brief(out),
            key: Tags.lyrics,
            payload: out,
          ),
          WriteLine(
            label: '同名 .lrc',
            oldText: '（随内嵌歌词一起写）',
            newText: '写入 ${widget.file.stem()}.lrc',
            key: '__lrc',
          ),
        ],
      ),
    ];
    final List<WriteTarget>? picked = await WriteConfirmSheet.show(
      context,
      title: '确认写入歌词',
      targets: targets,
      commitLabel: '写回',
      unit: '处',
      verb: '写入',
      expandAll: true,
    );
    if (!mounted || picked == null || picked.isEmpty) return;
    final WriteTarget t = picked.first;
    if (!t.lines.any((WriteLine l) => l.key == Tags.lyrics && l.selected)) return;
    final bool wantLrc =
        t.lines.any((WriteLine l) => l.key == '__lrc' && l.selected);

    final String err = await Repo.instance.tx?.apply(
          widget.file,
          <String, String>{Tags.lyrics: out},
          batchId: 'lyrictool-${DateTime.now().millisecondsSinceEpoch}',
        ) ??
        '还没有准备好写盘通道';
    if (err.isNotEmpty) {
      if (mounted) moSnack(context, '写入失败：$err');
      return;
    }
    String lrcErr = '';
    if (wantLrc) {
      lrcErr = await LyricLrcWriter.write(widget.store, widget.file, out);
    }
    if (!mounted) return;
    Repo.instance.invalidate(widget.file);
    moSnack(context,
        lrcErr.isEmpty ? '已写回内嵌歌词与 .lrc' : '内嵌歌词已写入，.lrc 失败：$lrcErr');
  }

  void _showViewer(BuildContext context, String text) {
    showMoSheet<void>(
      context,
      title: '歌词',
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.all(MoKit.pagePad),
          child: SingleChildScrollView(
            child: Text(text,
                style:
                    TextStyle(fontSize: MoKit.fsBody, color: MoKit.text(context))),
          ),
        ),
      ],
    );
  }
}
