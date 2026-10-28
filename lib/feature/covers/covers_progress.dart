/// 封面批量的行模型与行渲染（页面只管编排，展示逻辑放这里）。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app/cover_song_row.dart';
import '../../app/ui_kit.dart';
import '../../core/model/vfile.dart';

/// 单首的状态。
///
/// [ready] 是两阶段写入的中点：封面已下载到内存、等用户在预览里确认后才真正落盘。
enum CoverPhase { waiting, working, ready, written, skipped, noCover, failed }

/// 单首的进度。
class CoverJob {
  CoverJob(this.file);

  final VFile file;
  CoverPhase phase = CoverPhase.waiting;
  String note = '等待';

  /// 已下载、待写入的封面字节（[CoverPhase.ready] 时有值）。
  Uint8List? pendingBytes;

  /// 写之前那张（撤销 / 预览「已有封面」用）。
  Uint8List? previousBytes;

  /// 从上次中断处恢复出来的封面地址（省掉一次联网查询，直接下载）。
  String resumeUrl = '';

  /// 这条是续跑恢复出来的。
  bool resumed = false;

  void reset() {
    phase = CoverPhase.waiting;
    note = '等待';
    pendingBytes = null;
    previousBytes = null;
    resumeUrl = '';
    resumed = false;
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
    return CoverSongRow(
      key: ValueKey<String>(job.file.docId),
      file: job.file,
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
      case CoverPhase.ready:
        return '待确认';
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
      case CoverPhase.ready:
        return MoKit.primary(context);
      case CoverPhase.skipped:
      case CoverPhase.noCover:
        return MoKit.warn(context);
      default:
        return MoKit.sub(context);
    }
  }
}
