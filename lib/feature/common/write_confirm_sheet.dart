/// 统一写入确认面板：写盘前的最后一道闸。
///
/// 项目硬约束：**任何落盘操作都必须先在这里列清楚「改了什么」，由用户逐项勾选**。
/// 面板不认识业务，只看 [WriteTarget] / [WriteLine]；真正的写盘由调用方在拿到
/// 返回值之后执行，因此它是纯展示 + 勾选，不碰文件系统。
///
/// 布局要点：**底部确认按钮必须固定可见**。早前把「列表 + 按钮」一起塞进
/// 外层滚动容器，条目一多按钮就被顶出屏幕，手指又被内层列表吞掉滚不动，
/// 表现就是「预览出来了但没法确认」。
library;

import 'package:flutter/material.dart';

import '../../app/ui_kit.dart';
import '../../core/tx/write_preview.dart';

/// 写入前确认。
abstract final class WriteConfirmSheet {
  /// 弹出确认面板。
  ///
  /// 返回用户勾选后的 [WriteTarget] 列表（**取消返回 null**，一项都没勾返回空列表）。
  /// 调用方只写返回的这批。
  static Future<List<WriteTarget>?> show(
    BuildContext context, {
    required String title,
    required List<WriteTarget> targets,
    String? subtitle,
    String? warning,
    String commitLabel = '写入',
    String unit = '项',
    String verb = '写入',
    bool expandAll = false,
  }) {
    return showModalBottomSheet<List<WriteTarget>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: MoKit.bg(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (BuildContext ctx) => _Body(
        title: title,
        targets: targets,
        subtitle: subtitle,
        warning: warning,
        commitLabel: commitLabel,
        unit: unit,
        verb: verb,
        expandAll: expandAll,
      ),
    );
  }
}

class _Body extends StatefulWidget {
  const _Body({
    required this.title,
    required this.targets,
    required this.commitLabel,
    required this.unit,
    required this.verb,
    required this.expandAll,
    this.subtitle,
    this.warning,
  });

