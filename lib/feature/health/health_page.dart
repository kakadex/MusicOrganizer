import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../app/repo.dart';
import '../../app/ui_kit.dart';
import '../../core/csv/csv_export.dart' as csv;
import '../../core/health/health_check.dart';
import '../../core/model/tags.dart';
import '../../core/model/vfile.dart';
import '../../core/task/task_center.dart';

/// 体检 / CSV：逐项统计问题并可筛选，另可把曲库清单导出到应用私有目录。
class HealthPage extends StatefulWidget {
  const HealthPage({super.key});

  @override
  State<HealthPage> createState() => _HealthPageState();
}

class _HealthPageState extends State<HealthPage> {
  HealthResult? _result;
  HealthIssue? _filter;
  bool _busy = false;
  String _note = '';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: <Widget>[
            PageHeader(
              title: '体检 / CSV',
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
                  tooltip: '开始体检',
                  onPressed: _busy ? null : _run,
                  icon: Icon(Icons.fact_check_outlined,
                      size: 20,
                      color: _busy ? MoKit.faint(context) : MoKit.text(context)),
                ),
                IconButton(
                  tooltip: '导出 CSV',
                  onPressed: _busy ? null : _export,
                  icon: Icon(Icons.ios_share,
                      size: 20,
                      color: _busy ? MoKit.faint(context) : MoKit.text(context)),
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
    if (_note.isNotEmpty) return _note;
    final HealthResult? r = _result;
    if (r != null) return r.headline();
    return '检查标签 / 封面 / 歌词 / 时长 / 文件名';
  }

  Widget _body() {
    if (_busy && _result == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(height: 12),
            Text('正在读取曲库信息…',
                style: TextStyle(fontSize: MoKit.fsBody, color: MoKit.sub(context))),
          ],
        ),
      );
    }
    final HealthResult? r = _result;
    if (r == null) {
      return EmptyState(
        icon: Icons.monitor_heart_outlined,
        text: '还没有体检',
        hint: '会先读取标签 / 封面 / 歌词，再逐项统计问题',
        action: MoButton('开始体检',
            icon: Icons.fact_check_outlined, busy: _busy, onPressed: _run),
      );
    }
    return Column(
      children: <Widget>[
        _summary(r),
        _chips(r),
        Expanded(child: _list(r)),
      ],
    );
  }

  Widget _summary(HealthResult r) {
    final List<String> lines = r.lines();
    return SectionCard(
      title: '体检结果',
      subtitle: r.headline(),
      children: <Widget>[
        Text(
          lines.isEmpty ? '五个标签维度和附加检查都通过' : lines.join(' · '),
          style: TextStyle(
              fontSize: MoKit.fsBody, height: 1.5, color: MoKit.sub(context)),
        ),
        const SizedBox(height: 6),
        Text(
          '齐全 ${r.complete} 首 · 待处理 ${r.problems.length} 首',
          style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.faint(context)),
        ),
      ],
    );
  }

  Widget _chips(HealthResult r) {
    return SizedBox(
      height: 34,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: MoKit.pagePad),
        children: <Widget>[
          MoChip(
            label: '全部 ${r.problems.length}',
            selected: _filter == null,
            onTap: () => setState(() => _filter = null),
          ),
          for (final HealthIssue issue in HealthIssue.values)
            if (r.countOf(issue) > 0)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: MoChip(
                  label: '${issue.label} ${r.countOf(issue)}',
                  selected: _filter == issue,
                  onTap: () => setState(() => _filter = issue),
                ),
              ),
        ],
      ),
    );
  }

  Widget _list(HealthResult r) {
    final List<HealthTrack> shown =
        _filter == null ? r.problems : r.withIssue(_filter!);
    if (shown.isEmpty) {
      return EmptyState(
        icon: Icons.check_circle_outline,
        text: _filter == null ? '没有发现明显问题' : '这一项没有曲目',
        hint: _filter == null ? '标签、封面、歌词、时长、文件名都正常' : '换一项看看',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(top: 6, bottom: 16),
      itemCount: shown.length,
      itemBuilder: (BuildContext context, int index) {
        final HealthTrack t = shown[index];
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: SongRow(
            title: t.input.name,
            subtitle: t.detail(),
            trailing: Text(
              '${t.issues.length} 项',
              style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.faint(context)),
            ),
          ),
        );
      },
    );
  }

  Future<void> _run() async {
    if (_busy) return;
    final Repo repo = Repo.instance;
    if (repo.store == null) {
      moSnack(context, '仓库还没初始化，稍后再试');
      return;
    }
    if (repo.scanning || repo.metaLoading) { moSnack(context, '曲库正在扫描或读取标签，稍后再试'); return; }
    if (TaskCenter.isBusy()) {
      moSnack(context, '另一个任务正在运行，等它结束再体检');
      return;
    }
    final RunningTask? task = TaskCenter.start('曲库体检');
    if (task == null) {
      moSnack(context, '任务没启动起来，请稍后再试');
      return;
    }
    setState(() {
      _busy = true;
      _note = '正在读取标签…';
    });
    try {
      await repo.loadMeta(cancel: task.control, onProgress: (int done, int total) {
        if (mounted && total > 0) {
          setState(() => _note = '正在读取标签 $done/$total');
        }
      });
      final List<VFile> files = repo.audioFiles();
      final HealthResult r = HealthAudit.run(files.map(_inputOf));
      if (!mounted) return;
      setState(() {
        _result = r;
        _filter = null;
        _note = '';
      });
      if (files.isEmpty) moSnack(context, '还没有扫描到音频文件');
    } catch (e) {
      if (mounted) moSnack(context, '体检失败：$e');
    } finally {
      TaskCenter.finish();
      if (mounted) setState(() { _busy = false; _note = ''; });
    }
  }

  Future<void> _export() async {
    final Repo repo = Repo.instance;
    if (repo.files.isEmpty) {
      moSnack(context, '还没有扫描到文件，先扫描曲库');
      return;
    }
    if (repo.scanning || repo.metaLoading) { moSnack(context, '曲库正在扫描或读取标签，稍后再试'); return; }
    if (TaskCenter.isBusy()) {
      moSnack(context, '另一个任务正在运行，等它结束再导出');
      return;
    }
    final RunningTask? task = TaskCenter.start('导出 CSV');
    if (task == null) {
      moSnack(context, '任务没启动起来，请稍后再试');
      return;
    }
    setState(() {
      _busy = true;
      _note = '正在生成清单…';
    });
    try {
      await repo.loadMeta();
      final String rootId = repo.root?.rootDocId ?? '';
      final List<csv.Row> rows = <csv.Row>[];
      for (final VFile f in csv.CsvExport.audioOnly(repo.files)) {
        final Tags tags = f.cachedTags ?? Tags();
        final bool lyrics =
            f.cachedHasLyrics || tags.get(Tags.lyrics).trim().isNotEmpty;
        final csv.Row row = csv.CsvExport.rowOf(f, tags, f.cachedHasCover, lyrics);
        final String rel = f.relativePath(rootId);
        final int slash = rel.lastIndexOf('/');
        row.dir = slash > 0 ? rel.substring(0, slash) : '';
        rows.add(row);
      }
      final String content = csv.CsvExport.build(rows);
      final Directory dir = await getApplicationSupportDirectory();
      if (!await dir.exists()) await dir.create(recursive: true);
      final String name = csv.CsvExport.defaultFileName(DateTime.now());
      final File file = File('${dir.path}/$name');
      await file.writeAsString(content, flush: true);
      if (!mounted) return;
      final String where =
          Repo.isDesktop ? '已保存：${file.path}' : '已保存到应用私有目录：$name';
      moSnack(context, '导出 ${rows.length} 首 · $where');
    } catch (e) {
      if (mounted) moSnack(context, '导出失败：$e');
    } finally {
      TaskCenter.finish();
      if (mounted) setState(() { _busy = false; _note = ''; });
    }
  }
}

/// 从 VFile 的缓存标签映射成体检事实（不触发读盘）。
HealthInput _inputOf(VFile f) {
  final Tags t = f.cachedTags ?? Tags();
  return HealthInput(
    docId: f.docId,
    name: f.name,
    size: f.size,
    durationMs: f.cachedDurationMs,
    title: t.get('title').trim().isNotEmpty,
    artist: t.get('artist').trim().isNotEmpty,
    album: t.get('album').trim().isNotEmpty,
    cover: f.cachedHasCover,
    lyrics: f.cachedHasLyrics || t.get(Tags.lyrics).trim().isNotEmpty,
  );
}
