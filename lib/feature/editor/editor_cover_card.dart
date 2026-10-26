/// 编辑器里的封面卡片：预览、换图、移除、导出。
///
/// 只展示与转发点击，封面字节由页面统一持有，避免两处状态不同步。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app/ui_kit.dart';

/// 封面操作卡片。
class EditorCoverCard extends StatelessWidget {
  const EditorCoverCard({
    super.key,
    required this.cover,
    required this.hasCover,
    required this.onPick,
    required this.onOnline,
    required this.onRemove,
    required this.onExport,
  });

  /// 当前封面字节（可能来自文件或用户新选的图）。
  final Uint8List? cover;

  /// 当前是否判定为「有内嵌封面」。
  final bool hasCover;

  final VoidCallback onPick;

  /// 在线取封面（多源查候选后挑一张）。
  final VoidCallback onOnline;

  /// 没有封面时为 null（按钮置灰）。
  final VoidCallback? onRemove;

  final VoidCallback onExport;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: '封面',
      subtitle: hasCover ? '有内嵌封面' : '没有内嵌封面',
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            CoverBox(bytes: cover, size: 76),
            const SizedBox(width: 12),
            Expanded(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  MoButton('选封面', primary: false, onPressed: onPick),
                  MoButton('在线取', primary: false, onPressed: onOnline),
                  MoButton('移除',
                      primary: false, onPressed: hasCover ? onRemove : null),
                  MoButton('导出 cover.jpg',
                      primary: false, onPressed: onExport),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}
