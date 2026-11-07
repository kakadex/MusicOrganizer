import 'dart:async';
import 'dart:ui';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app/mo_app.dart';
import 'app/repo.dart';
import 'app/theme/font_scale.dart';
import 'app/theme/mo_theme.dart';
import 'app/theme/palette.dart';
import 'app/theme/theme_controller.dart';
import 'core/log/log.dart';
import 'feature/crash/crash_screen.dart';
import 'platform/appearance.dart';
import 'platform/external_open.dart';
import 'platform/system_colors.dart';

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
      color: MoPalette.light.bg,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                '这个界面画不出来：\n$text',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: MoPalette.light.body, fontSize: 13),
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

    // 外观（0.3.17）：三态「跟随系统 / 浅色 / 深色」。旧键 theme_id / theme_dark
    // 已在 repo.init() 里由 migrateThemeMode() 迁移成 theme_mode。
    //
    // 动态色只有 Android 12+ 有；Windows / 低版本返回 null → 固定中性色板，
    // 明暗仍跟随系统（这是预期行为，不是降级失败）。
    final SystemPaletteSet? systemPalette = await SystemColors.fetch();
    final String themeModeName =
        repo.settings.get<String>('theme_mode', fallback: 'system') ?? 'system';
    final ThemeMode startMode = <String, ThemeMode>{
          'system': ThemeMode.system,
          'light': ThemeMode.light,
          'dark': ThemeMode.dark,
        }[themeModeName] ??
        ThemeMode.system;
    final ThemeController controller = ThemeController(
      mode: startMode,
      systemPalette: systemPalette,
    );
    repo.themeController = controller;

    // Windows：① 标题栏深浅跟随应用（否则系统浅色 + 应用深色时标题栏是白的）；
    // ② 系统切深浅时原生侧推回来，让「跟随系统」即时生效。
    if (Repo.isDesktop) {
      final bool? sysDark = await AppearanceBridge.systemDark();
      if (sysDark != null) controller.setSystemDark(sysDark);
      // 探针（修完保留）：标题栏与系统明暗只有真机才能验，记两行好对的日志。
      // 只记状态，不记路径 / 用户名（日志脱敏规矩）。
      Log.info('[Appearance] 启动：系统深色=${sysDark ?? '未知'} '
          '外观模式=${startMode.name} 动态色=${systemPalette == null ? '无' : '有'}');
      AppearanceBridge.listenSystemTheme((bool dark) {
        Log.info('[Appearance] 系统明暗变化 → ${dark ? '深色' : '浅色'}');
        controller.setSystemDark(dark);
      });
      bool? lastTitleDark;
      void syncTitleBar() {
        final bool? d = controller.effectiveDark;
        if (d == lastTitleDark) return;
        lastTitleDark = d;
        Log.info('[Appearance] 标题栏 → ${d == null ? '跟随系统' : (d ? '深色' : '浅色')}');
        unawaited(AppearanceBridge.setDarkTitleBar(d));
      }

      controller.addListener(syncTitleBar);
      syncTitleBar();
    }

    // 字体缩放（0.3.9）：从设置读回；没存过就用平台默认值
    // （桌面 115%——Windows 上 13px 正文偏小；手机 100%）。
    final double? savedScale = repo.settings.get<double>('font_scale');
    FontScale.instance.set(savedScale ??
        (Repo.isDesktop ? FontScale.desktopDefaultScale : FontScale.defaultScale));

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
      // 启动失败页也带主题：否则默认 Material 白底 + 深色系统里一片刺白。
      theme: MoTheme.build(MoPalette.light, dark: false),
      darkTheme: MoTheme.build(MoPalette.dark, dark: true),
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
