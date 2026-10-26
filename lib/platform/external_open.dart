/// 外部调起：在文件管理器里「用本应用编辑 / 打开」音频。
///
/// 拿到的是系统给的 content uri，不属于任何已授权目录树，所以不能直接走 SAF 通道读写。
/// 这里的做法：先拿显示名 + 大小去已授权曲库里找，找得到就直接在编辑器里打开；
/// 找不到就提示用户授权它所在的目录（授权后重扫即可编辑）。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/repo.dart';
import '../app/ui_kit.dart';
import '../core/model/vfile.dart';
import '../feature/editor/editor_page.dart';

/// 外部调起处理。
abstract final class ExternalOpen {
  static const MethodChannel _ch = MethodChannel('com.dsh.musicorganizer/host');

  static bool _listening = false;

  /// 装上监听（main 里调一次）；应用已在前台时新 intent 从这里进来。
  static void listen(void Function(String uri) onUri) {
    if (_listening) return;
    _listening = true;
    _ch.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'onFileIntent') {
        final Object? uri = call.arguments;
        if (uri is String && uri.isNotEmpty) onUri(uri);
      }
      return null;
    });
  }

  /// 启动时带进来的文件 uri（没有返回 null）。
  static Future<String?> takeInitialIntent() async {
    if (kIsWeb) return null;
    try {
      return await _ch.invokeMethod<String>('takeInitialIntent');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// 文件的显示名与大小。
  static Future<Map<String, Object?>?> uriInfo(String uri) async {
    if (kIsWeb) return null;
    try {
      final Map<Object?, Object?>? m =
          await _ch.invokeMethod<Map<Object?, Object?>>('uriInfo', <String, Object?>{'uri': uri});
      if (m == null) return null;
      return m.map((Object? k, Object? v) => MapEntry<String, Object?>('$k', v));
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// 处理一个外部 uri：找到就开编辑器，找不到引导授权目录。
  static Future<void> handle(BuildContext context, String uri) async {
    final Map<String, Object?>? info = await uriInfo(uri);
    final String name = (info?['name'] as String?) ?? '';
    final int size = (info?['size'] as int?) ?? 0;
    if (!context.mounted) return;

    VFile? hit;
    for (final VFile f in Repo.instance.files) {
      if (f.dir) continue;
      if (f.name == name && (size == 0 || f.size == size)) {
        hit = f;
        break;
      }
    }
    if (hit != null) {
      await EditorPage.show(context, hit);
      return;
    }
    // 曲库里没有：引导用户授权所在目录
    await showMoSheet<bool>(
      context,
      title: '打开外部文件',
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 0, MoKit.pagePad, 8),
          child: Text(
            name.isEmpty ? '收到了一个音频文件' : '收到「$name」',
            style: TextStyle(fontSize: MoKit.fsBody, color: MoKit.text(context)),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(MoKit.pagePad, 0, MoKit.pagePad, 8),
          child: Text(
            '它不在当前曲库里。授权它所在的目录后就能编辑（也可以先把目录设成曲库）。',
            style: TextStyle(fontSize: MoKit.fsCaption),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(MoKit.pagePad),
          child: MoButton('选择目录', onPressed: () => Navigator.of(context).pop(true)),
        ),
      ],
    );
    if (!context.mounted) return;
    if (await Repo.instance.pickRoot()) {
      await Repo.instance.rescan();
      await Repo.instance.loadMeta();
    }
  }
}
