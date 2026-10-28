import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/repo.dart';
import '../../app/repo_changes.dart';
import '../../app/theme/palette.dart';
import '../../app/ui_kit.dart';
import '../../core/log/log.dart';
import '../../core/match/tag_fill.dart';
import '../../core/media/media_import.dart';
import '../../core/model/vfile.dart';
import '../../core/net/http_client.dart';
import '../../core/net/net_tuning.dart';
import '../../core/net/proxy_settings.dart';
import '../../core/source/endpoints.dart';
import '../../core/settings/settings_backup.dart';
import '../../core/version.dart';
import '../../platform/host_channel.dart';
import '../health/health_page.dart';
import 'data_source_page.dart';
import 'folder_page.dart';
import '../library/media_import_sheet.dart';
import '../history/history_page.dart';
import 'update_sheet.dart';
import '../../platform/windows_file_assoc.dart';

/// 设置页：偏好 / 主题 / 维护 / 备份 / 关于。
///
/// 与「整理」明确分工：这里只放**偏好与维护**，功能类动作不在这（把工具卡塞进设置里，
/// 结果主功能要点三次才能到）。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  Repo get _repo => Repo.instance;

  late final TextEditingController _proxyHost;
  late final TextEditingController _proxyPort;
  late final TextEditingController _excludeCtl;

  @override
  void initState() {
    super.initState();
    final String host = _repo.settings.get<String>('proxy_host', fallback: '') ?? '';
    final int port = _repo.settings.get<int>('proxy_port', fallback: 0) ?? 0;
    _proxyHost = TextEditingController(text: host);
    _proxyPort = TextEditingController(text: port > 0 ? '$port' : '');
    _excludeCtl = TextEditingController(
        text: _repo.settings.get<String>('scan_exclude', fallback: '') ?? '');
    if (WindowsFileAssoc.supported) {
      WindowsFileAssoc.isEnabled().then((bool on) {
        if (mounted) setState(() => _assocEnabled = on);
      });
    }
  }

  /// Windows 上是否已经把音频默认打开方式指向本应用。
  bool _assocEnabled = false;

  @override
  void dispose() {
    _proxyHost.dispose();
    _proxyPort.dispose();
    _excludeCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 只订阅「设置 + 目录」：曲库扫描进度不再带着设置页一起重建。
    return ListenableBuilder(
      listenable: _repo.changes
          .of(<RepoDomain>[RepoDomain.settings, RepoDomain.root]),
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
              _scanCard(),
              _netCard(),
              _themeCard(),
              if (WindowsFileAssoc.supported) _fileAssocCard(),
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
        Row(
          children: <Widget>[
            Expanded(
              child: MoButton(path.isEmpty ? '选择目录' : '更换目录',
                  primary: path.isEmpty, onPressed: _pickRoot),
            ),
            if (path.isNotEmpty) ...<Widget>[
              const SizedBox(width: 8),
              Expanded(
                child: MoButton('移除目录', primary: false, onPressed: _clearRoot),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        MoButton('文件夹管理（多目录）', primary: false,
            onPressed: () => FolderPage.show(context)),
        const SizedBox(height: 4),
        Text('可以同时登记多个目录，扫描时一起进曲库；查重与整理跨目录生效。',
            style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
        if (MediaImport.supported) ...<Widget>[
          const SizedBox(height: 8),
          MoButton('从系统媒体库导入', primary: false,
              onPressed: path.isEmpty ? null : () => runMediaImport(context)),
          const SizedBox(height: 4),
          Text('把设备媒体库里的歌复制进曲库的「导入/」目录；只在点这个按钮时才申请读取音频的权限。',
              style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
        ],
      ],
    );
  }

  /// 移除曲库目录（会释放安卓的系统授权）。
  Future<void> _clearRoot() async {
    final bool? ok = await showMoSheet<bool>(
      context,
      title: '移除曲库目录？',
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.all(MoKit.pagePad),
          child: Text('只是从本应用里移除，不会删除任何文件。安卓上会同时放掉系统授权。',
              style: TextStyle(fontSize: MoKit.fsBody, color: MoKit.text(context))),
        ),
        Padding(
          padding: const EdgeInsets.all(MoKit.pagePad),
          child: MoButton('确认移除', primary: false,
              onPressed: () => Navigator.of(context).pop(true)),
        ),
      ],
    );
    if (ok != true || !mounted) return;
    await _repo.clearRoot();
    if (!mounted) return;
    moSnack(context, '已移除曲库目录');
  }

  Widget _matchCard() {
    final int weight = _repo.settings.get<int>('filename_weight', fallback: 20) ?? 20;
    final Map<String, int> modes = _repo.tagModes();
    return SectionCard(
      title: '匹配与写入',
      subtitle: '文件名权重越高越信文件名；写入策略逐字段生效',
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
        Text('字段写入策略',
            style: TextStyle(fontSize: MoKit.fsBody, color: MoKit.text(context))),
        const SizedBox(height: 2),
        Text('不写=这个字段永远不动；只补空=已有值保留；覆盖=与候选不同就改',
            style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
        const SizedBox(height: 6),
        for (final String f in TagFill.candidateFields) _modeRow(f, modes[f] ?? TagFill.supplement),
      ],
    );
  }

  /// 单字段的三档选择行。
  Widget _modeRow(String field, int mode) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 56,
            child: Text(TagFill.label(field),
                style: TextStyle(fontSize: MoKit.fsBody, color: MoKit.text(context))),
          ),
          const Spacer(),
          for (final int m in <int>[TagFill.disabled, TagFill.supplement, TagFill.overwrite])
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: MoChip(
                label: TagFill.modeName(m),
                selected: mode == m,
                onTap: () async {
                  setState(() {});
                  await _repo.setTagMode(field, m);
                  if (mounted) setState(() {});
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _scanCard() {
    final bool ignoreVideo =
        _repo.settings.get<bool>('scan_ignore_video', fallback: false) ?? false;
    return SectionCard(
      title: '扫描过滤',
      subtitle: '把不想要的声音文件挡在曲库之外（改完重新扫描生效）',
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text('忽略视频文件（mkv/mp4/avi 等）',
                  style: TextStyle(fontSize: MoKit.fsBody, color: MoKit.text(context))),
            ),
            Switch(
              value: ignoreVideo,
              onChanged: (bool v) {
                setState(() {});
                _repo.setSetting('scan_ignore_video', v);
              },
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text('路径关键字黑名单（一行一个，命中就跳过该目录或文件）',
            style: TextStyle(fontSize: MoKit.fsBody, color: MoKit.text(context))),
        const SizedBox(height: 4),
        TextField(
          controller: _excludeCtl,
          minLines: 2,
          maxLines: 5,
          decoration: const InputDecoration(
            hintText: '例如：\n备份\nPodcasts\n现场版',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          style: TextStyle(fontSize: MoKit.fsBody, color: MoKit.text(context)),
          onChanged: (String v) {
            _repo.setSetting('scan_exclude', v.trim().isEmpty ? null : v);
          },
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
        const SizedBox(height: 10),
        Divider(color: MoKit.line(context), height: 1),
        const SizedBox(height: 10),
        _proxyBlock(context),
      ],
    );
  }

  /// 代理：直连 / 自动（读环境变量）/ 手动。
  Widget _proxyBlock(BuildContext context) {
    final int mode = _repo.settings.get<int>('proxy_mode', fallback: 0) ?? 0;
    final ProxyMode current =
        ProxyMode.values[mode.clamp(0, ProxyMode.values.length - 1)];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text('代理',
                style: TextStyle(fontSize: MoKit.fsBody, color: MoKit.text(context))),
            const Spacer(),
            MoChip(
              label: '直连',
              selected: current == ProxyMode.direct,
              onTap: () => _setProxy(ProxyMode.direct),
            ),
            const SizedBox(width: 6),
            MoChip(
              label: '自动',
              selected: current == ProxyMode.auto,
              onTap: () => _setProxy(ProxyMode.auto),
            ),
            const SizedBox(width: 6),
            MoChip(
              label: '手动',
              selected: current == ProxyMode.manual,
              onTap: () => _setProxy(ProxyMode.manual),
            ),
          ],
        ),
        if (current == ProxyMode.manual) ...<Widget>[
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _proxyHost,
                  style: TextStyle(fontSize: MoKit.fsBody, color: MoKit.text(context)),
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: '主机',
                    hintText: '127.0.0.1',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _proxyPort,
                  keyboardType: TextInputType.number,
                  style: TextStyle(fontSize: MoKit.fsBody, color: MoKit.text(context)),
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: '端口',
                    hintText: '7890',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              MoButton('应用', onPressed: _applyManualProxy),
            ],
          ),
        ],
        const SizedBox(height: 6),
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                NetworkProxy.describe() +
                    (NetworkProxy.lastError.isEmpty ? '' : ' · ${NetworkProxy.lastError}'),
                style: TextStyle(
                  fontSize: MoKit.fsCaption,
                  color: NetworkProxy.lastError.isEmpty
                      ? MoKit.sub(context)
                      : MoKit.err(context),
                ),
              ),
            ),
            TextButton(
              onPressed: _testConnectivity,
              child: const Text('测试连通'),
            ),
          ],
        ),
        Text(
          '自动模式读环境变量（HTTPS_PROXY 等）；只支持 HTTP 代理，不支持 SOCKS。'
          '安卓上没有应用内读系统代理的途径，建议用系统 VPN / 代理（网络层生效，应用无需设置）。',
          style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.faint(context)),
        ),
      ],
    );
  }

  Future<void> _setProxy(ProxyMode mode) async {
    await _repo.setSetting('proxy_mode', mode.index);
    if (mode == ProxyMode.manual) {
      _applyManualProxy();
    } else {
      _repo.applyProxy();
    }
    if (mounted) setState(() {});
  }

  Future<void> _applyManualProxy() async {
    final String host = _proxyHost.text.trim();
    final int port = int.tryParse(_proxyPort.text.trim()) ?? 0;
    await _repo.setSetting('proxy_host', host);
    await _repo.setSetting('proxy_port', port);
    await _repo.setSetting('proxy_mode', ProxyMode.manual.index);
    _repo.applyProxy();
    if (!mounted) return;
    setState(() {});
    moSnack(context, NetworkProxy.lastError.isEmpty
        ? '代理已应用：${NetworkProxy.describe()}'
        : NetworkProxy.lastError);
  }

  /// 测更新相关的两个出口（国内 Gitee 清单 + 海外 GitHub 接口），能拿到内容就说明通了。
  Future<void> _testConnectivity() async {
    if (!mounted) return;
    moSnack(context, '正在测试连通…');
    final List<(String, String, int)> targets = <(String, String, int)>[
      ('Gitee', Endpoints.urlOf('gitee', 0), Http.readTimeoutCnMs),
      ('GitHub', Endpoints.urlOf('update', 0), Http.readTimeoutOverseasMs),
    ];
    final List<String> reached = <String>[];
    String lastWhy = '';
    for (final (String label, String url, int timeout) in targets) {
      final String? text = await Http.getText(url, null, null, timeout);
      if (text != null && text.trim().isNotEmpty) {
        reached.add(label);
      } else {
        lastWhy = Http.lastError.isEmpty ? '无响应' : Http.lastError;
      }
    }
    if (!mounted) return;
    final StringBuffer msg = StringBuffer();
    if (reached.isNotEmpty) {
      msg.write('连通正常：${reached.join(' / ')}');
    } else {
      msg.write('连不上：$lastWhy（${NetworkProxy.describe()}）');
      if (NetworkProxy.mode == ProxyMode.direct) {
        msg.write(' · 若处于需代理的网络，请切到「自动」或「手动」并填代理');
      }
    }
    moSnack(context, msg.toString());
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
          title: '启动时静默检查更新',
          subtitle: '每天最多一次，查到新版在底栏提示一句',
          icon: Icons.notifications_none,
          trailing: Switch(
            value: _repo.settings.get<bool>('update_silent', fallback: true) ?? true,
            onChanged: (bool v) {
              _repo.setSetting('update_silent', v);
              setState(() {});
            },
          ),
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
        MoTile(
          title: '运行日志',
          subtitle: '看最近的日志，或导出成 txt（已去掉本机路径）',
          icon: Icons.article_outlined,
          onTap: _showLog,
        ),
        MoTile(
          title: '数据源设置',
          subtitle: '单独停用某个源 / 改接口地址',
          icon: Icons.cloud_outlined,
          onTap: () => _push(const DataSourcePage()),
        ),
      ],
    );
  }

  /// 日志面板：看最近日志 + 导出 + 清空。
  Future<void> _showLog() async {
    final String text = await Log.readTail();
    if (!mounted) return;
    await showMoSheet<void>(
      context,
      title: '运行日志',
      children: <Widget>[
        Container(
          constraints: const BoxConstraints(maxHeight: 260),
          width: double.infinity,
          padding: const EdgeInsets.all(MoKit.pagePad),
          child: SingleChildScrollView(
            child: SelectableText(
              text.isEmpty ? '还没有日志' : text,
              style: TextStyle(
                  fontSize: MoKit.fsCaption, color: MoKit.text(context)),
            ),
          ),
        ),
      ],
      // 固定底栏：日志再长也能直接导出 / 清空
      footer: Row(
        children: <Widget>[
          Expanded(
            child: MoButton('导出日志', primary: false, onPressed: _exportLog),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: MoButton('清空', primary: false, onPressed: _clearLog),
          ),
        ],
      ),
    );
  }

  Future<void> _exportLog() async {
    // 安卓的应用私有目录用户看不到，导出必须走系统的「保存到…」，
    // 桌面则直接把路径摊开并允许复制（提示条会一闪而过，长路径根本看不清）。
    final String text = await Log.exportText();
    if (!mounted) return;
    if (text.isEmpty) {
      moSnack(context, '日志还是空的，先复现一次问题再导出');
      return;
    }
    final String stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final String name = 'musicorganizer-log-$stamp.txt';
    if (!Repo.isDesktop) {
      final bool ok = await exportTextToUser(name: name, text: text);
      if (!mounted) return;
      moSnack(context, ok ? '日志已保存到你选的位置' : '已取消保存');
      return;
    }
    final String? path = await Log.export();
    if (!mounted) return;
    if (path == null) {
      moSnack(context, '导出失败');
      return;
    }
    await showMoSheet<void>(
      context,
      title: '日志已导出',
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 0, MoKit.pagePad, 8),
          child: SelectableText(path,
              style: TextStyle(fontSize: MoKit.fsBody, color: MoKit.text(context))),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 0, MoKit.pagePad, 12),
          child: Row(
            children: <Widget>[
              Expanded(
                child: MoButton('复制路径', primary: false, onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: path));
                  if (mounted) moSnack(context, '路径已复制');
                }),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _clearLog() async {
    await Log.clear();
    if (!mounted) return;
    moSnack(context, '日志已清空');
  }

  Future<void> _toggleAssoc() async {
    final bool ok = _assocEnabled
        ? await WindowsFileAssoc.disable()
        : await WindowsFileAssoc.enable();
    if (!mounted) return;
    final bool now = await WindowsFileAssoc.isEnabled();
    if (!mounted) return;
    setState(() => _assocEnabled = now);
    moSnack(
      context,
      ok
          ? (now ? '已关联，双击音频即可进本应用' : '已取消关联，默认程序已还原')
          : '系统拒绝了注册表写入（可能是组策略限制）',
    );
  }

  Widget _fileAssocCard() {
    return SectionCard(
      title: 'Windows 文件关联',
      subtitle: _assocEnabled ? '双击音频会用本应用打开' : '未接管，系统默认程序保持不变',
      children: <Widget>[
        MoButton(
          _assocEnabled ? '取消关联' : '关联音频文件',
          primary: !_assocEnabled,
          onPressed: _toggleAssoc,
        ),
        const SizedBox(height: 8),
        Text(
          '只改当前用户的默认打开方式（mp3 / flac / m4a / wav / ogg / ape 等），'
          '取消时把原来的程序还回去。便携使用不建议开。',
          style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context)),
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
        const SizedBox(height: 8),
        MoTile(
          title: '恢复默认设置',
          subtitle: '只清偏好，不动曲库目录与写入历史',
          icon: Icons.restart_alt,
          onTap: _restoreDefaults,
        ),
      ],
    );
  }

  /// 界面键名 → 备份键名。
  ///
  /// 界面用的是 `filename_weight` / `fill_overwrite` 这类名字，备份格式（与 Java 版
  /// 兼容）用的是 `fn_weight` / `tag_overwrite`；不映射的话导出的 JSON 里
  /// 一个设置都没有。
  static const Map<String, String> _toBackupKey = <String, String>{
    'filename_weight': 'fn_weight',
    'fill_overwrite': 'tag_overwrite',
    'update_silent': 'update_auto',
    'net_files': 'net_files',
    'net_timeout': 'net_timeout',
    'theme_id': 'theme_id',
    'theme_dark': 'theme_dark',
    'lyrics_simplify': 'lyrics_simplify',
    'proxy_mode': 'proxy_mode',
    'proxy_host': 'proxy_host',
    'proxy_port': 'proxy_port',
  };

  /// 备份键名 → 界面键名（导入时反向查回来）。
  static Map<String, String> get _fromBackupKey {
    return <String, String>{
      for (final MapEntry<String, String> e in _toBackupKey.entries) e.value: e.key,
    };
  }

  /// 备份键的中文名（「恢复默认设置」的确认清单里显示）。
  static const Map<String, String> _keyLabels = <String, String>{
    'fn_weight': '文件名权重',
    'tag_overwrite': '覆盖已有标签',
    'update_auto': '启动时检查更新',
    'net_files': '同时处理（并发）',
    'net_timeout': '超时倍率',
    'theme_id': '配色',
    'theme_dark': '夜间模式',
    'lyrics_simplify': '歌词转简体',
    'proxy_mode': '代理模式',
    'proxy_host': '代理主机',
    'proxy_port': '代理端口',
  };

  /// 当前设置（已换成备份键名）。
  Map<String, Object?> _valuesAsBackupKeys() {
    final Map<String, Object?> out = <String, Object?>{};
    for (final MapEntry<String, String> e in _toBackupKey.entries) {
      final Object? v = _repo.settings.get<Object>(e.key);
      if (v != null) out[e.value] = v;
    }
    // 逐字段策略（fp:）/ 数据源开关（ep_on:）/ 接口地址（ep:）/ 扫描过滤：
    // 运行时键名与备份格式一致，凡是备份核心认识的都直接带上。
    for (final String key in _repo.settings.keys) {
      if (out.containsKey(key)) continue;
      if (SettingsBackup.kindOf(key) == null) continue;
      final Object? v = _repo.settings.get<Object>(key);
      if (v != null) out[key] = v;
    }
    return out;
  }

  Future<void> _restoreDefaults() async {
    final Map<String, Object?> current = _valuesAsBackupKeys();
    final List<String> diff = SettingsBackup.diffFromDefaults(current);
    if (diff.isEmpty) {
      if (mounted) moSnack(context, '现在就是默认设置');
      return;
    }
    final bool? go = await showMoSheet<bool>(
      context,
      title: '恢复默认设置',
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 4, MoKit.pagePad, 8),
          child: Text('下面 ${diff.length} 项会回到默认值（曲库目录、写入历史、日志不受影响）：',
              style: TextStyle(fontSize: MoKit.fsBody, color: MoKit.text(context))),
        ),
        for (final String k in diff.take(20))
          Padding(
            padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 4, MoKit.pagePad, 0),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(_keyLabels[k] ?? k,
                      style: TextStyle(fontSize: MoKit.fsBody, color: MoKit.text(context))),
                ),
                Text('${current[k]} → ${SettingsBackup.defaults()[k]}',
                    style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
              ],
            ),
          ),
      ],
      // 固定底栏：要恢复的项再多也点得到
      footer: Builder(
        builder: (BuildContext fctx) => SizedBox(
          width: double.infinity,
          child: MoButton('恢复这 ${diff.length} 项', primary: false,
              onPressed: () => Navigator.of(fctx).pop(true)),
        ),
      ),
    );
    if (go != true) return;
    final Map<String, Object> defaults = SettingsBackup.defaults();
    for (final String k in diff) {
      final Object? v = defaults[k];
      if (v == null) continue;
      await _repo.setSetting(_fromBackupKey[k] ?? k, v);
    }
    if (!mounted) return;
    // 代理可能被重置回直连了，立即生效，别等重启
    _repo.applyProxy();
    setState(() {});
    moSnack(context, '已恢复 ${diff.length} 项默认设置');
  }

  Widget _aboutCard() {
    return SectionCard(
      title: '关于',
      children: <Widget>[
        MoTile(title: '版本', subtitle: kAppVersionFull, icon: Icons.info_outline),
        const SizedBox(height: 6),
        Text('下载（国内用户优先访问 Gitee，速度更快）',
            style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
        const SizedBox(height: 4),
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
    if (!ok) {
      if (_repo.pickError != null) {
        moSnack(context, _repo.pickError!);
      }
      return;
    }
    _repo.files = <VFile>[];
    setState(() {});
    moSnack(context, '已切换目录，回到「音乐库」会自动扫描');
  }

  Map<String, Object?> _exportValues() => _valuesAsBackupKeys();

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
      // 备份格式里的键名与界面键名不同名（fn_weight ↔ filename_weight），要换回来。
      await _repo.setSetting(_fromBackupKey[e.key] ?? e.key, e.value);
    }
    if (!mounted) return;
    // 导入的代理配置立即生效，不用等重启
    _repo.applyProxy();
    setState(() {});
    moSnack(context, '已导入 ${parsed.count} 项（重启应用后主题类设置完全生效）');
    if (parsed.warnings.isNotEmpty || parsed.ignored.isNotEmpty) {
      await showMoSheet<void>(
        context,
        title: '导入结果',
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(MoKit.pagePad),
            child: Text(parsed.summary(),
                style: TextStyle(fontSize: MoKit.fsBody, color: MoKit.text(context))),
          ),
        ],
      );
    }
  }
}
