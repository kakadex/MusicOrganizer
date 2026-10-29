import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/repo.dart';
import '../../app/ui_kit.dart';
import '../../core/match/tag_plan.dart';
import '../../core/task/match_runner.dart';
import '../../core/task/task_center.dart';
import '../history/undo_flow.dart';

/// 写入前预览：逐首展开「旧值 → 新值」，勾选后才写盘。
///
/// 这是本项目的硬约束：**任何联网结果都必须先预览再写**。
/// 返回 true 表示确实写入过（调用方据此刷新列表）。
class PreviewSheet extends StatelessWidget {
  const PreviewSheet({super.key, required this.plans});

  final List<FilePlan> plans;

  /// 弹出预览；返回值 = 是否写入过。
  static Future<bool?> show(BuildContext context, List<FilePlan> plans) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: MoKit.bg(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (BuildContext ctx) => _PreviewBody(plans: plans),
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

    return MoSheetScaffold(
      title: '确认写入',
      // 只有曲目列表滚动；底栏固定，203 首也不会把「写入」按钮顶出屏幕
      content: <Widget>[
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
      ],
      footer: Row(
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
                // 整行标题都可点：右侧「N 项」和箭头也在点击区内，
                // 不用非要去点歌名那一小段才能展开
                child: InkWell(
                  onTap: () => setState(() {
                    if (open) {
                      _expanded.remove(p.file.docId);
                    } else {
                      _expanded.add(p.file.docId);
                    }
                  }),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: <Widget>[
                        Expanded(
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
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 6, vertical: 1),
                                      decoration: BoxDecoration(
                                          color: MoKit.warn(context)
                                              .withValues(alpha: 0.16),
                                          borderRadius: BorderRadius.circular(6)),
                                      child: Text('低置信',
                                          style: TextStyle(
                                              fontSize: 10,
                                              color: MoKit.warn(context))),
                                    ),
                                  Expanded(
                                    child: Text(p.note,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                            fontSize: MoKit.fsCaption,
                                            color: MoKit.sub(context))),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                            '${p.fields.where((PlanField f) => f.accepted).length} 项',
                            style: TextStyle(
                                fontSize: MoKit.fsCaption,
                                color: MoKit.sub(context))),
                        Icon(open ? Icons.expand_less : Icons.expand_more,
                            size: 18, color: MoKit.faint(context)),
                      ],
                    ),
                  ),
                ),
              ),
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
    final WriteReport report;
    try {
      report = await runner.write(_plans, control: control, batchId: batchId);
    } finally {
      TaskCenter.finish();
    }
    // 写成功的这些文件：缓存已清，但列表条目还是旧值。补读一次，回到列表
    // 就能看到刚写进去的标签（不补读的话仍显示「无标签」，要重扫才更新）。
    // 放到后台跑：几百首逐个读盘要几秒，不该卡着面板不放。
    if (report.files.isNotEmpty) {
      unawaited(Repo.instance.loadMeta(only: report.files));
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = report.summary();
    });
    // 提示条挂在 root overlay 上，pop 之后仍然在；但撤销确认面板需要一个还活着
    // 的 context——sheet 自己马上就要 pop，用 overlay 的 context（它比这条 modal
    // 路由活得久）才不会点了撤销反而报「deactivated widget's ancestor」。
    final BuildContext alive =
        Overlay.maybeOf(context, rootOverlay: true)?.context ?? context;
    moSnack(context, report.summary(),
        actionLabel: report.written == 0 ? null : '撤销',
        onAction: () async {
          final int? n = await undoBatchWithPreview(alive, batchId: batchId);
          if (n == null || !alive.mounted) return;
          moSnack(alive, n == 0 ? '没有可还原的改动' : '已撤销 $n 处改动');
        });
    Navigator.of(context).pop(true);
  }
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
