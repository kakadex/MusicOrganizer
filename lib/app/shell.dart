import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'repo.dart';
import 'ui_kit.dart';
import '../core/tx/journal.dart';
import '../core/tx/journal_history.dart';
import '../feature/library/preview_sheet.dart';
import '../feature/library/library_page.dart';
import '../feature/organize/organize_page.dart';
import '../feature/settings/settings_page.dart';

/// 主界面骨架：底部三项导航（音乐库 / 整理 / 设置）+ 任务条。
///
/// 为什么用底部导航而不是把功能藏进齿轮：整理与设置都是高频入口，
/// 旧版走「齿轮 → 工具卡」要三次点击才能开始整理。
class MoShell extends StatefulWidget {
  const MoShell({super.key});

  @override
  State<MoShell> createState() => _MoShellState();
}

class _MoShellState extends State<MoShell> {
  int _tab = 0;
  bool _booted = false;
  String _bootError = '';

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      await Repo.instance.init();
      await Repo.instance.restoreRoot();
    } catch (e) {
      _bootError = '$e';
    }
    if (mounted) setState(() => _booted = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_booted) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const CircularProgressIndicator(),
              const SizedBox(height: 12),
              Text('正在准备…',
                  style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
            ],
          ),
        ),
      );
    }
    return CallbackShortcuts(
      // 桌面快捷键：与「设置」「整理」里的同名动作走同一套代码，不另开分支
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyO, control: true): _pickRoot,
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): _undoLast,
        const SingleActivator(LogicalKeyboardKey.f5): _rescan,
      },
      child: Focus(
        autofocus: true,
        child: _scaffold(),
      ),
    );
  }

  Future<void> _pickRoot() async {
    if (await Repo.instance.pickRoot() && mounted) setState(() {});
  }

  Future<void> _rescan() async {
    await Repo.instance.rescan();
    await Repo.instance.loadMeta();
  }

  /// 撤销最近一批（Ctrl+Z）：找不到批次就提示，不静默。
  Future<void> _undoLast() async {
    final Journal? journal = Repo.instance.journal;
    if (journal == null) return;
    final List<JournalBatch> batches = await journal.batches(1);
    if (batches.isEmpty) {
      if (mounted) moSnack(context, '没有可撤销的写入记录');
      return;
    }
    final int n = await undoBatch(batches.first.key);
    if (mounted) moSnack(context, '已撤销 $n 处改动');
  }

  Widget _scaffold() {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: <Widget>[
            if (_bootError.isNotEmpty)
              Container(
                width: double.infinity,
                color: MoKit.err(context).withValues(alpha: 0.10),
                padding: const EdgeInsets.all(10),
                child: Text('初始化失败：$_bootError',
                    style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.err(context))),
              ),
            // 三个页面都常驻（IndexedStack）。注意：**不要在这里统一包 ListenableBuilder**——
            // 子页面是 const 实例，widget 完全相同，Flutter 会跳过重建，监听白挂。
            // 每个页面自己监听 Repo（见 OrganizePage / SettingsPage 的 build）。
            Expanded(
              child: IndexedStack(
                index: _tab,
                children: const <Widget>[
                  LibraryPage(),
                  OrganizePage(),
                  SettingsPage(),
                ],
              ),
            ),
            const TaskBar(),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (int i) => setState(() => _tab = i),
        height: 60,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        destinations: const <NavigationDestination>[
          NavigationDestination(
            icon: Icon(Icons.library_music_outlined),
            selectedIcon: Icon(Icons.library_music),
            label: '音乐库',
          ),
          NavigationDestination(
            icon: Icon(Icons.tune_outlined),
            selectedIcon: Icon(Icons.tune),
            label: '整理',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
    );
  }
}
