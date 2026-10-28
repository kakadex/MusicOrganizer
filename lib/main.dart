import 'dart:async';
import 'dart:ui';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app/mo_app.dart';
import 'app/repo.dart';
import 'app/theme/palette.dart';
import 'app/theme/theme_controller.dart';
import 'core/log/log.dart';
import 'feature/crash/crash_screen.dart';
import 'platform/external_open.dart';

/// 应用入口：初始化全局仓库 → 恢复主题 → 挂载 [MoApp]。
Future<void> main(List<String> args) async {
  // 桌面端双击音频时，系统把文件路径作为启动参数传进来（安卓走 intent，不用这个）
  ExternalOpen.rememberLaunchArgs(args);
  WidgetsFlutterBinding.ensureInitialized();
  // 全局错误处理：记日志 + 弹崩溃页，别让 app 直接崩掉。
  //
  // 同一个异常可能被框架回调与平台回调各送一次（尤其异步 Zone 里的），不去重
  // 会出现「同一条错误报两遍、崩溃页叠两层」。另外 details.stack 允许为 null
  // （某些框架构造的错误没有栈），这里补一条当前栈，保证日志与崩溃页有据可查。
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    _reportOnce(details.exception, details.stack);
  };
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    _reportOnce(error, stack);
    return true;
  };
  ErrorWidget.builder = (FlutterErrorDetails details) {
    final String text = Log.sanitize(details.exceptionAsString());
    return Material(
      color: const Color(0xFF1B1B1F),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                '这个界面画不出来：\n$text',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFFE6E1E5), fontSize: 13),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Clipboard.setData(ClipboardData(text: text)),
                child: const Text('复制错误信息'),
              ),
            ],
          ),
        ),
      ),
    );
  };

  try {
    await Log.init();
    final Repo repo = Repo.instance;
    // 桌面端：系统目录选择器要在 init **之前**挂上——init 里恢复上次目录时
    // 可能就要用它，晚了会出现「该选目录却没有选择器」。
    if (Repo.isDesktop) {
      Repo.desktopDirectoryPicker = () => getDirectoryPath();
    }
    await repo.init();

    // 主题：上次选的方案与明暗（存在 SharedPreferences 里，repo 初始化时已读回）
    final int themeId = repo.settings.get<int>('theme_id', fallback: 1) ?? 1;
    final bool dark = repo.settings.get<bool>('theme_dark', fallback: false) ?? false;
    final ThemeController controller = ThemeController(
      themeId: MoThemeId.values[themeId.clamp(0, MoThemeId.values.length - 1)],
      dark: dark,
    );
    repo.themeController = controller;

    runApp(MoApp(themeController: controller));
  } catch (e, st) {
    // 初始化链上的异常不会被 FlutterError.onError 捕获：必须自己兜住并
    // runApp 一个可读的失败页，否则用户看到的是纯白屏、日志也未必有。
    Log.error('应用启动失败', e: e, stack: st);
    runApp(_BootFailureApp(error: Log.sanitize('$e')));
  }
}

/// 同一条错误只上报一次（去重窗口内重复到达的直接丢掉）。
///
/// 判重用「错误对象身份 + 首行文本」：同一个异常对象被两条通道送到时身份相同；
/// 不同对象但文案一致（重抛包装）时也按同一条处理，避免崩溃页叠两层。
final Map<Object, DateTime> _seenErrors = <Object, DateTime>{};
String? _lastErrorText;
DateTime? _lastErrorAt;
const Duration _dedupeWindow = Duration(milliseconds: 800);

void _reportOnce(Object error, StackTrace? stack) {
  final DateTime now = DateTime.now();
  final DateTime? first = _seenErrors[error];
  if (first != null && now.difference(first) < _dedupeWindow) return;
  final String text = '$error'.split('\n').first.trim();
  if (_lastErrorText == text &&
      _lastErrorAt != null &&
      now.difference(_lastErrorAt!) < _dedupeWindow) {
    return;
  }
  _seenErrors[error] = now;
  if (_seenErrors.length > 64) _seenErrors.clear();
  _lastErrorText = text;
  _lastErrorAt = now;
  CrashScreen.report(error, stack ?? StackTrace.current);
}

/// 启动失败页：初始化抛异常时至少让用户看到原因、能复制。
class _BootFailureApp extends StatelessWidget {
  const _BootFailureApp({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(Icons.error_outline, size: 40),
                  const SizedBox(height: 12),
                  const Text('应用启动失败',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  SelectableText(error,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 12)),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () =>
                        Clipboard.setData(ClipboardData(text: error)),
                    icon: const Icon(Icons.copy),
                    label: const Text('复制错误信息'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
