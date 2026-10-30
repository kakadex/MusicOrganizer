import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/repo.dart';
import '../../app/ui_kit.dart';
import '../../core/source/endpoints.dart';
import '../../core/version.dart';
import 'update_sheet.dart';

/// 「关于」独立页：版本、检查更新、静默更新开关、下载入口。
///
/// 2026-10-30 从设置页主列表里拆出来 —— 这些内容全是「偶尔看一眼」的，
/// 和曲库目录 / 匹配策略放在同一屏会把常用设置挤下去。
class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  Repo get _repo => Repo.instance;

  @override
  Widget build(BuildContext context) {
    final bool silent =
        _repo.settings.get<bool>('update_silent', fallback: true) ?? true;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: <Widget>[
            PageHeader(
              title: '关于',
              subtitle: kAppVersionFull,
              leading: IconButton(
                tooltip: '返回',
                icon: Icon(Icons.arrow_back,
                    size: 20, color: MoKit.text(context)),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 16),
                children: <Widget>[
                  SectionCard(
                    title: '更新',
                    children: <Widget>[
                      MoTile(
                        title: '检查更新',
                        subtitle: 'Gitee 优先，GitHub 兜底',
                        icon: Icons.system_update_alt,
                        onTap: () => UpdateSheet.show(context),
                      ),
                      MoTile(
                        title: '启动时静默检查更新',
                        icon: Icons.notifications_none,
                        trailing: Switch(
                          value: silent,
                          onChanged: (bool v) {
                            _repo.setSetting('update_silent', v);
                            setState(() {});
                          },
                        ),
                      ),
                    ],
                  ),
                  SectionCard(
                    title: '下载',
                    subtitle: '国内用户优先访问 Gitee，速度更快',
                    children: <Widget>[
                      MoTile(
                        title: 'Gitee 发布页',
                        subtitle: '国内站点，推荐',
                        icon: Icons.download,
                        onTap: () => _openUrl(Endpoints.urlOf('gitee', 1)),
                      ),
                      MoTile(
                        title: 'GitHub 发布页',
                        subtitle: '海外站点',
                        icon: Icons.download_outlined,
                        onTap: () => _openUrl(Endpoints.urlOf('update', 1)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openUrl(String url) async {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null || url.isEmpty) {
      if (mounted) moSnack(context, '地址无效：$url');
      return;
    }
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) moSnack(context, '打不开浏览器，请手动复制：$url');
    }
  }
}
