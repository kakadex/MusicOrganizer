// ignore_for_file: file_names

/// 版本戳工具（骨架；T15 接入发布链）。
///
/// 职责：以 VERSION 文件为唯一真源，计算 lib/ 源码内容哈希（6 位），
/// 生成 `lib/core/version.dart`：
/// ```dart
/// const kAppVersionFull = 'X.Y.Z-abc123';
/// ```
///
/// 用法（项目根目录执行）：
/// ```bash
/// dart run tools/stamp-version.dart          # 写版本文件
/// dart run tools/stamp-version.dart --check  # 只校验不写（CI 可用）
/// ```
///
/// 约定（架构设计 §6 / 风险 R6）：pubspec 的 version 行只写 `X.Y.Z+NNN`
/// （build 号 = versionCode，必须为整数）；内容哈希后缀一律进本生成文件。
/// 进位规则 / MO_ALLOW_ANY_VERSION 逃生门等 T15 补齐。
library;

import 'dart:io';

/// 版本唯一真源。
const String kVersionFile = 'VERSION';

/// 参与哈希的源码目录。
const String kLibDir = 'lib';

/// 生成目标。
const String kOutputFile = 'lib/core/version.dart';

/// pubspec（读 build 号）。
const String kPubspecFile = 'pubspec.yaml';

/// 内容哈希长度。
const int kHashLength = 6;

/// FNV-1a 64 位参数。
const int _fnvOffsetBasis = 0xcbf29ce484222325;
const int _fnvPrime = 0x100000001b3;

/// 程序入口。
void main(List<String> args) {
  final bool checkOnly = args.contains('--check');

  final File versionFile = File(kVersionFile);
  if (!versionFile.existsSync()) {
    stderr.writeln('缺少 $kVersionFile（版本唯一真源）');
    exitCode = 2;
    return;
  }
  final String version = versionFile.readAsStringSync().trim();
  if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version)) {
    stderr.writeln('VERSION 格式应为 X.Y.Z，当前：$version');
    exitCode = 2;
    return;
  }

  final String hash = sourceHash();
  final String full = '$version-$hash';
  final int build = readBuildNumber();
  final String rendered = render(version, full, build);

  if (checkOnly) {
    final File out = File(kOutputFile);
    if (!out.existsSync() || out.readAsStringSync() != rendered) {
      stderr.writeln('版本文件过期，期望 $full；请运行 dart run tools/stamp-version.dart');
      exitCode = 1;
      return;
    }
    stdout.writeln('version check ok: $full (build $build)');
    return;
  }

  File(kOutputFile).writeAsStringSync(rendered);
  stdout.writeln('stamped $full (build $build) -> $kOutputFile');
}

/// 计算 lib/ 源码内容哈希（FNV-1a 64 位 → base36 → 末 6 位）。
///
/// 口径：递归收集 lib/ 下全部 `.dart`，按路径排序，依次混入
/// 「相对路径 + 0 字节 + 文件内容」——改文件名 / 改内容都会变。
String sourceHash() {
  final Directory root = Directory(kLibDir);
  if (!root.existsSync()) {
    stderr.writeln('缺少 $kLibDir 目录');
    exitCode = 2;
    return '000000';
  }
  final List<File> files = <File>[];
  for (final FileSystemEntity entity
      in root.listSync(recursive: true, followLinks: false)) {
    if (entity is File && entity.path.endsWith('.dart')) {
      files.add(entity);
    }
  }
  files.sort((File a, File b) => a.path.compareTo(b.path));

  int h = _fnvOffsetBasis;
  for (final File file in files) {
    final String rel = file.path.replaceAll('\\', '/');
    for (final int byte in rel.codeUnits) {
      h = _mix(h, byte);
    }
    h = _mix(h, 0);
    for (final int byte in file.readAsBytesSync()) {
      h = _mix(h, byte);
    }
  }
  final String encoded = (h & 0xFFFFFFFFFFFFFFFF).toRadixString(36);
  return encoded.length >= kHashLength
      ? encoded.substring(encoded.length - kHashLength)
      : encoded.padLeft(kHashLength, '0');
}

/// FNV-1a 单步混合（64 位回绕）。
int _mix(int h, int byte) =>
    ((h ^ byte) * _fnvPrime) & 0xFFFFFFFFFFFFFFFF;

/// 从 pubspec.yaml 读 build 号（`version: X.Y.Z+NNN`）；缺失返回 0。
int readBuildNumber() {
  final File pubspec = File(kPubspecFile);
  if (!pubspec.existsSync()) return 0;
  final RegExp re =
      RegExp(r'^version:\s*\d+\.\d+\.\d+\+(\d+)\s*$', multiLine: true);
  final Match? match = re.firstMatch(pubspec.readAsStringSync());
  return match == null ? 0 : int.parse(match.group(1)!);
}

/// 渲染 version.dart 内容。
String render(String version, String full, int build) {
  return '/// 应用版本（**生成文件，勿手改**）。\n'
      '///\n'
      '/// 由 `tools/stamp-version.dart` 依据 VERSION（唯一真源）+ lib/ 源码内容\n'
      '/// 哈希生成；内容哈希后缀（6 位）随源码变化。pubspec 的 version 行只放\n'
      '/// `X.Y.Z+NNN`（build 号 = versionCode，须为整数）—— 见架构设计 §6 / R6。\n'
      'library;\n'
      '\n'
      "/// 完整版本串：`X.Y.Z-abc123`（UI 顶栏 / 设置页展示）。\n"
      "const String kAppVersionFull = '$full';\n"
      '\n'
      "/// 语义版本（与 VERSION 文件一致）。\n"
      "const String kAppVersion = '$version';\n"
      '\n'
      '/// 构建号（= versionCode = pubspec build 号）。\n'
      'const int kAppBuild = $build;\n';
}
