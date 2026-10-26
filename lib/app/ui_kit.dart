import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/model/task_control.dart';
import '../core/task/task_center.dart';

/// 设计常量与通用组件。
///
/// 三条视觉纪律（改版就是照这三条改）：
/// 1. **不靠描边分层**：卡片用比页面更亮的底色 + 大圆角，不用 1px 边框（满屏灰线最显廉价）；
/// 2. **字号只有 5 档**：11 辅助 / 13 正文 / 15 标题 / 17 页标题 / 22 大标题；
/// 3. **主色只给主操作与选中态**，其余一律次级文字色。
abstract final class MoKit {
  // ---- 尺寸 ----
  static const double radiusCard = 16;
  static const double radiusRow = 12;
  static const double gap = 12;
  static const double pagePad = 16;
  static const double rowHeight = 64;

  // ---- 字阶 ----
  static const double fsCaption = 11;
  static const double fsBody = 13;
  static const double fsTitle = 15;
  static const double fsPage = 17;
  static const double fsHuge = 22;

  // ---- 颜色 ----
  static Color bg(BuildContext c) => Theme.of(c).scaffoldBackgroundColor;
  static Color card(BuildContext c) => Theme.of(c).colorScheme.surface;
  static Color text(BuildContext c) => Theme.of(c).colorScheme.onSurface;
  static Color primary(BuildContext c) => Theme.of(c).colorScheme.primary;
  static Color sub(BuildContext c) =>
      Theme.of(c).colorScheme.onSurface.withValues(alpha: 0.60);
  static Color faint(BuildContext c) =>
      Theme.of(c).colorScheme.onSurface.withValues(alpha: 0.40);
  static Color line(BuildContext c) =>
      Theme.of(c).colorScheme.onSurface.withValues(alpha: 0.08);
  static Color soft(BuildContext c) =>
      Theme.of(c).colorScheme.primary.withValues(alpha: 0.12);
  static Color ok(BuildContext c) => const Color(0xFF2E9E5B);
  static Color warn(BuildContext c) => const Color(0xFFD98324);
  static Color err(BuildContext c) => Theme.of(c).colorScheme.error;
}

/// 页面标题（大标题 + 一行说明）。
class PageHeader extends StatelessWidget {
  const PageHeader({super.key, required this.title, this.subtitle, this.actions});

  final String title;
  final String? subtitle;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 14, MoKit.pagePad, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title,
                    style: TextStyle(
                        fontSize: MoKit.fsHuge,
                        fontWeight: FontWeight.w600,
                        color: MoKit.text(context))),
                if (subtitle != null && subtitle!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(subtitle!,
                        style: TextStyle(
                            fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
                  ),
              ],
            ),
          ),
          ...?actions,
        ],
      ),
    );
  }
}

/// 卡片：无描边、大圆角、可选标题与右侧动作。
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    this.title,
    this.subtitle,
    this.trailing,
    required this.children,
    this.padding = const EdgeInsets.all(14),
  });

  final String? title;
  final String? subtitle;
  final Widget? trailing;
  final List<Widget> children;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(MoKit.pagePad, 0, MoKit.pagePad, MoKit.gap),
      padding: padding,
      decoration: BoxDecoration(
        color: MoKit.card(context),
        borderRadius: BorderRadius.circular(MoKit.radiusCard),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (title != null)
            Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(title!,
                          style: TextStyle(
                              fontSize: MoKit.fsTitle,
                              fontWeight: FontWeight.w600,
                              color: MoKit.text(context))),
                      if (subtitle != null && subtitle!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(subtitle!,
                              style: TextStyle(
                                  fontSize: MoKit.fsCaption,
                                  color: MoKit.sub(context))),
                        ),
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
          if (title != null) const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }
}

/// 一行设置项：图标 + 标题 + 副标题 + 右侧。
class MoTile extends StatelessWidget {
  const MoTile({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.trailing,
    this.onTap,
    this.danger = false,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final Color fg = danger ? MoKit.err(context) : MoKit.text(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(MoKit.radiusRow),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          children: <Widget>[
            if (icon != null)
              Container(
                width: 34,
                height: 34,
                margin: const EdgeInsets.only(right: 12),
                decoration: BoxDecoration(
                  color: danger ? MoKit.err(context).withValues(alpha: 0.10) : MoKit.soft(context),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 18, color: danger ? MoKit.err(context) : MoKit.primary(context)),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title,
                      style: TextStyle(
                          fontSize: MoKit.fsTitle, fontWeight: FontWeight.w500, color: fg)),
                  if (subtitle != null && subtitle!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(subtitle!,
                          style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
                    ),
                ],
              ),
            ),
            ?trailing,
            if (onTap != null)
              Icon(Icons.chevron_right, size: 18, color: MoKit.faint(context)),
          ],
        ),
      ),
    );
  }
}

