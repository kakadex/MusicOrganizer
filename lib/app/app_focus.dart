import 'package:flutter/widgets.dart';

/// 全局焦点节点（跨页快捷键用）。
///
/// 为什么要一个全局槽位：Ctrl+F 是在壳层（MoShell）里接的，但输入框在曲库页里。
/// 把 FocusNode 提到这里，两边拿的是同一个对象，不用传一串回调。
abstract final class AppFocus {
  /// 曲库页的搜索输入框。
  static final FocusNode search = FocusNode(debugLabel: 'library-search');

  static void focusSearch() {
    if (!search.hasFocus) search.requestFocus();
  }

  static void unfocusAll() => FocusManager.instance.primaryFocus?.unfocus();
}
