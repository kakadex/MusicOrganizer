/// 自绘标题栏（0.4.0 第三期，仅 Windows）。
///
/// 为什么自绘：系统标题栏占约 32dp 且样式无法统一（深色模式下标题栏是浅色
/// 白条，与深色界面割裂）。自绘后标题栏与页面同色、可放应用内元素，并省出
/// 一行空间。
///
/// 代价：拖动 / 最小化 / 最大化 / 关闭 / 边缘缩放全部自己实现——
/// 见 `platform/window_controls.dart` 与 `windows/runner/win32_window.cpp`。
///
/// 手机端不构造此组件（窗口概念不存在）。
library;

import 'package:flutter/material.dart';

import '../app/ui_kit.dart';
import 'window_controls.dart';

/// 自绘标题栏：左侧图标 + 标题，右侧是最小化 / 最大化 / 关闭。
///
/// [title] 显示应用名；[subtitle] 可放当前曲库数量之类的状态。
class CustomTitleBar extends StatefulWidget {
  const CustomTitleBar({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.actions,
  });

  final String title;
  final String? subtitle;

  /// 标题左侧的自定义按钮（如返回、菜单）。
  final Widget? leading;

  /// 标题右侧、窗口按钮左侧的额外按钮（如设置齿轮）。
  final List<Widget>? actions;

  /// 标题栏高度（逻辑像素）。系统默认约 32，这里取 36 让图标好点。
  static const double height = 36;

  @override
  State<CustomTitleBar> createState() => _CustomTitleBarState();
}

class _CustomTitleBarState extends State<CustomTitleBar> {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    WindowControls.isMaximized().then((bool v) {
      if (mounted) setState(() => _maximized = v);
    });
    WindowControls.listenMaximized((bool v) {
      if (mounted) setState(() => _maximized = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // 按下空白处拖动窗口；双击切换最大化（Windows 习惯）
      onPanStart: (_) => WindowControls.startDrag(),
      onDoubleTap: () => WindowControls.toggleMaximize(),
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: CustomTitleBar.height,
        color: MoKit.bg(context),
        child: Row(
          children: <Widget>[
            if (widget.leading != null) widget.leading!,
            const SizedBox(width: 8),
            // 标题 + 副标题（副标题用浅色小字）
            Expanded(
              child: Row(
                children: <Widget>[
                  Text(
                    widget.title,
                    style: TextStyle(
                      fontSize: MoKit.fsBody,
                      fontWeight: FontWeight.w600,
                      color: MoKit.text(context),
                    ),
                  ),
                  if (widget.subtitle != null) ...<Widget>[
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        widget.subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: MoKit.fsCaption,
                          color: MoKit.faint(context),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (widget.actions != null) ...widget.actions!,
            const SizedBox(width: 4),
            // 窗口按钮：**不用字体图标，用 CustomPaint 手绘**。
            //
            // 踩过的坑：Icons.remove / Icons.crop_square / Icons.filter_none
            // 在 Windows release 构建里图标字体 tree-shaking 后字形没进包，
            // 按钮位置一片空白（真机截图确认，换成 Icons.minimize/fullscreen
            // 也一样）。手绘线条是最可靠的——不依赖任何图标字体。
            _windowButton(
              tooltip: '最小化',
              onTap: WindowControls.minimize,
              painter: _MinimizePainter(MoKit.text(context)),
            ),
            _windowButton(
              tooltip: _maximized ? '向下还原' : '最大化',
              onTap: WindowControls.toggleMaximize,
              painter: _maximized
                  ? _RestorePainter(MoKit.text(context))
                  : _MaximizePainter(MoKit.text(context)),
            ),
            _windowButton(
              tooltip: '关闭',
              onTap: WindowControls.close,
              danger: true,
              painter: _ClosePainter(MoKit.text(context)),
            ),
          ],
        ),
      ),
    );
  }

  /// 窗口控制按钮（手绘图形，无字体图标依赖）。
  Widget _windowButton({
    required String tooltip,
    required VoidCallback onTap,
    required CustomPainter painter,
    bool danger = false,
  }) {
    return _HoverButton(
      tooltip: tooltip,
      onTap: onTap,
      danger: danger,
      child: CustomPaint(size: const Size(12, 12), painter: painter),
    );
  }
}

/// 最小化：一条横线。
class _MinimizePainter extends CustomPainter {
  _MinimizePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint p = Paint()
      ..color = color
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    final double y = size.height / 2;
    canvas.drawLine(Offset(1, y), Offset(size.width - 1, y), p);
  }

  @override
  bool shouldRepaint(_MinimizePainter old) => old.color != color;
}

/// 最大化：一个方框。
class _MaximizePainter extends CustomPainter {
  _MaximizePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint p = Paint()
      ..color = color
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    canvas.drawRect(
        Rect.fromLTWH(1, 1, size.width - 2, size.height - 2), p);
  }

  @override
  bool shouldRepaint(_MaximizePainter old) => old.color != color;
}

/// 还原（已最大化时）：两个叠起来的方框。
class _RestorePainter extends CustomPainter {
  _RestorePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint p = Paint()
      ..color = color
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    // 后框（右上偏移）+ 前框
    canvas.drawRect(Rect.fromLTWH(3, 1, size.width - 4, size.height - 4), p);
    canvas.drawRect(Rect.fromLTWH(1, 3, size.width - 4, size.height - 4), p);
  }

  @override
  bool shouldRepaint(_RestorePainter old) => old.color != color;
}

/// 关闭：一个叉。
class _ClosePainter extends CustomPainter {
  _ClosePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint p = Paint()
      ..color = color
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    canvas.drawLine(const Offset(1, 1),
        Offset(size.width - 1, size.height - 1), p);
    canvas.drawLine(Offset(size.width - 1, 1),
        const Offset(1, 0) + Offset(0, size.height - 1), p);
  }

  @override
  bool shouldRepaint(_ClosePainter old) => old.color != color;
}

/// 悬停高亮按钮（标题栏窗口按钮用）。
///
/// 自己实现而不是用 IconButton：IconButton 有 48dp 最小点击区，会把标题栏
/// 撑高；这里固定 46×36，铺满标题栏高度，符合 Windows 窗口按钮的习惯。
class _HoverButton extends StatefulWidget {
  const _HoverButton({
    required this.child,
    required this.tooltip,
    required this.onTap,
    this.danger = false,
  });

  final Widget child;
  final String tooltip;
  final VoidCallback onTap;
  final bool danger;

  @override
  State<_HoverButton> createState() => _HoverButtonState();
}

class _HoverButtonState extends State<_HoverButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final Color bg = widget.danger
        ? (_hover ? const Color(0xFFE81123) : Colors.transparent)
        : (_hover ? MoKit.soft(context) : Colors.transparent);
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 46,
            height: CustomTitleBar.height,
            color: bg,
            alignment: Alignment.center,
            child: widget.danger && _hover
                ? IconTheme(
                    data: const IconThemeData(color: Colors.white),
                    child: widget.child,
                  )
                : widget.child,
          ),
        ),
      ),
    );
  }
}
