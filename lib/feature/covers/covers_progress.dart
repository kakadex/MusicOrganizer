/// 封面批量的行模型与行渲染（页面只管编排，展示逻辑放这里）。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app/ui_kit.dart';
import '../../core/model/vfile.dart';

/// 单首的状态。
enum CoverPhase { waiting, working, written, skipped, noCover, failed }

/// 单首的进度。
class CoverJob {
  CoverJob(this.file);

  final VFile file;
  CoverPhase phase = CoverPhase.waiting;
  String note = '等待';

  void reset() {
    phase = CoverPhase.waiting;
    note = '等待';
  }
}

/// 写封面之前的样子（封面不进 journal，撤销靠它）。
class CoverUndo {
  const CoverUndo(this.file, this.previous);

  final VFile file;
  final Uint8List? previous;
}

/// 一行：曲名 + 状态说明 + 右侧状态字。
class CoverJobRow extends StatelessWidget {
  const CoverJobRow({super.key, required this.job});

  final CoverJob job;

  @override
  Widget build(BuildContext context) {
    return SongRow(
      title: job.file.stem(),
      subtitle: job.note,
      trailing: Padding(
        padding: const EdgeInsets.only(left: 8),
        child: Text(labelOf(job.phase),
            style: TextStyle(
                fontSize: MoKit.fsCaption, color: colorOf(context, job.phase))),
      ),
    );
  }

  /// 状态中文名。
  static String labelOf(CoverPhase phase) {
    switch (phase) {
      case CoverPhase.waiting:
        return '';
      case CoverPhase.working:
        return '处理中';
      case CoverPhase.written:
        return '已写入';
      case CoverPhase.skipped:
        return '跳过';
      case CoverPhase.noCover:
        return '无封面';
      case CoverPhase.failed:
        return '失败';
    }
  }

  /// 状态颜色。
  static Color colorOf(BuildContext context, CoverPhase phase) {
    switch (phase) {
      case CoverPhase.written:
        return MoKit.ok(context);
      case CoverPhase.failed:
        return MoKit.err(context);
      case CoverPhase.skipped:
      case CoverPhase.noCover:
        return MoKit.warn(context);
      default:
        return MoKit.sub(context);
    }
  }
}
