/// 带封面异步加载的曲目行（批量页等列表复用）：内部走 [CoverCache]，滚动不重复解压。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/model/vfile.dart';
import 'cover_cache.dart';
import 'ui_kit.dart';

/// 与 [SongRow] 同参数、但会根据 [file] 自动加载封面。
class CoverSongRow extends StatefulWidget {
  const CoverSongRow({
    super.key,
    required this.file,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.selected = false,
    this.selectionMode = false,
    this.highlight = false,
  });

  final VFile file;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool selected;
  final bool selectionMode;
  final bool highlight;

  @override
  State<CoverSongRow> createState() => _CoverSongRowState();
}

class _CoverSongRowState extends State<CoverSongRow> {
  Uint8List? _cover;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final VFile file = widget.file;
    final Uint8List? hit = CoverCache.instance.peek(file);
    if (hit != null) {
      if (mounted) setState(() => _cover = hit);
      return;
    }
    if (CoverCache.instance.knownMiss(file)) return;
    final Uint8List? art = await CoverCache.instance.load(file);
    if (mounted && art != null) setState(() => _cover = art);
  }

  @override
  Widget build(BuildContext context) {
    return SongRow(
      title: widget.title,
      subtitle: widget.subtitle,
      cover: _cover,
      trailing: widget.trailing,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      selected: widget.selected,
      selectionMode: widget.selectionMode,
      highlight: widget.highlight,
    );
  }
}