  final String title;
  final List<WriteTarget> targets;
  final String? subtitle;
  final String? warning;
  final String commitLabel;
  final String unit;
  final String verb;
  final bool expandAll;

  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> {
  late final List<WriteTarget> _items = List<WriteTarget>.of(widget.targets);
  late final Set<String> _expanded = <String>{
    if (widget.expandAll) for (final WriteTarget t in _items) t.docId,
  };

  int get _pending =>
      _items.where((WriteTarget t) => t.selected && t.hasChange).length;

  @override
  Widget build(BuildContext context) {
    final int total = _items.length;
    final int low = _items
        .where((WriteTarget t) => t.selected && t.hasChange && t.lowConfidence)
        .length;
    final int risky =
        _items.where((WriteTarget t) => t.selected && t.risky).length;

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        // 留出顶部一点空间，避免面板顶到状态栏
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.9),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // 顶部把手 + 标题 + 关闭
            Padding(
              padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 10, 8, 2),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(widget.title,
                        style: TextStyle(
                            fontSize: MoKit.fsPage,
                            fontWeight: FontWeight.w600,
                            color: MoKit.text(context))),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.of(context).pop(null),
                  ),
                ],
              ),
            ),
            // 说明（固定，不随列表滚动）
            Padding(
              padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 0, MoKit.pagePad, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  if (widget.subtitle != null && widget.subtitle!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(widget.subtitle!,
                          style: TextStyle(
                              fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
                    ),
                  if (widget.warning != null && widget.warning!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(widget.warning!,
                          style: TextStyle(
                              fontSize: MoKit.fsCaption, color: MoKit.err(context))),
                    ),
                  Text(
                    '共 $total ${widget.unit}，已选 $_pending ${widget.unit}'
                    '${low > 0 ? '，其中 $low ${widget.unit}来自低置信结果' : ''}'
                    '${risky > 0 ? '，$risky ${widget.unit}为删除/覆盖类操作' : ''}',
                    style: TextStyle(
                        fontSize: MoKit.fsBody, color: MoKit.text(context)),
                  ),
                ],
              ),
            ),
            if (total > 1)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: MoKit.pagePad - 8),
                child: Row(
                  children: <Widget>[
                    TextButton(
                      onPressed: () =>
                          setState(() => WritePreview.setAll(_items, true)),
                      child: const Text('全选'),
                    ),
                    TextButton(
                      onPressed: () =>
                          setState(() => WritePreview.setAll(_items, false)),
                      child: const Text('全不选'),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () => setState(() {
                        for (final WriteTarget t in _items) {
                          if (t.lowConfidence) t.selected = false;
                        }
                      }),
                      child: const Text('不选低置信'),
                    ),
                  ],
                ),
              ),
            const Divider(height: 1),
            // 列表：唯一可滚动的区域，占满剩余高度
            Flexible(
              child: ListView.builder(
                padding: const EdgeInsets.only(top: 8, bottom: 8),
                itemCount: _items.length,
                itemBuilder: (BuildContext ctx, int i) => _card(ctx, _items[i]),
              ),
            ),
            // 底部按钮：固定在面板底部，永远点得到
            Container(
              decoration: BoxDecoration(
                color: MoKit.bg(context),
                border: Border(top: BorderSide(color: MoKit.line(context))),
              ),
              padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 8, MoKit.pagePad, 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (_pending == 0)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        children: <Widget>[
                          Icon(Icons.info_outline,
                              size: 14, color: MoKit.warn(context)),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text('没有勾选任何变更，先在上面勾选要写的项',
                                style: TextStyle(
                                    fontSize: MoKit.fsCaption,
                                    color: MoKit.warn(context))),
                          ),
                        ],
                      ),
                    ),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: MoButton('取消',
                            primary: false,
                            onPressed: () => Navigator.of(context).pop(null)),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: MoButton(
                          _pending == 0
                              ? widget.commitLabel
                              : '${widget.commitLabel} $_pending ${widget.unit}',
                          onPressed: _pending == 0
                              ? null
                              : () => Navigator.of(context)
                                  .pop(WritePreview.onlySelected(_items)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _card(BuildContext context, WriteTarget t) {
    final bool open = _expanded.contains(t.docId);
    final Color accent = t.risky
        ? MoKit.err(context)
        : (t.lowConfidence ? MoKit.warn(context) : MoKit.primary(context));
    return Container(
      margin: const EdgeInsets.fromLTRB(MoKit.pagePad, 0, MoKit.pagePad, 8),
      decoration: BoxDecoration(
        color: MoKit.card(context),
        borderRadius: BorderRadius.circular(MoKit.radiusRow),
        border: Border.all(color: MoKit.line(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Checkbox(
                value: t.selected,
                visualDensity: VisualDensity.compact,
                onChanged: (bool? v) =>
                    setState(() => t.selected = v == true),
              ),
              Expanded(
                child: InkWell(
                  onTap: () => setState(() {
                    if (open) {
                      _expanded.remove(t.docId);
                    } else {
                      _expanded.add(t.docId);
                    }
                  }),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(t.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: MoKit.fsBody,
                                fontWeight: FontWeight.w500,
                                color: MoKit.text(context))),
                        if (t.path.isNotEmpty)
                          Text(t.path,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: MoKit.fsCaption,
                                  color: MoKit.sub(context))),
                        if (t.note.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(t.note,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: MoKit.fsCaption, color: accent)),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              Icon(open ? Icons.expand_less : Icons.expand_more,
                  size: 18, color: MoKit.sub(context)),
              const SizedBox(width: 6),
            ],
          ),
          if (open)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Divider(height: 1),
                  for (final WriteLine l in t.lines) _line(context, t, l),
                  if (t.lines.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text('这一项没有可显示的字段变更（可能已经是目标状态）',
                          style: TextStyle(
                              fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _line(BuildContext context, WriteTarget t, WriteLine l) {
    final bool dim = !l.changed;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Checkbox(
          value: l.selected,
          visualDensity: VisualDensity.compact,
          onChanged: (bool? v) =>
              setState(() => l.selected = v == true),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 11),
            child: RichText(
              text: TextSpan(
                style: TextStyle(
                  fontSize: MoKit.fsCaption,
                  color: dim ? MoKit.faint(context) : MoKit.text(context),
                ),
                children: <TextSpan>[
                  TextSpan(
                      text: '${l.label}：',
                      style: TextStyle(color: MoKit.sub(context))),
                  TextSpan(
                    text: l.oldShown,
                    style: TextStyle(
                      decoration: l.changed ? TextDecoration.lineThrough : null,
                      decorationColor: MoKit.faint(context),
                    ),
                  ),
                  if (l.changed) ...<TextSpan>[
                    const TextSpan(text: '  →  '),
                    TextSpan(
                      text: l.newShown,
                      style: TextStyle(
                        color: t.risky
                            ? MoKit.err(context)
                            : MoKit.primary(context),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ] else
                    const TextSpan(text: '（未变）'),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
