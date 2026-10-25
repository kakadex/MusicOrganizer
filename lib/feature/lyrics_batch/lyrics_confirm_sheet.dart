/// 歌词写入前的确认面板：逐首列出将要写入的来源与时间轴情况。
///
/// 联网取回的歌词一律先过这一层，不直接落盘；面板只回传「确认 / 取消」，
/// 真正的写盘由页面在拿到 true 之后执行。
library;

import 'package:flutter/material.dart';

import '../../app/ui_kit.dart';
import 'lyrics_logic.dart';

/// 歌词写入确认。
abstract final class LyricsConfirmSheet {
  /// 弹出确认；返回 true 表示用户点了写入。
  static Future<bool?> show(
    BuildContext context, {
    required List<LyricPlan> plans,
    required bool writeLrc,
  }) {
    return showMoSheet<bool>(
      context,
      title: '确认写入歌词',
      children: <Widget>[_Body(plans: plans, writeLrc: writeLrc)],
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.plans, required this.writeLrc});

  final List<LyricPlan> plans;
  final bool writeLrc;

  @override
  Widget build(BuildContext context) {
    final int timed = plans.where((LyricPlan p) => p.choice.hasTiming).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 0, MoKit.pagePad, 8),
          child: Text(
            '将写入 ${plans.length} 首内嵌歌词'
            '（带时间轴 $timed 首）${writeLrc ? '，同时写同名 .lrc' : ''}',
            style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context)),
          ),
        ),
        for (final LyricPlan p in plans)
          Container(
            margin: const EdgeInsets.fromLTRB(MoKit.pagePad, 0, MoKit.pagePad, 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: MoKit.card(context),
              borderRadius: BorderRadius.circular(MoKit.radiusRow),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(p.file.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: MoKit.fsBody,
                        fontWeight: FontWeight.w500,
                        color: MoKit.text(context))),
                const SizedBox(height: 2),
                Text(p.choice.note,
                    style: TextStyle(
                        fontSize: MoKit.fsCaption,
                        color: p.choice.low
                            ? MoKit.warn(context)
                            : MoKit.sub(context))),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 6, MoKit.pagePad, 8),
          child: Align(
            alignment: Alignment.centerRight,
            child: MoButton('写入 ${plans.length} 首',
                onPressed: () => Navigator.of(context).pop(true)),
          ),
        ),
      ],
    );
  }
}