/// 封面方块（48dp，圆角 8，无图时显示音符占位）。
class CoverBox extends StatelessWidget {
  const CoverBox({super.key, this.bytes, this.size = 46});

  final Uint8List? bytes;
  final double size;

  @override
  Widget build(BuildContext context) {
    // 按实际显示尺寸解码：封面原图常见 500~1000px，若按全分辨率解到 46dp 的格子里，
    // 快速滑动时会反复分配大块内存触发 GC，是卡顿的主因。这里给定 cacheWidth/Height，
    // 让引擎只解到「显示像素」大小（含设备像素比）。
    final double dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
    final int cachePx = (size * dpr).round().clamp(1, 4096).toInt();
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: size,
        height: size,
        color: MoKit.line(context),
        child: bytes == null
            ? Icon(Icons.music_note, size: size * 0.42, color: MoKit.faint(context))
            : Image.memory(bytes!,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                cacheWidth: cachePx,
                cacheHeight: cachePx),
      ),
    );
  }
}

/// 带命中高亮的文本：检索词用主色加粗标出（没命中就按原样显示）。
///
/// [terms] 是原始检索词（大小写不敏感）。高亮只影响显示，不影响匹配。
Widget highlightText(
  String text,
  List<String> terms,
  TextStyle style, {
  required Color highlightColor,
  FontWeight? highlightWeight,
}) {
  if (text.isEmpty || terms.isEmpty) {
    return Text(text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style);
  }
  final String lower = text.toLowerCase();
  final List<bool> hit = List<bool>.filled(text.length, false);
  for (final String raw in terms) {
    final String term = raw.trim().toLowerCase();
    if (term.isEmpty) continue;
    int from = 0;
    while (true) {
      final int idx = lower.indexOf(term, from);
      if (idx < 0) break;
      for (int i = idx; i < idx + term.length && i < hit.length; i++) {
        hit[i] = true;
      }
      from = idx + term.length;
    }
  }
  if (!hit.any((bool b) => b)) {
    return Text(text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style);
  }
  final Color hl = highlightColor;
  final List<InlineSpan> spans = <InlineSpan>[];
  // 按「连续命中 / 连续未命中」切段：每段用它自己的状态决定样式
  // （不能用当前位置的状态 —— 整段命中时末尾那次判定会取到 false）。
  int start = 0;
  bool cur = hit[0];
  for (int i = 1; i <= hit.length; i++) {
    final bool on = i < hit.length && hit[i];
    if (i == hit.length || on != cur) {
      final String part = text.substring(start, i);
      spans.add(cur
          ? TextSpan(
              text: part,
              style: style.copyWith(
                  color: hl, fontWeight: highlightWeight ?? FontWeight.w700))
          : TextSpan(text: part, style: style));
      start = i;
      cur = on;
    }
  }
  return Text.rich(TextSpan(children: spans),
      maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
}

/// 曲目行：封面 + 两行文字 + 右侧尾部控件（默认显示时长）。
class SongRow extends StatelessWidget {
  const SongRow({
    super.key,
    required this.title,
    required this.subtitle,
    this.cover,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.selected = false,
    this.selectionMode = false,
    this.highlight = false,
    this.terms = const <String>[],
  });

  final String title;
  final String subtitle;
  final Uint8List? cover;
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool selected;
  final bool selectionMode;

  /// 标题未命中标签时用次级色（一眼看出哪些还没整理）。
  final bool highlight;

  /// 检索命中词（为空不高亮）。
  final List<String> terms;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(MoKit.radiusRow),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? MoKit.soft(context) : null,
          borderRadius: BorderRadius.circular(MoKit.radiusRow),
        ),
        child: Row(
          children: <Widget>[
            if (selectionMode)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(
                  selected ? Icons.check_circle : Icons.radio_button_unchecked,
                  size: 20,
                  color: selected ? MoKit.primary(context) : MoKit.faint(context),
                ),
              ),
            CoverBox(bytes: cover),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  highlightText(
                    title,
                    terms,
                    TextStyle(
                      fontSize: MoKit.fsTitle,
                      fontWeight: FontWeight.w500,
                      color: highlight ? MoKit.sub(context) : MoKit.text(context),
                    ),
                    highlightColor: MoKit.primary(context),
                  ),
                  const SizedBox(height: 2),
                  highlightText(
                    subtitle,
                    terms,
                    TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context)),
                    highlightColor: MoKit.primary(context),
                  ),
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// 筛选 chip（选中 = 主色底，未选 = 次级底）。
class MoChip extends StatelessWidget {
  const MoChip({super.key, required this.label, this.selected = false, this.onTap});

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? MoKit.primary(context) : MoKit.card(context),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: MoKit.fsBody,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected
                    ? Theme.of(context).colorScheme.onPrimary
                    : MoKit.sub(context))),
      ),
    );
  }
}

