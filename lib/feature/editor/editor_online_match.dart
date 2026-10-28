/// 编辑器里的「在线匹配」：多源查出候选，逐字段勾选后填回输入框。
///
/// 与批量匹配同一条链路（[Aggregator.tagCandidates]），但**只填勾中的字段**，
/// 不整条覆盖 —— 用户自己的写法不该被顺手抹掉。
library;

import 'package:flutter/material.dart';

import '../../app/ui_kit.dart';
import '../../core/match/local_query.dart';
import '../../core/model/candidate.dart';
import '../../core/model/query.dart';
import '../../core/model/tags.dart';
import '../../core/model/vfile.dart';
import '../../core/source/aggregator.dart';

/// 在线匹配卡片：返回用户勾选要填入的字段与值（没选返回 null）。
Future<Map<String, String>?> showOnlineMatch(
    BuildContext context, VFile file, Tags current) async {
  final Query q = LocalQuery.forFile(file, current);
  showMoSheet<void>(
    context,
    title: '正在联网匹配…',
    children: <Widget>[
      const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      ),
    ],
  );
  // 手动匹配：这里正是「本地标签可能错了」的场景，不能按本地艺人严格筛
  // （否则想修错标签时，正确答案会被一起筛掉），只把不像的排到后面。
  final AggregateResult agg = await Aggregator.tagCandidates(
      q, chinese: LocalQuery.chinese(q), verify: false);
  if (!context.mounted) return null;
  Navigator.of(context).pop();
  if (agg.candidates.isEmpty) {
    moSnack(context, '没有查到候选');
    return null;
  }
  return showModalBottomSheet<Map<String, String>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: MoKit.bg(context),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (BuildContext ctx) {
      return _MatchSheet(candidates: agg.candidates);
    },
  );
}

/// 候选选择面板。
class _MatchSheet extends StatefulWidget {
  const _MatchSheet({required this.candidates});

  final List<Candidate> candidates;

  @override
  State<_MatchSheet> createState() => _MatchSheetState();
}

class _MatchSheetState extends State<_MatchSheet> {
  int _index = 0;
  /// 勾选要填入的字段（默认全选非空字段）。
  final Set<String> _picked = <String>{};

  static const List<String> _fields = <String>[
    'title', 'artist', 'albumArtist', 'album', 'year', 'track', 'genre',
  ];

  @override
  void initState() {
    super.initState();
    _resetPicked();
  }

  void _resetPicked() {
    _picked.clear();
    final Candidate c = widget.candidates[_index];
    for (final String f in _fields) {
      if (_valueOf(c, f).trim().isNotEmpty) _picked.add(f);
    }
  }

  /// 候选里某个字段的值。
  static String _valueOf(Candidate c, String field) {
    switch (field) {
      case 'title':
        return c.title;
      case 'artist':
        return c.artist;
      case 'album':
        return c.album;
      case 'year':
        return c.year;
      case 'track':
        return c.track;
      case 'genre':
        return c.genre;
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final Candidate c = widget.candidates[_index];
    return SafeArea(
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.82),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 14, MoKit.pagePad, 6),
              child: Text('在线匹配：第 ${_index + 1} / ${widget.candidates.length} 条',
                  style: TextStyle(
                      fontSize: MoKit.fsTitle, color: MoKit.text(context))),
            ),
            if (widget.candidates.length > 1)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: MoKit.pagePad),
                child: Row(
                  children: <Widget>[
                    MoButton('上一条', primary: false,
                        onPressed: _index == 0
                            ? null
                            : () => setState(() {
                                  _index--;
                                  _resetPicked();
                                })),
                    const SizedBox(width: 8),
                    MoButton('下一条', primary: false,
                        onPressed: _index >= widget.candidates.length - 1
                            ? null
                            : () => setState(() {
                                  _index++;
                                  _resetPicked();
                                })),
                    const Spacer(),
                    Text('[${c.source}]',
                        style: TextStyle(
                            fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
                  ],
                ),
              ),
            const Padding(
              padding: EdgeInsets.fromLTRB(MoKit.pagePad, 10, MoKit.pagePad, 4),
              child: Text('勾选要填入的字段（只填勾中的，不整条覆盖）：',
                  style: TextStyle(fontSize: MoKit.fsCaption)),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: <Widget>[
                  for (final String f in _fields)
                    _fieldRow(context, c, f),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(MoKit.pagePad),
              child: MoButton('填入选中的 ${_picked.length} 项',
                  onPressed: _picked.isEmpty
                      ? null
                      : () => Navigator.of(context).pop(<String, String>{
                            for (final String f in _picked)
                              f: _valueOf(widget.candidates[_index], f).trim(),
                          })),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fieldRow(BuildContext context, Candidate c, String field) {
    final String value = _valueOf(c, field).trim();
    if (value.isEmpty) return const SizedBox.shrink();
    final bool on = _picked.contains(field);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: MoKit.pagePad, vertical: 1),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 30,
            height: 30,
            child: Checkbox(
              value: on,
              onChanged: (bool? v) => setState(() {
                if (v == true) {
                  _picked.add(field);
                } else {
                  _picked.remove(field);
                }
              }),
              visualDensity: VisualDensity.compact,
            ),
          ),
          SizedBox(
            width: 56,
            child: Text(Tags.labels[field] ?? field,
                style: TextStyle(
                    fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
          ),
          Expanded(
            child: Text(value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    TextStyle(fontSize: MoKit.fsBody, color: MoKit.text(context))),
          ),
        ],
      ),
    );
  }
}
