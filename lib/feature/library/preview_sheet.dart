import 'package:flutter/material.dart';

import '../../app/repo.dart';
import '../../app/ui_kit.dart';
import '../../core/match/tag_plan.dart';
import '../../core/model/journal_entry.dart';
import '../../core/model/vfile.dart';
import '../../core/task/task_center.dart';
import '../../core/tx/journal.dart';
import '../../core/tx/tag_transaction.dart';

/// 写入前预览：逐首展开「旧值 → 新值」，勾选后才写盘。
///
/// 这是本项目的硬约束：**任何联网结果都必须先预览再写**。
/// 返回 true 表示确实写入过（调用方据此刷新列表）。
class PreviewSheet extends StatelessWidget {
  const PreviewSheet({super.key, required this.plans});

  final List<FilePlan> plans;

  /// 弹出预览；返回值 = 是否写入过。
  static Future<bool?> show(BuildContext context, List<FilePlan> plans) {
    return showMoSheet<bool>(
      context,
      title: '确认写入',
      children: <Widget>[_PreviewBody(plans: plans)],
    );
  }

  @override
  Widget build(BuildContext context) => _PreviewBody(plans: plans);
}

class _PreviewBody extends StatefulWidget {
  const _PreviewBody({required this.plans});

  final List<FilePlan> plans;

  @override
  State<_PreviewBody> createState() => _PreviewBodyState();
}

class _PreviewBodyState extends State<_PreviewBody> {
  late final List<FilePlan> _plans = List<FilePlan>.of(widget.plans);
  final Set<String> _expanded = <String>{};
  bool _busy = false;
  String _status = '';

