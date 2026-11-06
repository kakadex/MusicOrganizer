/// 封面缩略图的**打包存储格式**（0.2.93）。
///
/// ## 为什么要换掉「一歌一文件」
///
/// 0.2.87–0.2.92 用的是一个文件存一张缩略图（文件名是 docId 的哈希）。
/// 在安卓 SAF 上每读一张都是一次**跨进程调用**，920 首就是 920 次；实测
/// 缩略图平均 37.8KB，单张读盘的开销远大于数据本身。这就是「快速滑动时
/// 来不及出图」的物理原因——缓存策略再调都没用。
///
/// ## 新格式
///
/// 所有缩略图打进**一个文件**，启动时顺序读一次进内存，之后取任意一张
/// 都是内存切片（零 IO）。文件布局：
///
/// ```
/// [magic 8B][version 4B][count 4B]
/// [索引区 count × entry]
///   entry = idLen(2B) + docId + keyLen(2B) + key + offset(8B) + len(4B)
/// [数据区：所有缩略图字节首尾相接]
/// ```
///
/// 索引里的「键」是 `docId` + `\u0000` + `size` + `\u0000` + `lastModified`：
/// 文件一变键就变，查不到就算过期（自然失效，不需要维护失效名单）。
///
/// 这个类只做**纯字节编解码**，不碰磁盘、不碰 Flutter，便于离线单测。
library;

import 'dart:convert';
import 'dart:typed_data';

import '../model/vfile.dart';

/// 一条索引项：某个 docId 的缩略图在数据区的位置。
class ThumbIndexEntry {
  const ThumbIndexEntry({
    required this.docId,
    required this.offset,
    required this.length,
  });

  final String docId;
  final int offset;
  final int length;
}

/// 读回来的打包内容：索引 + 数据区。
class ThumbPack {
  const ThumbPack({required this.entries, required this.keys});

  /// docId → 该曲目的缩略图字节（只含有效的）。
  final Map<String, Uint8List> entries;

  /// 打包里记录的每条 docId 对应的键（docId + size + mtime），用于判断过期。
  final Map<String, String> keys;

  /// 打包内实际包含的条目数。
  int get count => entries.length;

  /// 根据当前文件状态判断这条是否还有效。
  bool isFresh(VFile f) {
    final String? stored = keys[f.docId];
    return stored != null && stored == ThumbPackCodec.keyOf(f);
  }
}

/// 打包格式的编解码。
abstract final class ThumbPackCodec {
  /// 文件头魔数：`MOCOVERT`（音乐整理封面）。识别自己的文件，避免读错。
  static const List<int> magic = <int>[0x4D, 0x4F, 0x43, 0x4F, 0x56, 0x45, 0x52, 0x54];

  /// 格式版本。改动布局时递增，旧文件会被当「格式不认识」整体重建。
  static const int version = 1;

  /// 单条 docId 最长字节数（docId 是 SAF 的 document id，实测很少超过 200B）。
  static const int maxDocIdBytes = 1024;

  /// 键：docId + 尺寸 + 修改时间。任一变化都视为过期。
  static String keyOf(VFile f) => '${f.docId}\u0000${f.size}\u0000${f.lastModified}';

  /// 把一组「docId → 缩略图字节」编成打包字节。
  ///
  /// [keys] 与 [blobs] 必须一一对应（同一批 docId）。
  static Uint8List encode({
    required Map<String, String> keys,
    required Map<String, Uint8List> blobs,
  }) {
    final List<String> docIds = <String>[
      for (final String id in blobs.keys)
        if (blobs[id]!.isNotEmpty && (keys[id]?.isNotEmpty ?? false)) id,
    ]..sort();

    // 先算索引区大小，才能知道数据区从哪开始
    int indexBytes = 0;
    final List<Uint8List> idBytes = <Uint8List>[];
    final List<Uint8List> keyBytes = <Uint8List>[];
    for (final String id in docIds) {
      final Uint8List ib = utf8.encode(id);
      final Uint8List kb = utf8.encode(keys[id]!);
      idBytes.add(ib);
      keyBytes.add(kb);
      // idLen(2) + id + keyLen(2) + key + offset(8) + len(4)
      indexBytes += 2 + ib.length + 2 + kb.length + 8 + 4;
    }

    const int headerBytes = 8 + 4 + 4; // magic + version + count
    int offset = headerBytes + indexBytes;
    final BytesBuilder out = BytesBuilder(copy: false);
    out.add(magic);
    out.add(_u32(version));
    out.add(_u32(docIds.length));

    for (int i = 0; i < docIds.length; i++) {
      final Uint8List b = blobs[docIds[i]]!;
      final Uint8List ib = idBytes[i];
      final Uint8List kb = keyBytes[i];
      out.add(_u16(ib.length));
      out.add(ib);
      out.add(_u16(kb.length));
      out.add(kb);
      out.add(_u64(offset));
      out.add(_u32(b.length));
      offset += b.length;
    }
    for (final String id in docIds) {
      out.add(blobs[id]!);
    }
    return out.toBytes();
  }

  /// 解析打包字节；格式不认识 / 损坏返回 null（调用方按「没有缓存」处理）。
  static ThumbPack? decode(Uint8List bytes) {
    if (bytes.length < 16) return null;
    for (int i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) return null;
    }
    final ByteData d = ByteData.sublistView(bytes);
    final int ver = d.getUint32(8);
    if (ver != version) return null;
    final int count = d.getUint32(12);

    final Map<String, Uint8List> entries = <String, Uint8List>{};
    final Map<String, String> keys = <String, String>{};
    int at = 16;
    for (int i = 0; i < count; i++) {
      if (at + 2 > bytes.length) return null;
      final int idLen = d.getUint16(at);
      at += 2;
      if (idLen <= 0 || idLen > maxDocIdBytes || at + idLen + 2 > bytes.length) {
        return null;
      }
      final String docId =
          utf8.decode(bytes.sublist(at, at + idLen), allowMalformed: true);
      at += idLen;

      final int keyLen = d.getUint16(at);
      at += 2;
      if (keyLen <= 0 || at + keyLen + 12 > bytes.length) return null;
      final String key =
          utf8.decode(bytes.sublist(at, at + keyLen), allowMalformed: true);
      at += keyLen;

      final int off = d.getUint64(at);
      at += 8;
      final int len = d.getUint32(at);
      at += 4;
      if (off < 0 || len <= 0 || off + len > bytes.length) return null;
      entries[docId] = Uint8List.sublistView(bytes, off, off + len);
      keys[docId] = key;
    }
    return ThumbPack(entries: entries, keys: keys);
  }

  static Uint8List _u16(int v) =>
      Uint8List.fromList(<int>[(v >> 8) & 0xFF, v & 0xFF]);

  static Uint8List _u32(int v) => Uint8List.fromList(<int>[
        (v >> 24) & 0xFF,
        (v >> 16) & 0xFF,
        (v >> 8) & 0xFF,
        v & 0xFF,
      ]);

  static Uint8List _u64(int v) => Uint8List.fromList(<int>[
        (v >> 56) & 0xFF,
        (v >> 48) & 0xFF,
        (v >> 40) & 0xFF,
        (v >> 32) & 0xFF,
        (v >> 24) & 0xFF,
        (v >> 16) & 0xFF,
        (v >> 8) & 0xFF,
        v & 0xFF,
      ]);
}
