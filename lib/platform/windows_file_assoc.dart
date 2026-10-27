/// Windows 文件关联：让双击音频直接进本应用。
///
/// 便携版不该偷偷改用户的系统设置，所以默认什么都不做，由用户在设置里手动开关。
/// 开启时把各扩展名**原来的默认程序**记下来，关闭时原样还回去——不还的话，
/// 用户取消关联后双击 mp3 会变成「找不到应用」。
library;

import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// 文件关联开关（仅 Windows）。
abstract final class WindowsFileAssoc {
  /// 只接管这几类音频，视频与播放列表不碰。
  static const List<String> exts = <String>[
    '.mp3', '.flac', '.m4a', '.wav', '.ogg', '.ape', '.opus', '.wv',
  ];

  /// 本应用在注册表里的程序标识。
  static const String progId = 'MusicOrganizer.Audio';

  static bool get supported => Platform.isWindows;

  static const String _base = r'HKCU\Software\Classes';

  /// 是否已经由本应用接管（以 .mp3 为准）。
  static Future<bool> isEnabled() async {
    if (!supported) return false;
    return await _queryDefault('$_base\\.mp3') == progId;
  }

  /// 开：注册 ProgID + 逐扩展名设为默认（先备份原值）。
  static Future<bool> enable() async {
    if (!supported) return false;
    final String exe = Platform.resolvedExecutable;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await _run(<String>[
      'add', '$_base\\$progId', '/ve', '/d', '音频文件', '/f',
    ]);
    await _run(<String>[
      'add', '$_base\\$progId\\DefaultIcon', '/ve', '/d', '"$exe",0', '/f',
    ]);
    await _run(<String>[
      'add', '$_base\\$progId\\shell\\open\\command', '/ve', '/d', '"$exe" "%1"', '/f',
    ]);
    for (final String ext in exts) {
      final String key = 'assoc_orig_$ext';
      final String? old = await _queryDefault('$_base\\$ext');
      if (old != null && old.isNotEmpty && old != progId) {
        await prefs.setString(key, old);
      }
      // 保留原程序在「打开方式」里的位置，别让它从列表里消失
      if (old != null && old.isNotEmpty && old != progId) {
        await _run(<String>[
          'add', '$_base\\$ext\\OpenWithProgids', '/v', old, '/t', 'REG_NONE', '/f',
        ]);
      }
      await _run(<String>['add', '$_base\\$ext', '/ve', '/d', progId, '/f']);
    }
    return isEnabled();
  }

  /// 关：把各扩展名的默认程序还原，再删掉自己的 ProgID。
  static Future<bool> disable() async {
    if (!supported) return false;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    for (final String ext in exts) {
      final String? old = prefs.getString('assoc_orig_$ext');
      if (old != null && old.isNotEmpty) {
        await _run(<String>['add', '$_base\\$ext', '/ve', '/d', old, '/f']);
        await prefs.remove('assoc_orig_$ext');
      } else if (await _queryDefault('$_base\\$ext') == progId) {
        // 原来就没有默认程序：删掉我们写的值，交还给系统
        await _run(<String>['delete', '$_base\\$ext', '/ve', '/f']);
      }
    }
    await _run(<String>['delete', '$_base\\$progId', '/f']);
    return !await isEnabled();
  }

  static Future<String?> _queryDefault(String key) async {
    final ProcessResult r =
        await Process.run('reg', <String>['query', key, '/ve']);
    if (r.exitCode != 0) return null;
    final RegExp m = RegExp(r'REG_SZ\s+(.+)$', multiLine: true);
    final RegExpMatch? match = m.firstMatch('${r.stdout}');
    return match?.group(1)?.trim();
  }

  static Future<void> _run(List<String> args) async {
    try {
      await Process.run('reg', args);
    } catch (_) {
      // 组策略限制下的机器可能连 HKCU 都写不了：交给调用方按失败处理
    }
  }
}
