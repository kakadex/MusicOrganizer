/// 宿主（MainActivity）通道：不属于 SAF 的那几个平台动作。
///
/// 目前有「把一段文本保存到用户选的位置」和「应用内更新装包」两组——
/// 安卓的应用私有目录用户根本看不到，导出日志必须落到用户能打开的地方；
/// 装 APK 也必须走宿主（Flutter 侧拿不到 FileProvider 授权）。
library;

import 'package:flutter/services.dart';

const MethodChannel kHostChannel = MethodChannel('com.dsh.musicorganizer/host');

/// 保存文本到用户选的位置；true=已保存，false=取消或失败。
Future<bool> exportTextToUser({
  required String name,
  required String text,
}) async {
  try {
    final bool? ok = await kHostChannel.invokeMethod<bool>(
      'exportText',
      <String, Object?>{'name': name, 'text': text},
    );
    return ok == true;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}

/// 应用内更新的下载目录（绝对路径）；拿不到返回空串。
///
/// 用宿主返回而不是 Dart 侧拼路径：安卓上正确的可写目录是
/// `context.getCacheDir()/updates`，Dart 侧没有可靠的等价写法；
/// 而且 FileProvider 的白名单必须与这个目录严格对应。
Future<String> updateDownloadDir() async {
  try {
    final String? dir =
        await kHostChannel.invokeMethod<String>('updateDir');
    return dir ?? '';
  } on MissingPluginException {
    return '';
  } on PlatformException {
    return '';
  }
}

/// 拉起系统安装器安装 [path] 处的 APK；true=已拉起安装界面。
///
/// 平台侧会校验该路径确实位于 [updateDownloadDir] 之内，防止被诱导安装
/// 任意位置的 APK。失败（文件不存在 / 系统拒绝）返回 false。
Future<bool> installApk(String path) async {
  if (path.isEmpty) return false;
  try {
    final bool? ok = await kHostChannel.invokeMethod<bool>(
      'installApk',
      <String, Object?>{'path': path},
    );
    return ok == true;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}
