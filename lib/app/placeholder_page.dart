import 'package:flutter/material.dart';

import '../core/version.dart';
import 'router.dart';
import 'theme/theme_controller.dart';

/// Phase 0 占位页：标题 + 外观三态（跟随系统 / 浅色 / 深色）+ 首页功能导航。
class MoPlaceholderPage extends StatelessWidget {
  const MoPlaceholderPage({
    super.key,
    required this.title,
    required this.themeController,
    this.showNav = false,
  });

  /// 页面标题（AppBar 展示）。
  final String title;

  /// 主题状态源。
  final ThemeController themeController;

  /// 是否展示功能导航（仅首页）。
  final bool showNav;

  static const String _subtitle = 'Phase 0 骨架占位 —— 功能施工中';

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(_subtitle, style: textTheme.bodyMedium),
              const SizedBox(height: 4),
              Text('版本 $kAppVersionFull', style: textTheme.bodySmall),
              const SizedBox(height: 24),
              _ThemeSwitcher(themeController: themeController),
              if (showNav) ...<Widget>[
                const SizedBox(height: 24),
                const _NavSectionTitle(),
                for (final MapEntry<String, String> entry
                    in MoRouter.titles.entries)
                  if (entry.key != MoRoutes.home)
                    ListTile(
                      leading: const Icon(Icons.chevron_right),
                      title: Text(entry.value),
                      onTap: () =>
                          Navigator.of(context).pushNamed(entry.key),
                    ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 外观切换区：跟随系统 / 浅色 / 深色（0.3.17）。
class _ThemeSwitcher extends StatelessWidget {
  const _ThemeSwitcher({required this.themeController});

  final ThemeController themeController;

  @override
  Widget build(BuildContext context) {
    const List<(ThemeMode, String)> modes = <(ThemeMode, String)>[
      (ThemeMode.system, '跟随系统'),
      (ThemeMode.light, '浅色'),
      (ThemeMode.dark, '深色'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('外观', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: <Widget>[
            for (final (ThemeMode mode, String label) in modes)
              ChoiceChip(
                label: Text(label),
                selected: themeController.mode == mode,
                onSelected: (_) => themeController.setMode(mode),
              ),
          ],
        ),
      ],
    );
  }
}

/// 导航区小标题。
class _NavSectionTitle extends StatelessWidget {
  const _NavSectionTitle();

  @override
  Widget build(BuildContext context) {
    return Text('功能', style: Theme.of(context).textTheme.titleMedium);
  }
}
