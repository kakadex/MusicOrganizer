/// 批量歌词的行模型与行渲染。
library;

import 'package:flutter/material.dart';

import '../../app/cover_song_row.dart';
import '../../app/ui_kit.dart';
import '../../core/model/vfile.dart';
import 'lyrics_logic.dart';

/// 一首歌的取词状态。
class LyricRow {
  LyricRow(this.file);

  final VFile file;
  LyricChoice? choice;
  bool selected = false;
  String status = '等待';

  /// 重新取词前复位。
  void reset() {
    choice = null;
    selected = false;
    status = '等待';
  }
}

/// 一行：曲名 + 来源/置信度 + 勾选状态。
class LyricRowTile extends StatelessWidget {
  const LyricRowTile({super.key, required this.row, required this.onTap});

  final LyricRow row;

  /// 没有候选时为 null（不可勾选）。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final LyricChoice? choice = row.choice;
    return CoverSongRow(
      key: ValueKey<String>(row.file.docId),
      file: row.file,
      title: row.file.stem(),
      subtitle: choice == null ? row.status : '${row.status} · ${choice.note}',
      selectionMode: choice != null,
      selected: row.selected,
      onTap: onTap,
      trailing: choice != null && choice.low
          ? Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text('低置信',
                  style: TextStyle(
                      fontSize: MoKit.fsCaption, color: MoKit.warn(context))),
            )
          : null,
    );
  }
}
