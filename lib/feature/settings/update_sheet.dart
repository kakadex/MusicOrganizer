import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/ui_kit.dart';
import '../../core/source/endpoints.dart';
import '../../core/task/task_center.dart';
import '../../core/update/app_update.dart';
import '../../core/update/update_check.dart';
import '../../core/version.dart';

/// 检查更新面板：Gitee 清单 → GitHub 清单 → GitHub Release 接口，任一成功即用。
///
/// 不新增版本依赖：当前版本直接读 [kAppVersionFull]；下载统一交给浏览器。
class UpdateSheet extends StatefulWidget {
  const UpdateSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: MoKit.bg(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (BuildContext ctx) => const UpdateSheet(),
    );
  }

  @override
  State<UpdateSheet> createState() => _UpdateSheetState();
}

class _UpdateSheetState extends State<UpdateSheet> {
  bool _busy = true;
  String _step = '正在检查…';
  String _error = '';
  Release? _release;
  String _source = '';
  final List<String> _failures = <String>[];

  bool get _newer =>
      _release != null && AppUpdate.isNewer(kAppVersionFull, _release!.version);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  Future<void> _check() async {
    if (TaskCenter.isBusy()) {
      setState(() {
        _busy = false;
        _error = '另一个任务正在运行，等它结束再检查';
      });
      return;
    }
    final RunningTask? task = TaskCenter.start('检查更新');
    if (task == null) {
      setState(() {
        _busy = false;
        _error = '任务没启动起来，请稍后再试';
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
      _release = null;
      _source = '';
      _failures.clear();
    });
    try {
      await _tryAll();
    } catch (e) {
      if (mounted) setState(() => _error = '检查过程中出错：$e');
    } finally {
      TaskCenter.finish();
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 按优先级依次尝试；失败原因逐条留下，最后一起展示。
  ///
  /// 国内优先：Gitee 清单 → Gitee 接口 → GitHub 清单 → GitHub 接口。
  Future<void> _tryAll() async {
    final UpdateOutcome out = await UpdateCheck.fetch(onStep: _report);
    if (!mounted) return;
    setState(() {
      _failures
        ..clear()
        ..addAll(out.failures);
      _source = out.source;
      _release = out.release;
      if (out.release == null) {
        _error = '四个来源都没拿到版本信息';
      }
    });
  }

  void _report(String step) {
    if (mounted) setState(() => _step = step);
  }

  @override
  Widget build(BuildContext context) {
    if (_busy) {
      return MoSheetScaffold(
        title: '检查更新',
        content: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 24, MoKit.pagePad, 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(height: 12),
                Text(_step,
                    style: TextStyle(
                        fontSize: MoKit.fsBody, color: MoKit.sub(context))),
              ],
            ),
          ),
        ],
      );
    }
    if (_error.isNotEmpty) {
      return MoSheetScaffold(
        title: '检查更新',
        content: <Widget>[_errorView()],
        // 固定底栏：失败原因再多也不影响重试
        footer: Row(
          children: <Widget>[
            MoButton('重试', icon: Icons.refresh, onPressed: _check),
            const SizedBox(width: 10),
            Expanded(
              child: MoButton('打开发布页',
                  primary: false,
                  onPressed: () => _open(Endpoints.urlOf('gitee', 1))),
            ),
          ],
        ),
      );
    }
    final Release r = _release!;
    return MoSheetScaffold(
      title: '检查更新',
      content: <Widget>[_resultView(r)],
      // 固定底栏：更新说明再长，「去下载」也一直点得到
      footer: _newer
          ? Row(
              children: <Widget>[
                Expanded(
                  child: MoButton('去下载',
                      icon: Icons.download,
                      onPressed: () => _open(_downloadUrl(r))),
                ),
                const SizedBox(width: 10),
                MoButton('发布页',
                    primary: false, onPressed: () => _open(_pageUrl(r))),
              ],
            )
          : null,
    );
  }

  Widget _errorView() {
    return SectionCard(
      title: '检查失败',
      subtitle: _error,
      children: <Widget>[
        for (final String f in _failures)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(f,
                style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.sub(context))),
          ),
        const SizedBox(height: 6),
        Text('当前版本 $kAppVersionFull',
            style: TextStyle(fontSize: MoKit.fsCaption, color: MoKit.faint(context))),
      ],
    );
  }

  Widget _resultView(Release r) {
    final String size = AppUpdate.humanSize(r.apkSize);
    final String notes = AppUpdate.shortNotes(r.notes, 8);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SectionCard(
          title: _newer ? '发现新版本' : '已是最新版本',
          subtitle: '来源：$_source',
          children: <Widget>[
            _kv('当前版本', kAppVersionFull),
            _kv('最新版本', r.display.isEmpty ? r.tag : r.display),
            _kv('安装包体积', size.isEmpty ? '未知' : size),
          ],
        ),
        SectionCard(
          title: '更新说明',
          children: <Widget>[
            Text(
              notes.isEmpty ? '这次发布没有填写说明' : notes,
              style: TextStyle(
                  fontSize: MoKit.fsBody, height: 1.5, color: MoKit.text(context)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _kv(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 78,
            child: Text(label,
                style: TextStyle(fontSize: MoKit.fsBody, color: MoKit.sub(context))),
          ),
          Expanded(
            child: Text(value,
                style: TextStyle(
                    fontSize: MoKit.fsBody,
                    fontWeight: FontWeight.w500,
                    color: MoKit.text(context))),
          ),
        ],
      ),
    );
  }

  /// 优先 APK 直链；清单没给就退回发布页。
  String _downloadUrl(Release r) {
    if (r.hasApk) return r.apkUrl;
    return _pageUrl(r);
  }

  String _pageUrl(Release r) {
    // 国内优先：清单/接口给的 page 若是 Gitee 就直接用，否则统一回 Gitee 发布页
    if (r.pageUrl.isNotEmpty && r.pageUrl.contains('gitee.com')) return r.pageUrl;
    return Endpoints.urlOf('gitee', 1);
  }

  Future<void> _open(String url) async {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null || url.isEmpty) {
      moSnack(context, '地址无效，无法打开：$url');
      return;
    }
    bool ok = false;
    try {
      ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
    if (!ok && mounted) {
      moSnack(context, '打不开浏览器，请手动复制地址：$url');
    }
  }
}
