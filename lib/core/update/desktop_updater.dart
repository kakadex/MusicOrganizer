/// 桌面端自动更新：下载 zip → 解压 → 用外部脚本替换正在运行的程序 → 重启。
///
/// 为什么非要绕一圈脚本：**正在运行的 exe 没法自己覆盖自己**（Windows 会锁文件）。
/// 所以做法是「把新版本解到临时目录 → 写一个等进程退出再动手的脚本 → 启动脚本
/// 并立刻退出自己」，替换与重启都由脚本完成。
///
/// 每一步都可失败、失败就停在原地并给出可手动完成的说明：
/// 下载失败 → 提示去发布页；解压失败 → 提示已下载到哪、自己解；替换失败 →
/// 新版本已经躺在临时目录里，用户手动拷过去就行。绝不留下「新旧夹杂」的半吊子。
library;

import 'dart:io';

import '../log/log.dart';
import '../update/app_update.dart';

/// 一次桌面更新的进度。
abstract final class DesktopUpdater {
  /// 当前平台能不能自动更新（只有 Windows / Linux / macOS 桌面端可以）。
  static bool get supported =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  /// 本程序的安装目录（exe 所在目录），也是要被替换的目录。
  static String get appDir {
    final String exe = Platform.resolvedExecutable;
    final int cut = exe.lastIndexOf(Platform.pathSeparator);
    return cut <= 0 ? exe : exe.substring(0, cut);
  }

  /// 本程序的文件名（重启时用来定位）。
  static String get appFileName {
    final String exe = Platform.resolvedExecutable;
    final int cut = exe.lastIndexOf(Platform.pathSeparator);
    return cut < 0 ? exe : exe.substring(cut + 1);
  }

  /// 新版本解压到哪（临时目录下的独立子目录）。
  static String stagingDir(String version) =>
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'mo-update-${version.replaceAll(RegExp(r'[^0-9A-Za-z.-]'), '_')}';

  /// 解压：优先用系统自带的解压能力，都没有就返回失败（交给调用方提示手动解压）。
  ///
  /// Windows 用 PowerShell 的 Expand-Archive（系统自带、不用装东西）；
  /// 类 Unix 依次试 unzip 与 tar（macOS 有 tar 不一定有 unzip）。
  static Future<String> extract(String zipPath, String dest) async {
    final Directory dir = Directory(dest);
    try {
      if (!await dir.exists()) await dir.create(recursive: true);
    } catch (e) {
      return '建不了解压目录：$e';
    }
    try {
      final ProcessResult r;
      if (Platform.isWindows) {
        r = await Process.run('powershell', <String>[
          '-NoProfile',
          '-Command',
          'Expand-Archive -Force -LiteralPath "$zipPath" -DestinationPath "$dest"',
        ]);
      } else {
        ProcessResult first = await Process.run('unzip', <String>['-oq', zipPath, '-d', dest]);
        if (first.exitCode != 0) {
          first = await Process.run('tar', <String>['-xf', zipPath, '-C', dest]);
        }
        r = first;
      }
      if (r.exitCode != 0) {
        final String why = '${r.stderr}'.trim();
        return '解压失败${why.isEmpty ? '' : '：$why'}';
      }
    } catch (e) {
      return '解压失败：$e';
    }
    return '';
  }

  /// 生成更新脚本：等本程序退出 → 把新版本拷进安装目录 → 重启 → 自删。
  ///
  /// 返回脚本路径；写不出来返回空串（调用方提示手动替换）。
  static Future<String> writeApplyScript(String from, String to) async {
    final String dir = Directory.systemTemp.path;
    final String sep = Platform.pathSeparator;
    try {
      if (Platform.isWindows) {
        final File bat = File('$dir${sep}mo-apply-update.bat');
        // 先等 2 秒：父进程退出、文件锁释放要一点时间，抢着拷会半途失败
        await bat.writeAsString(
            '@echo off\r\n'
            'timeout /t 2 /nobreak >nul\r\n'
            'xcopy /Y /E /I "$from\\*" "$to\\" >nul\r\n'
            'start "" "$to\\$exeName"\r\n'
            'del "%~f0"\r\n',
            flush: true);
        return bat.path;
      }
      final File sh = File('$dir${sep}mo-apply-update.sh');
      await sh.writeAsString(
          '#!/bin/sh\n'
          'sleep 2\n'
          'cp -Rf "$from/." "$to/"\n'
          'chmod +x "$to/$exeName" 2>/dev/null\n'
          'nohup "$to/$exeName" >/dev/null 2>&1 &\n'
          'rm -f "\$0"\n',
          flush: true);
      await Process.run('chmod', <String>['+x', sh.path]);
      return sh.path;
    } catch (e) {
      Log.warn('写更新脚本失败：$e');
      return '';
    }
  }

  static String get exeName => appFileName;

  /// 启动脚本并退出本程序（这一步之后进程就结束了）。
  static Future<bool> launchAndExit(String script) async {
    try {
      if (Platform.isWindows) {
        await Process.start('cmd', <String>['/c', script],
            mode: ProcessStartMode.detached);
      } else {
        await Process.start('/bin/sh', <String>[script],
            mode: ProcessStartMode.detached);
      }
    } catch (e) {
      Log.warn('启动更新脚本失败：$e');
      return false;
    }
    return true;
  }

  /// 这条 Release 有没有桌面版安装包（没有就别显示「自动更新」）。
  static bool hasDesktopPackage(Release r) => r.hasZip;

  /// 从清单 / Release 里挑出桌面版下载地址。
  static String zipUrlOf(Release r) => r.zipUrl;

  /// 解压出来的东西到底是不是一个能跑的程序（至少要有可执行文件）。
  ///
  /// 光「解压没报错」不够：万一 zip 里是别的目录结构，直接覆盖安装目录会把
  /// 程序搞坏。这里要求**至少有一个可执行文件**，否则宁可停下让用户手动来。
  static bool stagingLooksRunnable(String stage) {
    try {
      final Directory dir = Directory(stage);
      if (!dir.existsSync()) return false;
      final bool Function(String) isExe = Platform.isWindows
          ? (String n) => n.toLowerCase().endsWith('.exe')
          : (String n) => !n.contains('.');
      for (final FileSystemEntity e in dir.listSync(recursive: true)) {
        if (e is! File) continue;
        final String name = e.path.substring(e.path.lastIndexOf(Platform.pathSeparator) + 1);
        if (isExe(name)) return true;
      }
    } catch (_) {}
    return false;
  }
}
