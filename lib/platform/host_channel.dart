/// 宿主（MainActivity）通道：不属于 SAF 的那几个平台动作。
///
/// 目前只有「把一段文本保存到用户选的位置」——安卓的应用私有目录用户根本看不到，
/// 导出日志必须落到下载 / 文档这类用户能打开的地方。
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
