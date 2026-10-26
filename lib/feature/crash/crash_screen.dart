/// 崩溃页：出问题时把错误说清楚，并给出「复制堆栈」与「返回首页」。
///
/// 堆栈只显示函数名与错误信息 —— 本机路径一律不进界面（也不进日志）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/ui_kit.dart';
import '../../core/log/log.dart';

/// 崩溃页。
class CrashScreen extends StatelessWidget {
  const CrashScreen({super.key, required this.error, this.stack});

  /// 错误信息（已清理过路径）。
  final String error;

  /// 堆栈（可空）。
  final StackTrace? stack;

  /// 记录并打开崩溃页（全局错误处理用）。
  static void report(Object error, StackTrace? stack) {
    Log.error('未捕获异常', e: error, stack: stack);
    final String text = Log.sanitize('$error');
    final String frames = stack == null
        ? ''
        : Log.sanitize(stack.toString())
            .split('\n')
            .where((String l) => l.trim().isNotEmpty)
            .take(12)
            .join('\n');
    _navigatorKey.currentState?.push<void>(MaterialPageRoute<void>(
      builder: (BuildContext _) =>
          CrashScreen(error: text, stack: stack == null ? null : StackTrace.fromString(frames)),
    ));
  }

  /// 全局导航钥匙（崩溃页要能盖在任何界面上）。
  static final GlobalKey<NavigatorState> _navigatorKey =
      GlobalKey<NavigatorState>();

  /// 供 [MaterialApp] 使用的导航钥匙。
  static GlobalKey<NavigatorState> get navigatorKey => _navigatorKey;

  @override
  Widget build(BuildContext context) {
    final String frames = stack == null ? '' : Log.sanitize(stack.toString());
    return Scaffold(
      appBar: AppBar(
        title: const Text('出错了'),
        leading: IconButton(
          tooltip: '返回首页',
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(MoKit.pagePad),
          children: <Widget>[
            Text('应用遇到了一个错误，已记进日志。',
                style: TextStyle(
                    fontSize: MoKit.fsBody, color: MoKit.text(context))),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: MoKit.card(context),
                borderRadius: BorderRadius.circular(10),
              ),
              child: SelectableText(
                frames.isEmpty ? error : '$error\n\n$frames',
                style: TextStyle(
                    fontSize: MoKit.fsCaption, color: MoKit.text(context)),
              ),
            ),
            const SizedBox(height: 16),
            MoButton('复制错误信息', primary: false,
                onPressed: () => _copy(context)),
            const SizedBox(height: 8),
            MoButton('返回首页', onPressed: () => Navigator.of(context).maybePop()),
          ],
        ),
      ),
    );
  }

  Future<void> _copy(BuildContext context) async {
    final String frames = stack == null ? '' : Log.sanitize(stack.toString());
    await Clipboard.setData(ClipboardData(text: '$error\n\n$frames'));
    if (!context.mounted) return;
    moSnack(context, '已复制');
  }
}
