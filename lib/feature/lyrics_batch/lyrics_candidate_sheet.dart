/// 歌词候选列表：一首歌命中多个源时，让用户自己挑一条。
///
/// 为什么不只给最高分：`offerScore` 只回答「像不像同一首歌」，不比谁的歌词
/// 更完整、更准 —— 同名不同版本（演唱会版 / remix / 翻唱）经常并列，
/// 机器选的那条未必是用户想要的。这里把候选按分数排好、各带前两行预览，
/// 让人一眼能分辨。
library;

import 'package:flutter/material.dart';

import '../../app/ui_kit.dart';
import 'lyrics_logic.dart';

/// 候选选择面板；返回选中的候选，取消返回 null。
class LyricCandidateSheet extends StatefulWidget {
  const LyricCandidateSheet({super.key, required this.candidates});

  final List<LyricChoice> candidates;

  static Future<LyricChoice?> show(
      BuildContext context, List<LyricChoice> candidates) {
    return showModalBottomSheet<LyricChoice>(
      context: context,
      isScrollControlled: true,
      backgroundColor: MoKit.bg(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (BuildContext ctx) =>
          LyricCandidateSheet(candidates: candidates),
    );
  }

  @override
  State<LyricCandidateSheet> createState() => _LyricCandidateSheetState();
}

class _LyricCandidateSheetState extends State<LyricCandidateSheet> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final LyricChoice picked = widget.candidates[_index];
    return MoSheetScaffold(
      title: '共 ${widget.candidates.length} 条候选',
      content: <Widget>[
        for (int i = 0; i < widget.candidates.length; i++)
          _tile(context, widget.candidates[i], i),
      ],
      footer: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              '这条 ${LyricPick.brief(picked.text, maxLines: 1)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context)),
            ),
          ),
          const SizedBox(width: 8),
          MoButton('用这条', onPressed: () => Navigator.of(context).pop(picked)),
        ],
      ),
    );
  }

  Widget _tile(BuildContext context, LyricChoice c, int i) {
    final bool on = i == _index;
    final String preview = LyricPick.brief(c.text);
    return InkWell(
      onTap: () => setState(() => _index = i),
      child: Container(
        margin: const EdgeInsets.fromLTRB(MoKit.pagePad, 0, MoKit.pagePad, 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: on ? MoKit.primary(context).withValues(alpha: 0.10) : MoKit.card(context),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: on ? MoKit.primary(context) : MoKit.line(context),
              width: on ? 1.2 : 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(on ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                    size: 18,
                    color: on ? MoKit.primary(context) : MoKit.faint(context)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${c.sourceLabel} · ${c.hasTiming ? '带时间轴' : '无时间轴'}',
                    style: TextStyle(
                        fontSize: MoKit.fsBody,
                        fontWeight: on ? FontWeight.w600 : FontWeight.w500,
                        color: MoKit.text(context)),
                  ),
                ),
                Text('${(c.score * 100).round()}%',
                    style: TextStyle(
                        fontSize: MoKit.fsCaption,
                        color: c.low ? MoKit.warn(context) : MoKit.sub(context))),
              ],
            ),
            if (preview.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 26, top: 4),
                child: Text(preview,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: MoKit.fsCaption,
                        height: 1.35,
                        color: MoKit.sub(context))),
              ),
            Padding(
              padding: const EdgeInsets.only(left: 26, top: 4),
              child: Text(
                <String>[
                  if (c.hasTranslation) '有译文',
                  if (c.low) '低置信（可能不是同一版本）',
                  if (!c.hasTiming) '无时间轴，播放器不滚动',
                ].join(' · '),
                style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.faint(context)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
