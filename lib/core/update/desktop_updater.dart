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
import 'dart:typed_data';

import '../log/log.dart';
import '../update/app_update.dart';
import 'sha256.dart';

/// 一次桌面更新的进度。
abstract final class DesktopUpdater {
  /// 校验下载回来的安装包是否与发布清单一致。
  ///
  /// 返回空串 = 通过；否则是「为什么拒绝」。
  /// [expectedSize] / [expectedSha256] 来自发布清单（`zipSize` / `zipSha256`），
  /// 都是可选的（老版本清单可能没写）；没给哪个就跳过哪项校验。
  static String verifyZip(Uint8List bytes,
      {int expectedSize = 0, String expectedSha256 = ''}) {
    if (expectedSize > 0 && bytes.length != expectedSize) {
      return '安装包大小不符：清单是 $expectedSize 字节，实际 ${bytes.length} 字节';
    }
    final String want = expectedSha256.trim().toLowerCase();
    if (want.isNotEmpty) {
      final String got = sha256Hex(bytes).toLowerCase();
      if (got != want) {
        return '安装包 SHA-256 校验失败（可能被篡改或下载不完整）';
      }
    }
    return '';
  }

  /// 清单里到底有没有给可校验的信息。
  static bool hasVerification(int size, String sha256) =>
      size > 0 || sha256.trim().isNotEmpty;

  /// 校验信息有多完整：0 = 都没有，1 = 只有一样，2 = 大小与哈希都有。
  static int verificationLevel(int size, String sha256) {
    final bool hasSize = size > 0;
    final bool hasSha = sha256.trim().isNotEmpty;
    if (hasSize && hasSha) return 2;
    if (hasSize || hasSha) return 1;
    return 0;
  }

  /// 这份清单需要用户先确认的提示文案；完整校验（不用问）时返回 null。
  ///
  /// 只给一项时仍要校验能给的那项，但**不能默默放行**：得告诉用户「内容没验过」，
  /// 让他自己决定装不装。两样都没有时更要说清楚「完全没校验」。
  static String? confirmTextFor(int size, String sha256) {
    switch (verificationLevel(size, sha256)) {
      case 2:
        return null;
      case 1:
        return size > 0
            ? '本次只校验了大小，未校验内容，是否继续安装？'
            : '本次只校验了内容指纹（SHA-256），未校验大小，是否继续安装？';
      default:
        return '本次未校验安装包（清单没提供大小与 SHA-256），是否继续安装？';
    }
  }

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
          // tar 解不了 zip，兜底要先试 bsdtar（它既能解 tar 也能解 zip）
          final ProcessResult bsdtar =
              await Process.run('bsdtar', <String>['-xf', zipPath, '-C', dest]);
          if (bsdtar.exitCode != 0) {
            return '解压失败：找不到 unzip / bsdtar，请先安装 unzip 再更新';
          }
          first = bsdtar;
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
        await bat.writeAsString(windowsApplyScript(from, to), flush: true);
        return bat.path;
      }
      final File sh = File('$dir${sep}mo-apply-update.sh');
      await sh.writeAsString(posixApplyScript(from, to), flush: true);
      await Process.run('chmod', <String>['+x', sh.path]);
      return sh.path;
    } catch (e) {
      Log.warn('写更新脚本失败：$e');
      return '';
    }
  }

  /// Windows 更新脚本内容（纯函数，可单测）。
  ///
  /// 复制失败（[errorlevel] 非 0）就**不重启、不删自己**，把失败写到日志文件，
  /// 否则用户只会看到「版本没变」却不知道是复制这一步挂了。
  static String windowsApplyScript(String from, String to) =>
      '@echo off\r\n'
      'timeout /t 2 /nobreak >nul\r\n'
      'xcopy /Y /E /I "$from\\*" "$to\\" >nul\r\n'
      'if errorlevel 1 (\r\n'
      '  echo 更新失败：复制文件出错 > "%TEMP%\\mo-update-failed.txt"\r\n'
      '  exit /b 1\r\n'
      ')\r\n'
      'start "" "$to\\$exeName"\r\n'
      'del "%~f0"\r\n';

  /// 类 Unix 更新脚本内容（纯函数，可单测）。
  ///
  /// 复制失败就停在原地：不重启、不删自己，日志写到临时目录。
  static String posixApplyScript(String from, String to) =>
      '#!/bin/sh\n'
      'sleep 2\n'
      'if ! cp -Rf "$from/." "$to/"; then\n'
      '  echo "update failed" > /tmp/mo-update-failed.txt\n'
      '  exit 1\n'
      'fi\n'
      'chmod +x "$to/$exeName" 2>/dev/null\n'
      'nohup "$to/$exeName" >/dev/null 2>&1 &\n'
      'rm -f "\$0"\n';

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
