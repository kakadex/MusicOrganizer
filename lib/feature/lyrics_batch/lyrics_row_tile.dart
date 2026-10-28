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

  /// 这首歌命中的全部候选（按分数降序）；长度 > 1 时界面给「换一条」。
  List<LyricChoice> candidates = <LyricChoice>[];
  bool selected = false;
  String status = '等待';

  /// 这条是从上次中断处**恢复**出来的（已经查到过，不必再联网）。
  bool resumed = false;

  /// 重新取词前复位。
  void reset() {
    choice = null;
    candidates = <LyricChoice>[];
    selected = false;
    status = '等待';
    resumed = false;
  }

  /// 有没有可选的其他版本。
  bool get canSwitch => candidates.length > 1;
}

/// 一行：曲名 + 来源/置信度 + 勾选状态。
class LyricRowTile extends StatelessWidget {
  const LyricRowTile({
    super.key,
    required this.row,
    required this.onTap,
    this.onSwitch,
  });

  final LyricRow row;

  /// 没有候选时为 null（不可勾选）。
  final VoidCallback? onTap;

  /// 打开候选列表；没有多个候选时为 null。
  final VoidCallback? onSwitch;

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
      trailing: choice == null
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (choice.low)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text('低置信',
                        style: TextStyle(
                            fontSize: MoKit.fsCaption, color: MoKit.warn(context))),
                  ),
                if (row.canSwitch)
                  TextButton(
                    onPressed: onSwitch,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 32),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text('换一条（${row.candidates.length}）',
                        style: TextStyle(fontSize: MoKit.fsCaption)),
                  ),
              ],
            ),
    );
  }
}
