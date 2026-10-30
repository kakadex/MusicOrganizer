import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'repo.dart';
import 'ui_kit.dart';
import '../core/tx/journal.dart';
import '../platform/drop_channel.dart';
import '../platform/external_open.dart';
import '../platform/task_service.dart';
import '../core/tx/journal_history.dart';
import '../feature/history/undo_flow.dart';
import '../feature/library/library_page.dart';
import '../feature/settings/settings_page.dart';
import '../feature/settings/update_sheet.dart';
import 'silent_update.dart';

/// 主界面骨架：**只有音乐库一页** + 任务条。
///
/// 2026-10-30 改版：去掉底部三项导航。设置收紧成标题栏左上角的齿轮（点开是
/// 独立路由），原「整理」页整体收进设置里（设置 → 整理 → 扫描与整理 / 清理与查重）。
/// 标题「音乐库」居中放在顶部，右侧只留排序。
class MoShell extends StatefulWidget {
  const MoShell({super.key});

  @override
  State<MoShell> createState() => _MoShellState();
}

class _MoShellState extends State<MoShell> {
  bool _booted = false;
  String _bootError = '';

  @override
  void initState() {
    super.initState();
    // 拖放只在桌面生效（其他平台没有对端，注册是空操作）
    DropChannel.listen(_onDrop);
    // 长任务挂通知栏（安卓前台服务），退后台才不会被系统回收
    TaskService.attach();
    // 外部调起：文件管理器里「用本应用打开」音频
    ExternalOpen.listen(_onExternalUri);
    _boot();
  }

  Future<void> _boot() async {
    try {
      await Repo.instance.init();
      await Repo.instance.restoreRoot();
      // 目录一恢复就把上次的曲库缓存灌进来：界面立刻有列表可看，
      // 后台再增量扫一遍补差，不用每次启动都干等一轮全量扫描。
      await Repo.instance.restoreLibraryCache();
    } catch (e) {
      _bootError = '$e';
    }
    if (mounted) setState(() => _booted = true);
    // 启动时就带进来的文件（ACTION_EDIT / ACTION_VIEW）
    _takeInitialIntent();
    // 静默查更新（每天最多一次）：查到新版本就在底栏提示一句，不打断。
    _silentCheck();
  }

  Future<void> _takeInitialIntent() async {
    final String? uri = await ExternalOpen.takeInitialIntent();
    if (uri == null || uri.isEmpty || !mounted) return;
    await ExternalOpen.handle(context, uri);
  }

  Future<void> _onExternalUri(String uri) async {
    if (!mounted) return;
    await ExternalOpen.handle(context, uri);
  }

  Future<void> _silentCheck() async {
    final release = await SilentUpdate.checkIfDue();
    if (release == null || !mounted) return;
    moSnack(context, '有新版本 ${release.version}',
        actionLabel: '去看看', onAction: () => UpdateSheet.show(context));
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
        // Ctrl+, 打开设置（桌面通用约定）；没有底部导航后就没法用数字键切页了
        const SingleActivator(LogicalKeyboardKey.comma, control: true):
            _openSettings,
      },
      child: Focus(
        autofocus: true,
        child: _scaffold(),
      ),
    );
  }

  void _openSettings() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (BuildContext _) => const SettingsPage()),
    );
  }

  /// 拖放：桌面把文件夹（或文件）拖进来就切到那个目录。
  Future<void> _onDrop(List<String> paths) async {
    final DropResult? r = DropAction.resolve(paths);
    if (r == null) {
      if (mounted) moSnack(context, '这些路径里没有可用的目录');
      return;
    }
    final bool ok = await Repo.instance.useDirectory(r.rootPath);
    if (!mounted) return;
    if (!ok) {
      moSnack(context, '目录不存在：${r.rootPath}');
      return;
    }
    moSnack(context, r.describe());
    await Repo.instance.rescan();
    await Repo.instance.loadMeta();
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
    if (!mounted) return;
    if (batches.isEmpty) {
      if (mounted) moSnack(context, '没有可撤销的写入记录');
      return;
    }
    final int? n = await undoBatchWithPreview(context, batchId: batches.first.key);
    if (n == null || !mounted) return;
    moSnack(context, n == 0 ? '没有可还原的改动' : '已撤销 $n 处改动');
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
            // 只有音乐库一页；页面常驻，切设置是独立路由（返回后列表状态不丢）。
            Expanded(
              child: const LibraryPage(),
            ),
            const TaskBar(),
          ],
        ),
      ),
    );
  }
}
