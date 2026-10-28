/// 按域拆分的变更通知。
///
/// 原来 `Repo` 是一个 `ChangeNotifier`：扫描进度每跳一次、设置改一个开关，
/// 所有监听它的页面（曲库 / 整理 / 设置）都会整页重建。拆开之后，页面只
/// 订阅自己关心的域：
///
/// - [library]：曲目列表 / 扫描进度 / 缓存恢复；
/// - [root]：曲库目录的增删与授权状态；
/// - [settings]：设置项；
/// - [meta]：标签加载。
///
/// `Repo` 仍然保留整体通知（旧代码 / 新页面忘了订阅具体域时不会「不动」），
/// 但只要订阅了具体域，就不会被无关变更带着重建。
library;

import 'package:flutter/foundation.dart';

/// 变更域。
enum RepoDomain { library, root, settings, meta }

/// 单个域的通知源。
class _Domain extends ChangeNotifier {
  void emit() => notifyListeners();
}

/// 一组成员变更源。
class RepoChanges {
  final _Domain _library = _Domain();
  final _Domain _root = _Domain();
  final _Domain _settings = _Domain();
  final _Domain _meta = _Domain();

  /// 曲目列表 / 扫描进度。
  Listenable get library => _library;

  /// 曲库目录与授权状态。
  Listenable get root => _root;

  /// 设置项。
  Listenable get settings => _settings;

  /// 标签加载。
  Listenable get meta => _meta;

  /// 发一次对应域的通知。
  void emit(RepoDomain domain) {
    switch (domain) {
      case RepoDomain.library:
        _library.emit();
      case RepoDomain.root:
        _root.emit();
      case RepoDomain.settings:
        _settings.emit();
      case RepoDomain.meta:
        _meta.emit();
    }
  }

  /// 同时关心多个域时用（例如整理页要跟着目录和曲目一起刷新）。
  Listenable of(Iterable<RepoDomain> domains) {
    final List<Listenable> list = <Listenable>[
      for (final RepoDomain d in domains)
        switch (d) {
          RepoDomain.library => _library,
          RepoDomain.root => _root,
          RepoDomain.settings => _settings,
          RepoDomain.meta => _meta,
        },
    ];
    return Listenable.merge(list);
  }

  /// 进程退出时释放（单例，实际很少用到，测试里需要）。
  void dispose() {
    _library.dispose();
    _root.dispose();
    _settings.dispose();
    _meta.dispose();
  }
}
