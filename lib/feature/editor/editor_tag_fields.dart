/// 编辑器的七个字段输入框（标题 / 歌手 / 专辑 / 年份 / 音轨 / 流派 / 注释）。
///
/// 输入框状态仍由页面持有（保存时要和初始值逐项比较），这里只负责排版。
library;

import 'package:flutter/material.dart';

import '../../app/ui_kit.dart';
import '../../core/model/tags.dart';

/// 字段输入卡片。
class EditorTagFields extends StatelessWidget {
  const EditorTagFields({super.key, required this.controllers});

  /// 键为 `Tags.keys`，由页面创建与释放。
  final Map<String, TextEditingController> controllers;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: '标签',
      subtitle: '留空即清除该字段',
      children: <Widget>[
        for (final String key in Tags.keys) _field(context, key),
      ],
    );
  }

  Widget _field(BuildContext context, String key) {
    final TextEditingController? controller = controllers[key];
    if (controller == null) return const SizedBox.shrink();
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
        ],
      ),
    );
  }
}
