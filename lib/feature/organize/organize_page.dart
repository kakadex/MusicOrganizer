import 'package:flutter/material.dart';

import '../../app/repo.dart';
import '../../app/ui_kit.dart';
import '../../core/model/vfile.dart';
import '../covers/covers_page.dart';
import '../health/health_page.dart';
import '../history/history_page.dart';
import '../lyrics_batch/lyrics_batch_page.dart';

/// 整理页（最小落位）：批量歌词 / 封面入口，另接体检与撤销历史。
///
/// 文件移动等整理规则由整理功能负责人继续补；这里先保证入口可用，
/// 批量操作始终在点击时重新取曲库，避免页面停留后拿到旧列表。
class OrganizePage extends StatefulWidget {
  const OrganizePage({super.key});

  @override
  State<OrganizePage> createState() => _OrganizePageState();
}

class _OrganizePageState extends State<OrganizePage> {
  @override
  Widget build(BuildContext context) {
    final int count = Repo.instance.audioFiles().length;
    return Column(
      children: <Widget>[
        PageHeader(
          title: '整理',
          subtitle: count == 0 ? '还没有扫描到音频' : '$count 首可处理',
          actions: <Widget>[
            IconButton(
              tooltip: '刷新',
              onPressed: () => setState(() {}),
              icon: Icon(Icons.refresh, size: 20, color: MoKit.text(context)),
            ),
          ],
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 16),
            children: <Widget>[
              SectionCard(
                title: '批量处理',
                subtitle: '联网结果先预览，确认后才写盘',
                children: <Widget>[
                  MoTile(
                    title: '批量歌词',
                    subtitle: '按来源取词，逐首确认后写入',
                    icon: Icons.lyrics_outlined,
                    onTap: () => _openBatch(
                        context, (List<VFile> f) => LyricsBatchPage(files: f)),
                  ),
                  MoTile(
                    title: '批量封面',
                    subtitle: '从数据源补齐内嵌封面',
                    icon: Icons.image_outlined,
                    onTap: () => _openBatch(
                        context, (List<VFile> f) => CoversPage(files: f)),
                  ),
                ],
              ),
              SectionCard(
                title: '检查与回退',
                children: <Widget>[
                  MoTile(
                    title: '体检 / CSV',
                    subtitle: '统计缺项并导出曲库清单',
                    icon: Icons.monitor_heart_outlined,
                    onTap: () => _push(context, const HealthPage()),
                  ),
                  MoTile(
                    title: '撤销历史',
                    subtitle: '按批次回退已写入的标签',
                    icon: Icons.history,
                    onTap: () => _push(context, const HistoryPage()),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _openBatch(BuildContext context, Widget Function(List<VFile>) build) {
    final List<VFile> files = Repo.instance.audioFiles();
    if (files.isEmpty) {
      moSnack(context, '先在音乐库选择目录并扫描');
      return;
    }
    _push(context, build(files));
  }

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (BuildContext _) => page),
    );
  }
}
