import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/ui_kit.dart';
import '../../core/net/http_client.dart';
import '../../core/source/endpoints.dart';
import '../../core/task/task_center.dart';
import '../../core/update/app_update.dart';
import '../../core/version.dart';

/// 检查更新面板：Gitee 清单 → GitHub 清单 → GitHub Release 接口，任一成功即用。
///
/// 不新增版本依赖：当前版本直接读 [kAppVersionFull]；下载统一交给浏览器。
class UpdateSheet extends StatefulWidget {
  const UpdateSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showMoSheet<void>(
      context,
      title: '检查更新',
      children: const <Widget>[UpdateSheet()],
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
  Future<void> _tryAll() async {
    Release? r = await _manifest(
        'Gitee 版本清单', Endpoints.urlOf('gitee', 0), Http.readTimeoutCnMs);
    r ??= await _manifest('GitHub 版本清单', Endpoints.urlOf('update', 3),
        Http.readTimeoutOverseasMs);
    r ??= await _api('GitHub Release 接口', Endpoints.urlOf('update', 0));
    if (!mounted) return;
    if (r == null) {
      setState(() => _error = '三步检查都没有拿到版本信息');
      return;
    }
    setState(() => _release = r);
  }

  Future<Release?> _manifest(String label, String url, int timeout) async {
    if (url.isEmpty) {
      _failures.add('$label：没有登记地址');
      return null;
    }
    _report('正在读取$label…');
    final String? text = await Http.getText(url, null, null, timeout);
    if (text == null) {
      _failures.add('$label：无法访问或超时（$url）');
      return null;
    }
    final Release? r = AppUpdate.parseManifest(text, url);
    if (r == null) {
      _failures.add('$label：返回内容不是有效的版本清单');
      return null;
    }
    _source = label;
    return r;
  }

  Future<Release?> _api(String label, String url) async {
    if (url.isEmpty) {
      _failures.add('$label：没有登记地址');
      return null;
    }
    _report('正在读取$label…');
    final Object? json = await Http.getJson(
      url,
      null,
      <String, String>{'Accept': 'application/vnd.github+json'},
      Http.readTimeoutOverseasMs,
    );
    if (json == null) {
      _failures.add('$label：无法访问、超时或返回为空');
      return null;
    }
    final Release? r = AppUpdate.parseRelease(json);
    if (r == null) {
      _failures.add('$label：响应里没有 tag_name（可能被限流）');
      return null;
    }
    _source = label;
    return r;
  }

  void _report(String step) {
    if (mounted) setState(() => _step = step);
  }

  @override
  Widget build(BuildContext context) {
    if (_busy) {
      return Padding(
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
                style: TextStyle(fontSize: MoKit.fsBody, color: MoKit.sub(context))),
          ],
        ),
      );
    }
    if (_error.isNotEmpty) return _errorView();
    return _resultView(_release!);
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
        const SizedBox(height: 10),
        Row(
          children: <Widget>[
            MoButton('重试', icon: Icons.refresh, onPressed: _check),
            const SizedBox(width: 10),
            Expanded(
              child: MoButton('打开发布页',
                  primary: false,
                  onPressed: () => _open(Endpoints.urlOf('update', 1))),
            ),
          ],
        ),
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
        if (_newer)
          Padding(
            padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 4, MoKit.pagePad, 16),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: MoButton('去下载',
                      icon: Icons.download, onPressed: () => _open(_downloadUrl(r))),
                ),
                const SizedBox(width: 10),
                MoButton('发布页',
                    primary: false, onPressed: () => _open(_pageUrl(r))),
              ],
            ),
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
    if (r.pageUrl.isNotEmpty) return r.pageUrl;
    return Endpoints.urlOf('update', 1);
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
