import 'package:flutter/material.dart';

import '../../app/ui_kit.dart';
import '../../core/version.dart';
import '../health/health_page.dart';
import '../history/history_page.dart';
import 'update_sheet.dart';

/// 设置页（最小落位）：版本信息 + 维护入口。
///
/// 主题 / 端点覆盖 / 备份等设置项由设置功能负责人继续补，这里先把
/// 「检查更新 / 撤销历史 / 体检与导出」三个入口接上，避免入口悬空。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        PageHeader(title: '设置', subtitle: '版本 $kAppVersionFull'),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 16),
            children: <Widget>[
              SectionCard(
                title: '维护',
                children: <Widget>[
                  MoTile(
                    title: '检查更新',
                    subtitle: 'Gitee 优先，GitHub 兜底',
                    icon: Icons.system_update_alt,
                    onTap: () => UpdateSheet.show(context),
                  ),
                  MoTile(
                    title: '撤销历史',
                    subtitle: '按批次回退已写入的标签',
                    icon: Icons.history,
                    onTap: () => _push(context, const HistoryPage()),
                  ),
                  MoTile(
                    title: '体检 / CSV',
                    subtitle: '统计缺项，导出曲库清单',
                    icon: Icons.monitor_heart_outlined,
                    onTap: () => _push(context, const HealthPage()),
                  ),
                ],
              ),
              SectionCard(
                title: '关于',
                children: <Widget>[
                  MoTile(
                    title: '当前版本',
                    subtitle: kAppVersionFull,
                    icon: Icons.info_outline,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (BuildContext _) => page),
    );
  }
}
