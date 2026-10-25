import 'package:flutter/material.dart';

import '../../app/repo.dart';
import '../../app/ui_kit.dart';
import '../../core/model/journal_entry.dart';
import '../../core/model/vfile.dart';
import '../../core/task/task_center.dart';
import '../../core/tx/journal.dart';
import '../../core/tx/journal_history.dart';
import '../../core/tx/tag_transaction.dart';

/// 撤销历史：按批次列出写入记录，整批逆序回滚。
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  List<JournalBatch> _batches = <JournalBatch>[];
  bool _loading = true;
  String _error = '';
  String _busyKey = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final Journal? journal = Repo.instance.journal;
    if (journal == null) {
      setState(() {
        _loading = false;
        _error = '仓库还没初始化，稍后重试';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final List<JournalBatch> list = await journal.batches(100);
      if (mounted) {
        setState(() {
          _batches = list;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '读取撤销记录失败：$e';
        });
      }
    }
  }

  Future<void> _undo(JournalBatch batch) async {
    final Repo repo = Repo.instance;
    final Journal? journal = repo.journal;
    final TagTransaction? tx = repo.tx;
    if (journal == null || tx == null) {
      moSnack(context, '仓库还没初始化，无法撤销');
      return;
    }
    if (_busyKey.isNotEmpty) return;
    if (TaskCenter.isBusy()) {
      moSnack(context, '另一个任务正在运行，等它结束再撤销');
      return;
    }
    final RunningTask? task = TaskCenter.start('撤销写入');
    if (task == null) {
      moSnack(context, '任务没启动起来，请稍后再试');
      return;
    }
    setState(() => _busyKey = batch.key);

    final Map<String, VFile> byId = <String, VFile>{
      for (final VFile f in repo.files) f.docId: f,
    };
    List<int> result = <int>[0, 0, 0];
    try {
      result = await journal.revertBatch(batch.key,
          revertOne: (JournalEntry entry) async {
        final String key = entry.targetId.isNotEmpty ? entry.targetId : entry.uri;
        final VFile? f = byId[key];
        if (f == null) return false;
        final String err = await tx.apply(
          f,
          Map<String, String>.from(entry.before),
          record: false,
        );
        if (err.isNotEmpty) return false;
        repo.invalidate(f);
        return true;
      });
    } catch (e) {
      if (mounted) moSnack(context, '撤销失败：$e');
    } finally {
      TaskCenter.finish();
    }

    if (!mounted) return;
    setState(() => _busyKey = '');
    await _load();
    if (!mounted) return;
    final int ok = result[0];
    final int failed = result[1];
    final int total = result[2];
    if (total == 0 && failed == 0) return;
    if (failed == 0) {
      moSnack(context, '已撤销 $ok 处改动');
    } else {
      moSnack(context, '已撤销 $ok 处，失败 $failed 处（共 $total 条）');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: <Widget>[
            PageHeader(
              title: '撤销历史',
              subtitle: _subtitle(),
              actions: <Widget>[
                if (Navigator.of(context).canPop())
                  IconButton(
                    tooltip: '返回',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(Icons.arrow_back,
                        size: 20, color: MoKit.text(context)),
                  ),
                IconButton(
                  tooltip: '刷新',
                  onPressed: _loading ? null : _load,
                  icon: Icon(Icons.refresh,
                      size: 20,
                      color: _loading ? MoKit.faint(context) : MoKit.text(context)),
                ),
              ],
            ),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  String _subtitle() {
    if (_loading) return '正在读取…';
    if (_error.isNotEmpty) return _error;
    return '${_batches.length} 批可撤销（最多显示最近 100 批）';
  }

  Widget _body() {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_error.isNotEmpty) {
      return EmptyState(
        icon: Icons.error_outline,
        text: _error,
        action: MoButton('重试', icon: Icons.refresh, onPressed: _load),
      );
    }
    if (_batches.isEmpty) {
      return const EmptyState(
        icon: Icons.history,
        text: '没有可撤销的写入记录',
        hint: '批量改标签后会按批次出现在这里，可整批回退',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: _batches.length,
      itemBuilder: (BuildContext context, int index) {
        final JournalBatch b = _batches[index];
        final bool busy = _busyKey == b.key;
        final bool partial = b.total > b.count;
        return SectionCard(
          title: b.title(),
          subtitle: b.summary(),
          trailing: Text(
            partial ? '部分已撤销' : '可撤销',
            style: TextStyle(
              fontSize: MoKit.fsCaption,
              fontWeight: FontWeight.w600,
              color: partial ? MoKit.warn(context) : MoKit.ok(context),
            ),
          ),
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '共 ${b.total} 条，尚可撤销 ${b.count} 条',
                    style: TextStyle(
                        fontSize: MoKit.fsCaption, color: MoKit.sub(context)),
                  ),
                ),
                MoButton(
                  busy ? '撤销中' : '撤销这一批',
                  primary: false,
                  busy: busy,
                  onPressed: _busyKey.isEmpty ? () => _undo(b) : null,
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
