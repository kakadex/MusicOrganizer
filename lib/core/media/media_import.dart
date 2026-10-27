/// 系统媒体库（安卓 MediaStore）：把设备上散落的曲目导入曲库。
///
/// 与「选择目录」不同：这条不申请任何权限，直到用户明确点「从系统媒体库导入」才申请
/// 读取音频的权限。桌面端没有 MediaStore，直接返回空。
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../fs/file_store.dart';
import '../fs/tree_ref.dart';
import '../model/vfile.dart';
import '../../platform/saf_channel.dart';

/// 媒体库里的一条音频。
class MediaTrack {
  MediaTrack({
    required this.id,
    required this.uri,
    required this.name,
    required this.artist,
    required this.album,
    required this.title,
    required this.durationMs,
    required this.size,
    required this.mime,
    this.relativePath = '',
  });

  final int id;
  final String uri;
  final String name;
  final String artist;
  final String album;
  final String title;
  final int durationMs;
  final int size;
  final String mime;

  /// 系统相对路径（如 `Music/周杰伦/`）；用来判断是否已在曲库目录里。
  final String relativePath;

  /// 列表里显示的一行。
  String display() {
    final String a = artist.isEmpty ? '未知歌手' : artist;
    final String t = title.isEmpty ? name : title;
    return '$t · $a';
  }

  /// 从平台通道的原始 map 构造。
  static MediaTrack fromMap(Map<String, Object?> m) => MediaTrack(
        id: (m['id'] as int?) ?? 0,
        uri: (m['uri'] as String?) ?? '',
        name: (m['name'] as String?) ?? '',
        artist: (m['artist'] as String?) ?? '',
        album: (m['album'] as String?) ?? '',
        title: (m['title'] as String?) ?? '',
        durationMs: (m['durationMs'] as int?) ?? 0,
        size: (m['size'] as int?) ?? 0,
        mime: (m['mime'] as String?) ?? '',
        relativePath: (m['relativePath'] as String?) ?? '',
      );

  /// 是否落在某个曲库目录内（`rootDocId` 形如 `primary:Music`）。
  bool insideRoot(String rootDocId) {
    final String path = relativePath;
    if (path.isEmpty) return false;
    final int colon = rootDocId.indexOf(':');
    final String rel = colon >= 0 ? rootDocId.substring(colon + 1) : rootDocId;
    final String dir = rel.endsWith('/') ? rel : '$rel/';
    return path == rel || path.startsWith(dir);
  }
}

/// 媒体库导入。
abstract final class MediaImport {
  /// 导入目录名（放在曲库根下）。
  static const String folderName = '导入';

  /// 最短时长（毫秒）：太短的多是提示音，不算歌。
  static const int minDurationMs = 10 * 1000;

  /// 当前平台是否支持（只有安卓有 MediaStore）。
  static bool get supported => !Platform.isWindows && !Platform.isMacOS && !Platform.isLinux;

  /// 申请权限；已授权或用户同意返回 true。
  static Future<bool> ensurePermission() async {
    if (!supported) return false;
    return await SafChannel().requestAudioPermission();
  }

  /// 扫媒体库里的音频。
  static Future<List<MediaTrack>> scan() async {
    if (!supported) return <MediaTrack>[];
    final List<Map<String, Object?>> raw =
        await SafChannel().mediaStoreAudio(minDurationMs);
    return <MediaTrack>[for (final Map<String, Object?> m in raw) MediaTrack.fromMap(m)];
  }

  /// 把一条曲目复制进曲库根下的「导入/」目录。
  ///
  /// 返回空串表示成功，否则是失败原因。
  static Future<String> importOne(
      FileStore store, TreeRef root, MediaTrack track) async {
    if (track.uri.isEmpty) return '这条没有可读的位置';
    try {
      // 目标目录：导入/<歌手>/
      String artist = track.artist.trim();
      if (artist.isEmpty) artist = '未知歌手';
      artist = _safeSegment(artist);
      final VFile dir = await _ensureDir(store, root, '$folderName/$artist');
      final VFile target = await store.createFile(dir, track.name, track.mime);
      final Directory tmp = await getTemporaryDirectory();
      final File tmpFile = File('${tmp.path}/import-${track.id}');
      await SafChannel().copyMediaToCache(track.uri, tmpFile.path);
      await store.writeFromLocal(target, tmpFile);
      try {
        await tmpFile.delete();
      } catch (_) {
        // 临时文件删不掉不影响导入结果
      }
      return '';
    } catch (e) {
      return '$e';
    }
  }

  static Future<VFile> _ensureDir(
      FileStore store, TreeRef root, String path) async {
    VFile cur = VFile(
        docId: root.rootDocId,
        parentId: null,
        name: root.rootDocId.split('/').last,
        dir: true);
    for (final String seg in path.split('/')) {
      if (seg.isEmpty) continue;
      final VFile? exist = await store.stat('${cur.docId}/$seg');
      cur = exist ?? await store.createDir(cur, seg);
    }
    return cur;
  }

  /// 目录名合法化（去掉路径分隔符与控制字符）。
  static String _safeSegment(String raw) {
    final StringBuffer sb = StringBuffer();
    for (final int c in raw.trim().codeUnits) {
      if (c < 0x20 || '/\\:*?"<>|'.codeUnits.contains(c)) {
        sb.write(' ');
      } else {
        sb.writeCharCode(c);
      }
    }
    String s = sb.toString().replaceAll(RegExp(r'\s{2,}'), ' ').trim();
    if (s.isEmpty || s == '.' || s == '..') return '未知歌手';
    if (s.length > 60) s = s.substring(0, 60).trim();
    return s;
  }
}
