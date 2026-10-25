import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../app/repo.dart';
import '../../app/theme/palette.dart';
import '../../app/ui_kit.dart';
import '../../core/model/vfile.dart';
import '../../core/net/net_tuning.dart';
import '../../core/settings/settings_backup.dart';
import '../../core/version.dart';
import '../health/health_page.dart';
import '../history/history_page.dart';
import 'update_sheet.dart';

/// 设置页：偏好 / 主题 / 维护 / 备份 / 关于。
///
/// 与「整理」明确分工：这里只放**偏好与维护**，功能类动作不在这（旧版把工具卡塞进设置里，
/// 结果主功能要点三次才能到）。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  Repo get _repo => Repo.instance;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _repo,
      builder: (BuildContext context, Widget? _) => _body(context),
    );
  }

  Widget _body(BuildContext context) {
    return Column(
      children: <Widget>[
        PageHeader(title: '设置', subtitle: '版本 $kAppVersionFull'),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 16),
            children: <Widget>[
              _dirCard(),
              _matchCard(),
              _netCard(),
              _themeCard(),
              _maintainCard(),
              _backupCard(),
              _aboutCard(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _dirCard() {
    final String path = _repo.root?.rootDocId ?? '';
    return SectionCard(
      title: '曲库目录',
      subtitle: Repo.isDesktop ? '桌面直接读写这个文件夹' : '只在你授权的范围内读写',
      children: <Widget>[
        Text(path.isEmpty ? '还没有选择' : path,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
        const SizedBox(height: 8),
        MoButton(path.isEmpty ? '选择目录' : '更换目录',
            primary: path.isEmpty, onPressed: _pickRoot),
      ],
    );
  }

  Widget _matchCard() {
    final int weight = _repo.settings.get<int>('filename_weight', fallback: 20) ?? 20;
    final bool overwrite = _repo.settings.get<bool>('fill_overwrite', fallback: false) ?? false;
    return SectionCard(
      title: '匹配与写入',
      subtitle: '文件名权重越高越信文件名，越低越信已有标签',
      children: <Widget>[
        Row(
          children: <Widget>[
            Text('权重 $weight%',
                style: TextStyle(fontSize: MoKit.fsBody, color: MoKit.text(context))),
            Expanded(
              child: Slider(
                value: weight.toDouble(),
                min: 0,
                max: 100,
                divisions: 20,
                label: '$weight%',
                onChanged: (double v) {
                  setState(() {});
                  _repo.setSetting('filename_weight', v.round());
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: <Widget>[
            Text('写入策略',
                style: TextStyle(fontSize: MoKit.fsBody, color: MoKit.text(context))),
            const Spacer(),
            MoChip(
              label: '只补空缺',
              selected: !overwrite,
              onTap: () {
                setState(() {});
                _repo.setSetting('fill_overwrite', false);
              },
            ),
            const SizedBox(width: 8),
            MoChip(
              label: '覆盖已有',
              selected: overwrite,
              onTap: () {
                setState(() {});
                _repo.setSetting('fill_overwrite', true);
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _netCard() {
    final int files = _repo.settings.get<int>('net_files',
            fallback: NetTuning.defaultFileConcurrency) ??
        NetTuning.defaultFileConcurrency;
    final int timeout = _repo.settings.get<int>('net_timeout',
            fallback: NetTuning.defaultTimeoutPercent) ??
        NetTuning.defaultTimeoutPercent;
    return SectionCard(
      title: '网络与并发',
      subtitle: '网络差就少并发、加超时；网络好可以多并发，批量更快',
      children: <Widget>[
        Row(
          children: <Widget>[
            Text('同时处理',
                style: TextStyle(fontSize: MoKit.fsBody, color: MoKit.text(context))),
            const Spacer(),
            for (int i = NetTuning.minFileConcurrency;
                i <= NetTuning.maxFileConcurrency;
                i++)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: MoChip(
                  label: '$i',
                  selected: files == i,
                  onTap: () {
                    setState(() {});
                    _repo.setSetting('net_files', i);
                    NetTuning.apply(i, timeout);
                  },
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            Text('超时倍率',
                style: TextStyle(fontSize: MoKit.fsBody, color: MoKit.text(context))),
            const Spacer(),
            for (final int step in NetTuning.timeoutSteps)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: MoChip(
                  label: NetTuning.timeoutLabel(step),
                  selected: timeout == step,
                  onTap: () {
                    setState(() {});
                    _repo.setSetting('net_timeout', step);
                    NetTuning.apply(files, step);
                  },
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _themeCard() {
    final controller = _repo.themeController;
    if (controller == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) {
        return SectionCard(
          title: '外观',
          children: <Widget>[
            Row(
              children: <Widget>[
                for (final MoThemeId id in MoThemeId.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: MoChip(
                      label: _themeName(id),
                      selected: controller.themeId == id,
                      onTap: () {
                        controller.setTheme(id);
                        _repo.setSetting('theme_id', id.index);
                      },
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: <Widget>[
                Text('夜间模式',
                    style: TextStyle(fontSize: MoKit.fsBody, color: MoKit.text(context))),
                const Spacer(),
                Switch(
                  value: controller.dark,
                  onChanged: (bool v) {
                    controller.setDark(v);
                    _repo.setSetting('theme_dark', v);
                  },
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _maintainCard() {
    return SectionCard(
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
          onTap: () => _push(const HistoryPage()),
        ),
        MoTile(
          title: '体检 / CSV',
          subtitle: '统计缺项，导出曲库清单',
          icon: Icons.monitor_heart_outlined,
          onTap: () => _push(const HealthPage()),
        ),
      ],
    );
  }

  Widget _backupCard() {
    return SectionCard(
      title: '设置备份',
      subtitle: '只备份偏好与接口地址，不含曲库与文件',
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: MoButton('导出设置', primary: false, onPressed: _export),
            ),
            const SizedBox(width: 8),
            Expanded(child: MoButton('导入设置', primary: false, onPressed: _import)),
          ],
        ),
      ],
    );
  }

  Widget _aboutCard() {
    return SectionCard(
      title: '关于',
      children: <Widget>[
        MoTile(title: '版本', subtitle: kAppVersionFull, icon: Icons.info_outline),
        MoTile(
          title: '零依赖说明',
          subtitle: '不绑定需注册账号的平台；数据源全部使用公开接口；安装包自包含',
          icon: Icons.verified_user_outlined,
        ),
      ],
    );
  }

  String _themeName(MoThemeId id) {
    switch (id) {
      case MoThemeId.warm:
        return '暖橙';
      case MoThemeId.minimal:
        return '简紫';
      case MoThemeId.lyrico:
        return '简蓝';
    }
  }

  void _push(Widget page) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (BuildContext _) => page),
    );
  }

  Future<void> _pickRoot() async {
    final bool ok = await _repo.pickRoot();
    if (!mounted) return;
    if (!ok) return;
    _repo.files = <VFile>[];
    setState(() {});
    moSnack(context, '已切换目录，回到「音乐库」会自动扫描');
  }

  Map<String, Object?> _exportValues() {
    final Map<String, Object?> out = <String, Object?>{};
    for (final String key in <String>[
      'filename_weight',
      'fill_overwrite',
      'net_files',
      'net_timeout',
      'theme_id',
      'theme_dark',
    ]) {
      out[key] = _repo.settings.get<Object>(key);
    }
    return out;
  }

  Future<void> _export() async {
    final String text = SettingsBackup.toJson(_exportValues(), null);
    final Directory dir = await getApplicationSupportDirectory();
    final File f = File('${dir.path}/settings-backup.json');
    await f.writeAsString(text);
    if (!mounted) return;
    moSnack(context, Repo.isDesktop ? '已导出到 ${f.path}' : '已导出到应用私有目录 settings-backup.json');
  }

  Future<void> _import() async {
    const XTypeGroup group = XTypeGroup(label: '设置备份', extensions: <String>['json']);
    final XFile? picked = await openFile(acceptedTypeGroups: <XTypeGroup>[group]);
    if (picked == null) return;
    final String text = await picked.readAsString();
    final SettingsImport parsed = SettingsBackup.fromJson(text);
    if (!mounted) return;
    if (!parsed.ok) {
      moSnack(context, '导不进去：${parsed.error ?? '格式不对'}');
      return;
    }
    for (final MapEntry<String, Object> e in parsed.values.entries) {
      await _repo.setSetting(e.key, e.value);
    }
    if (!mounted) return;
    setState(() {});
    moSnack(context, '已导入 ${parsed.count} 项（重启应用后主题类设置完全生效）');
  }
}
