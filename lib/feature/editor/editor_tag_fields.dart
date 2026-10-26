/// 编辑器的字段输入（标题 / 歌手 / 专辑 / 年份 / 音轨 / 流派 / 注释 + 歌词）。
///
/// 输入框状态仍由页面持有（保存时要和初始值逐项比较），这里只负责排版：
/// 改过的字段右侧亮「● 已改」，点它单项回滚。
library;

import 'package:flutter/material.dart';

import '../../app/ui_kit.dart';
import '../../core/model/tags.dart';

/// 字段输入卡片。
class EditorTagFields extends StatelessWidget {
  const EditorTagFields({
    super.key,
    required this.controllers,
    required this.initial,
    this.lyricsController,
    this.onRevert,
    this.onClearLyrics,
  });

  /// 键为 `Tags.keys`，由页面创建与释放。
  final Map<String, TextEditingController> controllers;

  /// 打开时的标签值（用来判断「改过没」）。
  final Tags initial;

  /// 歌词输入框（单独一个控制器：歌词不进 [Tags.keys]，免得撑大撤销日志）。
  final TextEditingController? lyricsController;

  /// 单项回滚：把某个字段还原成打开时的值。
  final void Function(String key)? onRevert;

  /// 清除歌词。
  final VoidCallback? onClearLyrics;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SectionCard(
          title: '标签',
          subtitle: '留空即清除该字段',
          children: <Widget>[
            for (final String key in Tags.keys) _field(context, key),
          ],
        ),
        if (lyricsController != null)
          SectionCard(
            title: '歌词',
            subtitle: '留空即清除歌词',
            children: <Widget>[
              TextField(
                controller: lyricsController,
                maxLines: 6,
                minLines: 3,
                style: TextStyle(
                    fontSize: MoKit.fsBody, color: MoKit.text(context)),
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: MoKit.bg(context),
                  hintText: '（空）',
                  hintStyle: TextStyle(
                      fontSize: MoKit.fsBody, color: MoKit.faint(context)),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              if (onClearLyrics != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: MoButton('清除歌词', primary: false, onPressed: onClearLyrics),
                ),
            ],
          ),
      ],
    );
  }

  Widget _field(BuildContext context, String key) {
    final TextEditingController? controller = controllers[key];
    if (controller == null) return const SizedBox.shrink();
    final String now = controller.text.trim();
    final bool changed = now != initial.get(key).trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 56,
            child: Padding(
              padding: const EdgeInsets.only(top: 11),
              child: Text(Tags.labels[key] ?? key,
                  style: TextStyle(
                      fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
            ),
          ),
          Expanded(
            child: TextField(
              controller: controller,
              keyboardType: key == 'year' || key == 'track'
                  ? TextInputType.number
                  : TextInputType.text,
              style: TextStyle(
                  fontSize: MoKit.fsBody, color: MoKit.text(context)),
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: MoKit.bg(context),
                hintText: '（空）',
                hintStyle: TextStyle(
                    fontSize: MoKit.fsBody, color: MoKit.faint(context)),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          if (changed)
            Padding(
              padding: const EdgeInsets.only(left: 6, top: 9),
              child: GestureDetector(
                onTap: onRevert == null ? null : () => onRevert!(key),
                child: Tooltip(
                  message: '已改，点这里还原',
                  child: Text('● 已改',
                      style: TextStyle(
                          fontSize: 10, color: MoKit.warn(context))),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