  @override
  Widget build(BuildContext context) {
    final List<FilePlan> changed = _plans.where((FilePlan p) => p.hasChange).toList();
    final int selected = _plans.where((FilePlan p) => p.selected && p.hasChange).length;
    final int low = _plans.where((FilePlan p) => p.lowConfidence).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 0, MoKit.pagePad, 8),
          child: Text(
            '${TagPlan.summarize(_plans)}${low > 0 ? ' · 低置信 $low 首（已标出，建议逐个确认）' : ''}',
            style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context)),
          ),
        ),
        if (changed.isEmpty)
          Padding(
            padding: const EdgeInsets.all(MoKit.pagePad),
            child: Text('没有需要写入的字段（可能都已经是目标值了）',
                style: TextStyle(fontSize: MoKit.fsBody, color: MoKit.sub(context))),
          ),
        for (final FilePlan p in changed) _row(context, p),
        Padding(
          padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 10, MoKit.pagePad, 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  _status.isEmpty ? '将写入 $selected 首' : _status,
                  style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context)),
                ),
              ),
              MoButton('写入 $selected 首',
                  busy: _busy,
                  onPressed: selected == 0 ? null : () => _write(selected)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, FilePlan p) {
    final bool open = _expanded.contains(p.file.docId);
    return Container(
      margin: const EdgeInsets.fromLTRB(MoKit.pagePad, 0, MoKit.pagePad, 8),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: MoKit.card(context),
        borderRadius: BorderRadius.circular(MoKit.radiusRow),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Checkbox(
                value: p.selected,
                visualDensity: VisualDensity.compact,
                onChanged: (bool? v) => setState(() => p.selected = v ?? false),
              ),
              Expanded(
                child: GestureDetector(
                  onTap: () => setState(() {
                    if (open) {
                      _expanded.remove(p.file.docId);
                    } else {
                      _expanded.add(p.file.docId);
                    }
                  }),
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
                      Row(
                        children: <Widget>[
                          if (p.lowConfidence)
                            Container(
                              margin: const EdgeInsets.only(right: 6),
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                  color: MoKit.warn(context).withValues(alpha: 0.16),
                                  borderRadius: BorderRadius.circular(6)),
                              child: Text('低置信',
                                  style: TextStyle(
                                      fontSize: 10, color: MoKit.warn(context))),
                            ),
                          Expanded(
                            child: Text(p.note,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              Text('${p.fields.where((PlanField f) => f.accepted).length} 项',
                  style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
              Icon(open ? Icons.expand_less : Icons.expand_more,
                  size: 18, color: MoKit.faint(context)),
            ],
          ),
          if (open)
            for (final PlanField f in p.fields)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Checkbox(
                      value: f.accepted,
                      visualDensity: VisualDensity.compact,
                      onChanged: (bool? v) => setState(() => f.accepted = v ?? false),
                    ),
                    SizedBox(
                      width: 46,
                      child: Text(TagFillLabel.of(f.key),
                          style: TextStyle(
                              fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
                    ),
                    Expanded(
                      child: Text.rich(TextSpan(children: <TextSpan>[
                        TextSpan(
                            text: f.oldValue.isEmpty ? '（空）' : f.oldValue,
                            style: TextStyle(
                                fontSize: MoKit.fsBody, color: MoKit.faint(context))),
                        TextSpan(
                            text: '  →  ',
                            style: TextStyle(
                                fontSize: MoKit.fsBody, color: MoKit.faint(context))),
                        TextSpan(
                            text: f.newValue,
                            style: TextStyle(
                                fontSize: MoKit.fsBody,
                                fontWeight: FontWeight.w500,
                                color: MoKit.text(context))),
                      ])),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  Future<void> _write(int selected) async {
    final runner = Repo.instance.runner;
    if (runner == null) return;
    setState(() {
      _busy = true;
      _status = '正在写入…';
    });
    final RunningTask? task = TaskCenter.start('写入标签');
    final control = task?.control;
    final String batchId = runner.newBatchId();
    final report = await runner.write(_plans, control: control, batchId: batchId);
    TaskCenter.finish();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = report.summary();
    });
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Text(report.summary()),
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.all(12),
      action: report.written == 0
          ? null
          : SnackBarAction(
              label: '撤销',
              onPressed: () async {
                final int n = await undoBatch(batchId);
                messenger.showSnackBar(SnackBar(
                    content: Text('已撤销 $n 处改动'),
                    behavior: SnackBarBehavior.floating,
                    margin: const EdgeInsets.all(12)));
              },
            ),
    ));
    Navigator.of(context).pop(true);
  }
}

/// 按批次撤销（把 before 写回去）。
///
/// 逆序回滚：同一字段被多次改写时，最后写的那条先回退，才不会互相覆盖。
Future<int> undoBatch(String batchId) async {
  final Repo repo = Repo.instance;
  final Journal? journal = repo.journal;
  final TagTransaction? tx = repo.tx;
  if (journal == null || tx == null) return 0;
  int ok = 0;
  await journal.revertBatch(batchId, revertOne: (JournalEntry entry) async {
    // 旧日志只写了 uri（同一份 docId），这里两个都认，否则撤销会静默 0 条
    final String key = entry.targetId.isNotEmpty ? entry.targetId : entry.uri;
    VFile? target;
    for (final VFile f in repo.files) {
      if (f.docId == key) {
        target = f;
        break;
      }
    }
    if (target == null) return false;
    final String err =
        await tx.apply(target, Map<String, String>.from(entry.before), record: false);
    if (err.isEmpty) {
      ok++;
      repo.invalidate(target);
      return true;
    }
    return false;
  });
  return ok;
}

/// 字段名 → 中文（预览里用短名，别把整列挤满）。
abstract final class TagFillLabel {
  static String of(String key) {
    switch (key) {
      case 'title':
        return '标题';
      case 'artist':
        return '歌手';
      case 'album':
        return '专辑';
      case 'year':
        return '年份';
      case 'track':
        return '音轨';
      case 'genre':
        return '流派';
      case 'comment':
        return '注释';
      default:
        return key;
    }
  }
}
