import 'package:flutter/material.dart';

import 'placeholder_page.dart';
import 'theme/theme_controller.dart';

/// 路由表（Phase 0 占位路由；feature 页面自  起落位）。
abstract final class MoRoutes {
  /// 首页（曲库入口 + 主题切换演示）。
  static const String home = '/';

  /// 曲库浏览。
  static const String library = '/library';

  /// 整理。
  static const String organize = '/organize';

  /// 批量标签。
  static const String tagBatch = '/tag_batch';

  /// 批量歌词。
  static const String lyricsBatch = '/lyrics_batch';

  /// 封面批量。
  static const String covers = '/covers';

  /// 单文件编辑器。
  static const String editor = '/editor';

  /// 撤销历史。
  static const String history = '/history';

  /// 体检 / CSV。
  static const String health = '/health';

  /// 设置。
  static const String settings = '/settings';
}

/// 路由生成器：所有 feature 暂由同一占位页承载，首页附功能导航。
abstract final class MoRouter {
  /// 路由 → 页面标题（插入序即首页导航序）。
  static const Map<String, String> titles = <String, String>{
    MoRoutes.home: 'MusicOrganizer',
    MoRoutes.library: '曲库浏览',
    MoRoutes.organize: '整理',
    MoRoutes.tagBatch: '批量标签',
    MoRoutes.lyricsBatch: '批量歌词',
    MoRoutes.covers: '封面批量',
    MoRoutes.editor: '单文件编辑器',
    MoRoutes.history: '撤销历史',
    MoRoutes.health: '体检 / CSV',
    MoRoutes.settings: '设置',
  };

  /// 生成占位路由；未知路径同样落入占位页（避免白屏）。
  static Route<dynamic> onGenerateRoute(
      RouteSettings settings, ThemeController themeController) {
    final String route = settings.name ?? MoRoutes.home;
    final String title = titles[route] ?? titles[MoRoutes.home]!;
    return MaterialPageRoute<void>(
      builder: (BuildContext context) => MoPlaceholderPage(
        title: title,
        themeController: themeController,
        showNav: route == MoRoutes.home,
      ),
    );
  }
}
