import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/ui_kit.dart';
import '../../core/log/log.dart';
import '../../core/net/http_client.dart';
import '../../core/source/endpoints.dart';
import '../../core/task/task_center.dart';
import '../../core/update/app_update.dart';
import '../../core/update/desktop_updater.dart';
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
  /// 桌面版 zip 的下载上限（200MB：正常版本几十 MB，留足余量）。
  static const int _maxZipBytes = 200 * 1024 * 1024;

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
                  child: MoButton(
                      _canSelfUpdate ? '下载并更新' : '去下载',
                      icon: Icons.download,
                      onPressed: _canSelfUpdate
                          ? () => _updateNow(r)
                          : () => _open(_downloadUrl(r))),
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

  /// 桌面端能不能就地更新（有 zip、且是桌面平台）。
  bool get _canSelfUpdate => DesktopUpdater.supported && (_release?.hasZip ?? false);

  /// 桌面端「下载 → 解压 → 替换 → 重启」。
  ///
  /// 自己覆盖自己是不行的（Windows 锁着 exe），所以最后一步交给脚本：
  /// 脚本等本程序退出后把新版本拷进安装目录、重启程序、再把自己删掉。
  Future<void> _updateNow(Release r) async {
    if (TaskCenter.isBusy()) {
      moSnack(context, '另一个任务正在运行，等它结束再更新');
      return;
    }
    final RunningTask? task = TaskCenter.start('下载更新');
    if (task == null) return;
    setState(() {
      _busy = true;
      _step = '正在下载桌面版…';
    });
    Uint8List? bytes;
    String stage = '';
    try {
      bytes = await Http.getBytes(
          r.zipUrl, null, null, Http.readTimeoutCnMs, _maxZipBytes);
      task.control.report(1, 3, '下载完成');
      if (!mounted) return;
      if (bytes == null || bytes.isEmpty) {
        setState(() {
          _busy = false;
          _error = '下载失败：${Http.lastError.isEmpty ? '没有拿到内容' : Http.lastError}';
        });
        return;
      }
      setState(() => _step = '正在解压…');
      final String tmp = Directory.systemTemp.path;
      final String sep = Platform.pathSeparator;
      final File zip = File('$tmp${sep}mo-update-${r.version}.zip');
      await zip.writeAsBytes(bytes, flush: true);
      // 解压之前先校验安装包：清单给了哪项就校验哪项，不符直接拒绝。
      // 只有「大小 + SHA-256 都有」才算完整校验；只给一项或都没给时，
      // 要把「哪项没验」说清楚，让用户自己决定装不装。
      final int level =
          DesktopUpdater.verificationLevel(r.zipSize, r.zipSha256);
      if (level > 0) {
        final String vErr = DesktopUpdater.verifyZip(bytes,
            expectedSize: r.zipSize, expectedSha256: r.zipSha256);
        if (vErr.isNotEmpty) {
          try {
            await zip.delete();
          } catch (_) {}
          if (!mounted) return;
          setState(() {
            _busy = false;
            _error = '$vErr。已删除临时包，请手动到发布页下载';
          });
          return;
        }
      }
      final String? ask =
          DesktopUpdater.confirmTextFor(r.zipSize, r.zipSha256);
      if (ask != null) {
        if (!mounted) return;
        final bool? go = await showDialog<bool>(
          context: context,
          builder: (BuildContext ctx) => AlertDialog(
            title: const Text('安装包校验不完整'),
            content: Text(ask),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('先不装'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('继续安装'),
              ),
            ],
          ),
        );
        if (go != true) {
          try {
            await zip.delete();
          } catch (_) {}
          if (!mounted) return;
          setState(() {
            _busy = false;
            _error = '已取消安装（安装包校验不完整）';
          });
          return;
        }
        Log.warn('桌面更新：$ask（用户选择继续）');
      } else {
        Log.info('桌面更新：安装包已完整校验（大小 + SHA-256）');
      }
      stage = DesktopUpdater.stagingDir(r.version);
      final String err = await DesktopUpdater.extract(zip.path, stage);
      if (err.isNotEmpty) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error = '$err（已下载到 ${zip.path}，也可以手动解压覆盖）';
        });
        return;
      }
      if (!DesktopUpdater.stagingLooksRunnable(stage)) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error = '解压出来的内容不像一个可运行的程序，已停手（新版本在 $stage）';
        });
        return;
      }
      setState(() => _step = '正在准备替换…');
      final String script =
          await DesktopUpdater.writeApplyScript(stage, DesktopUpdater.appDir);
      if (script.isEmpty) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error = '写不了更新脚本，请手动把 $stage 里的文件覆盖到 ${DesktopUpdater.appDir}';
        });
        return;
      }
      final bool started = await DesktopUpdater.launchAndExit(script);
      if (!started) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error = '启动更新脚本失败，请手动把 $stage 里的文件覆盖到 ${DesktopUpdater.appDir}';
        });
        return;
      }
      // 脚本已经接手：立刻退出自己，把文件锁让出来
      exit(0);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '更新失败：$e';
      });
    } finally {
      TaskCenter.finish();
    }
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
