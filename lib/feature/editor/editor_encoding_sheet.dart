/// 编码修正面板：按候选编码重解乱码字段，预览后再决定写回。
///
/// 一个面板只回传「用哪种编码」，具体回填由编辑器执行 —— 页面仍是唯一
/// 持有输入框状态的地方，面板不直接改文本。
library;

import 'package:flutter/material.dart';

import '../../app/ui_kit.dart';
import 'encoding_fix.dart';

/// 某个字段在某种编码下的重解结果。
class FieldFix {
  const FieldFix({
    required this.key,
    required this.label,
    required this.before,
    required this.after,
  });

  /// 字段键（`Tags.keys`）。
  final String key;

  /// 字段中文名。
  final String label;

  /// 修正前（乱码）。
  final String before;

  /// 修正后。
  final String after;
}

/// 编辑器里的「检测到乱码」提示卡。
class EncodingFixHint extends StatelessWidget {
  const EncodingFixHint({super.key, required this.count, required this.onFix});

  /// 疑似乱码的字段数。
  final int count;

  final VoidCallback onFix;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: '检测到疑似乱码',
      subtitle: '$count 个字段的字符都落在单字节区，可尝试按原编码重解',
      children: <Widget>[
        Align(
          alignment: Alignment.centerLeft,
          child: MoButton('编码修正',
              primary: false, icon: Icons.translate, onPressed: onFix),
        ),
      ],
    );
  }
}

/// 编码修正面板。
abstract final class EncodingFixSheet {
  /// 弹出面板；返回选中的编码，取消返回 null。
  static Future<String?> show(
      BuildContext context, Map<String, List<FieldFix>> byCharset) {
    return showMoSheet<String>(
      context,
      title: '编码修正',
      children: <Widget>[_Body(byCharset: byCharset)],
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.byCharset});

  final Map<String, List<FieldFix>> byCharset;

  @override
  Widget build(BuildContext context) {
    final List<String> order = EncodingFix.charsets
        .where((String c) => byCharset.containsKey(c))
        .toList();
    if (order.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(MoKit.pagePad),
        child: Text('这段文本按 UTF-8 / GBK / Big5 都解不出可读内容',
            style: TextStyle(fontSize: MoKit.fsBody, color: MoKit.sub(context))),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 0, MoKit.pagePad, 8),
          child: Text('下面每种编码都只是「可能的解」，看清预览再选',
              style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
        ),
        for (final String charset in order) _card(context, charset),
      ],
    );
  }

  Widget _card(BuildContext context, String charset) {
    final List<FieldFix> fixes = byCharset[charset]!;
    return SectionCard(
      title: '按 $charset 重解',
      subtitle: '${fixes.length} 个字段',
      children: <Widget>[
        for (final FieldFix fix in fixes)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(fix.label,
                    style: TextStyle(
                        fontSize: MoKit.fsCaption, color: MoKit.faint(context))),
                const SizedBox(height: 2),
                Text(fix.before,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: MoKit.fsBody, color: MoKit.faint(context))),
                Text(fix.after,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: MoKit.fsTitle,
                        fontWeight: FontWeight.w500,
                        color: MoKit.text(context))),
              ],
            ),
          ),
        Align(
          alignment: Alignment.centerRight,
          child: MoButton('用 $charset 写入输入框',
              onPressed: () => Navigator.of(context).pop(charset)),
        ),
      ],
    );
  }
}