/// 主按钮 / 次按钮。
class MoButton extends StatelessWidget {
  const MoButton(this.label,
      {super.key, this.onPressed, this.primary = true, this.icon, this.busy = false});

  final String label;
  final VoidCallback? onPressed;
  final bool primary;
  final IconData? icon;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final bool enabled = onPressed != null && !busy;
    final Color fg = primary ? Theme.of(context).colorScheme.onPrimary : MoKit.text(context);
    return Material(
      color: primary ? MoKit.primary(context) : MoKit.soft(context),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: enabled ? onPressed : null,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          height: 42,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              if (busy)
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(fg)),
                )
              else if (icon != null)
                Icon(icon, size: 17, color: fg),
              if (busy || icon != null) const SizedBox(width: 7),
              Text(label,
                  style: TextStyle(
                      fontSize: MoKit.fsBody,
                      fontWeight: FontWeight.w600,
                      color: enabled ? fg : fg.withValues(alpha: 0.5))),
            ],
          ),
        ),
      ),
    );
  }
}

/// 空状态：图标 + 一行原因 + 可选主操作。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.text,
    this.hint,
    this.action,
  });

  final IconData icon;
  final String text;
  final String? hint;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 44, color: MoKit.faint(context)),
            const SizedBox(height: 12),
            Text(text,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: MoKit.fsTitle, color: MoKit.text(context))),
            if (hint != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(hint!,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
              ),
            if (action != null)
              Padding(padding: const EdgeInsets.only(top: 16), child: action!),
          ],
        ),
      ),
    );
  }
}

/// 底部面板（统一圆角与拖拽条）。
Future<T?> showMoSheet<T>(
  BuildContext context, {
  required String title,
  required List<Widget> children,
  String? actionLabel,
  VoidCallback? onAction,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: MoKit.bg(context),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (BuildContext ctx) {
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.82),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(top: 10, bottom: 8),
                decoration: BoxDecoration(
                    color: MoKit.line(ctx), borderRadius: BorderRadius.circular(2)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 4, MoKit.pagePad, 8),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(title,
                          style: TextStyle(
                              fontSize: MoKit.fsPage,
                              fontWeight: FontWeight.w600,
                              color: MoKit.text(ctx))),
                    ),
                    if (actionLabel != null)
                      TextButton(onPressed: onAction, child: Text(actionLabel)),
                  ],
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 16),
                  children: children,
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// 轻提示（带可选操作，用于「写入成功 · 撤销」）。
void moSnack(BuildContext context, String message,
    {String? actionLabel, VoidCallback? onAction}) {
  final ScaffoldMessengerState m = ScaffoldMessenger.of(context);
  m.hideCurrentSnackBar();
  m.showSnackBar(SnackBar(
    content: Text(message, style: const TextStyle(fontSize: MoKit.fsBody)),
    behavior: SnackBarBehavior.floating,
    margin: const EdgeInsets.all(12),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    action: actionLabel == null
        ? null
        : SnackBarAction(label: actionLabel, onPressed: onAction ?? () {}),
  ));
}

/// 任务条：**只在有任务时出现**，结束 1.2 秒后自动隐藏。
///
/// 只在有任务时出现：常驻一条「就绪」会白占 40dp，还会让列表跟着抖。
class TaskBar extends StatefulWidget {
  const TaskBar({super.key});

  @override
  State<TaskBar> createState() => _TaskBarState();
}

class _TaskBarState extends State<TaskBar> {
  Timer? _timer;
  RunningTask? _task;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 300), (_) => _poll());
  }

  void _poll() {
    final RunningTask? t = TaskCenter.current();
    if (!mounted) return;
    if (t != null) {
      setState(() {
        _task = t;
        _visible = true;
      });
    } else if (_visible) {
      // 任务刚结束：留一小会儿让人看到结果，然后收起
      setState(() => _visible = false);
      _task = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final RunningTask? t = _task;
    if (!_visible || t == null) return const SizedBox.shrink();
    final TaskControl c = t.control;
    final int pct = c.percent();
    return Container(
      padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 8, MoKit.pagePad, 8),
      color: MoKit.card(context),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text('${t.title} · ${c.summary()}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
              ),
              _tiny(context, c.isPaused() ? '继续' : '暂停', () {
                TaskCenter.togglePause();
              }),
              const SizedBox(width: 6),
              _tiny(context, '停止', () {
                TaskCenter.cancel();
              }),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: pct < 0 ? null : pct / 100.0,
              minHeight: 3,
              backgroundColor: MoKit.line(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tiny(BuildContext context, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
            color: MoKit.soft(context), borderRadius: BorderRadius.circular(999)),
        child: Text(label,
            style: TextStyle(
                fontSize: MoKit.fsCaption,
                fontWeight: FontWeight.w600,
                color: MoKit.primary(context))),
      ),
    );
  }
}
