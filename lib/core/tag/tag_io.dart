/// 标签读写调度（事务外壳）。
///
/// 本地读 / 写按扩展名分发到各 codec；写路径工作在内存字节上，调用方负责把
/// 结果写回 SAF 原文件（副本 → 写 → 校验 → 写回，任一步失败原文件不动）。
library;

import 'dart:typed_data';

import '../model/tags.dart';
import 'ape.dart';
import 'dsf.dart';
import 'flac.dart';
import 'id3.dart';
import 'mp4.dart';
import 'ogg.dart';
import 'wav.dart';
import 'wma.dart';

/// 标签读写调度（纯 Dart）。
abstract final class TagIO {
  /// 需要写入的字段名集合（comment 不参与批量写入）。
  static Map<String, String> writableCopy(Map<String, String> values) {
    final Map<String, String> out = <String, String>{};
    for (final String k in Tags.keys) {
      if (k == 'comment') continue;
      final String? v = values[k];
      if (v != null) out[k] = v.trim();
    }
    return out;
  }

  /// MP4 家族的标签在 moov 里，而 moov 可能在文件**尾部**（录音/转码常见），
  /// 所以不能靠「头 N 字节够不够」来一刀切。
  static bool isMp4(String ext) {
    final String e = ext.toLowerCase();
    return e == '.m4a' || e == '.mp4';
  }

  /// 当前缓冲还需不需要更多字节（扫描/读标签据此决定要不要继续读）。
  static bool needsMore(Uint8List copy, String ext) {
    if (isMp4(ext)) return mp4MoovIn(copy) == null;
    return !tagFitsCopy(copy, ext);
  }

  /// 在缓冲里找**完整的**顶层 moov；返回 (起点, 长度)，没有返回 null。
  ///
  /// 只读原子头做判断，不解析内部，因此对截断的缓冲也是安全的。
  static (int, int)? mp4MoovIn(Uint8List b) {
    int pos = 0;
    while (pos + 8 <= b.length) {
      int size = (b[pos] << 24) | (b[pos + 1] << 16) | (b[pos + 2] << 8) | b[pos + 3];
      final String type = String.fromCharCodes(b, pos + 4, pos + 8);
      int header = 8;
      if (size == 1) {
        // 64 位 largesize：只有高 4 字节为 0 时才当普通长度处理
        if (pos + 16 > b.length) return null;
        if (b[pos + 8] != 0 || b[pos + 9] != 0 || b[pos + 10] != 0 || b[pos + 11] != 0) {
          return null;
        }
        size = (b[pos + 12] << 24) |
            (b[pos + 13] << 16) |
            (b[pos + 14] << 8) |
            b[pos + 15];
        header = 16;
      } else if (size == 0) {
        // size=0 表示「一直到文件末尾」，在本缓冲里无法确认完整
        return null;
      }
      if (size < header) return null;
      if (type == 'moov') {
        return pos + size <= b.length ? (pos, size) : null;
      }
      if (pos + size > b.length) return null; // 下一个原子还没读进来
      pos += size;
    }
    return null;
  }

  /// 从「尾部缓冲」里切出以 moov 开头的独立片段。
  ///
  /// 返回的片段可以直接交给 [readLocal] / `CoverReader.read`：
  /// 它们都从偏移 0 开始按顶层原子扫描，切片正好是 moov 本身。
  static Uint8List? mp4MoovFromTail(Uint8List tail) {
    for (int i = tail.length - 4; i >= 4; i--) {
      // 找 'moov'
      if (tail[i] != 0x6D ||
          tail[i + 1] != 0x6F ||
          tail[i + 2] != 0x6F ||
          tail[i + 3] != 0x76) {
        continue;
      }
      final int start = i - 4;
      final int size = (tail[start] << 24) |
          (tail[start + 1] << 16) |
          (tail[start + 2] << 8) |
          tail[start + 3];
      if (size < 16) continue;
      if (start + size > tail.length) continue;
      return Uint8List.sublistView(tail, start, start + size);
    }
    return null;
  }

  /// 头部副本里是否已包含完整标签。
  static bool tagFitsCopy(Uint8List copy, String ext) {
    final String e = ext.isEmpty ? '' : ext.toLowerCase();
    if (e == '.dsf') return true;
    if (e != '.mp3' && e != '.flac') return false;
    final int len = copy.length;
    if (e == '.mp3') {
      if (len < 10) return true;
      if (copy[0] != 0x49 || copy[1] != 0x44 || copy[2] != 0x33) return true;
      final int size = _syncsafe(copy, 6);
      final int tagEnd = 10 + size + ((copy[5] & 0x10) != 0 ? 10 : 0);
      return tagEnd <= len;
    }
    // FLAC
    if (len < 4) return true;
    if (!(copy[0] == 0x66 && copy[1] == 0x4C && copy[2] == 0x61 && copy[3] == 0x43)) {
      return true;
    }
    int pos = 4;
    while (pos + 4 <= len) {
      final int b = copy[pos];
      final bool last = (b & 0x80) != 0;
      final int type = b & 0x7F;
      if (pos + 4 > len) return true;
      final int blockLen =
          (copy[pos + 1] << 16) | (copy[pos + 2] << 8) | copy[pos + 3];
      final int end = pos + 4 + blockLen;
      if (type == 4) return end <= len;
      if (last) return true;
      pos = end;
    }
    return false;
  }

  /// 本地文件标签读取（自动分发格式）。
  static Tags readLocal(Uint8List data, String ext) {
    Tags tags = Tags();
    final String e = extOf(ext);
    try {
      if (e == '.mp3') {
        tags = Id3.read(data);
      } else if (e == '.flac') {
        tags = Flac.isFlac(data) ? Flac.read(data) : Tags();
      } else if (e == '.m4a' || e == '.mp4') {
        tags = Mp4.isMp4(data) ? Mp4.read(data) : Tags();
      } else if (e == '.wav') {
        tags = Wav.read(data);
      } else if (e == '.ogg' || e == '.opus') {
        tags = Ogg.read(data);
      } else if (e == '.ape') {
        tags = Ape.read(data);
      } else if (e == '.wma') {
        tags = Wma.read(data);
      } else if (e == '.dsf') {
        tags = Dsf.isDsf(data) ? Dsf.read(data) : Tags();
      }
    } catch (_) {
      tags = Tags();
    }
    if (tags.get('year').length > 4) {
      tags.put('year', tags.get('year').substring(0, 4));
    }
    return tags;
  }

  /// 本地写入；返回 (错误信息, 新字节)。成功时错误为空串、新字节非空。
  static (String, Uint8List?) writeLocal(Uint8List data, String ext,
      Map<String, String> values, {Uint8List? cover}) {
    final String e = extOf(ext);
    try {
      if (e == '.mp3') {
        return ('', Id3.rewrite(data, values, cover: cover));
      }
      if (e == '.flac') {
        if (!Flac.isFlac(data)) return ('文件不是有效的 FLAC', null);
        return ('', Flac.rewrite(data, values, cover: cover));
      }
      if (e == '.m4a' || e == '.mp4') {
        if (!Mp4.isMp4(data)) return ('文件不是有效的 M4A/MP4', null);
        return ('', Mp4.write(data, values, cover: cover));
      }
      if (e == '.wav') {
        if (!Wav.isWav(data)) return ('文件不是有效的 WAV', null);
        return ('', Wav.rewrite(data, values, cover: cover));
      }
      if (e == '.ogg' || e == '.opus') {
        if (!Ogg.isOgg(data)) return ('文件不是有效的 OGG/Opus', null);
        return ('', Ogg.rewrite(data, values, cover: cover));
      }
      if (e == '.ape' || e == '.wv' || e == '.mpc') {
        if (!Ape.isApe(data)) return ('文件不是有效的 APE / WavPack / Musepack', null);
        return ('', Ape.rewrite(data, values, cover: cover));
      }
      if (e == '.aac') {
        return ('纯 ADTS AAC 不支持 ID3 标签，建议先转码为 M4A 或 MP3 再写入', null);
      }
      if (e == '.wma') {
        return ('WMA 标签写入支持有限，建议转码为 FLAC 或 MP3', null);
      }
      if (e == '.dsf') {
        if (!Dsf.isDsf(data)) return ('文件不是有效的 DSF', null);
        return ('', Dsf.rewrite(data, values, cover: cover));
      }
      return ('该格式不支持写标签：$e', null);
    } catch (err) {
      return (_shortError(err), null);
    }
  }

  static bool canWrite(String ext) {
    final String e = extOf(ext);
    return e == '.mp3' ||
        e == '.flac' ||
        e == '.m4a' ||
        e == '.mp4' ||
        e == '.wav' ||
        e == '.ogg' ||
        e == '.opus' ||
        e == '.ape' ||
        e == '.wv' ||
        e == '.mpc' ||
        e == '.dsf';
  }

  /// 该格式能否**读取**标签与封面（WMA 只读，但能读出封面）。
  static bool canRead(String ext) {
    final String e = extOf(ext);
    return canWrite(e) || e == '.wma';
  }

  /// 该格式是否有内嵌歌词字段（WAV / DSF 只有常规标签，没有歌词）。
  static bool canWriteLyrics(String ext) {
    final String e = extOf(ext);
    return e == '.mp3' ||
        e == '.flac' ||
        e == '.m4a' ||
        e == '.mp4' ||
        e == '.ogg' ||
        e == '.opus' ||
        e == '.ape' ||
        e == '.wv' ||
        e == '.mpc';
  }

  static bool hasCoverLocal(Uint8List data, String ext) {
    final String e = extOf(ext);
    if (e == '.mp3') return Id3.hasCover(data);
    if (e == '.flac') return Flac.isFlac(data) && Flac.hasPicture(data);
    if (e == '.m4a' || e == '.mp4') return Mp4.isMp4(data) && Mp4.hasCover(data);
    if (e == '.ogg' || e == '.opus') return Ogg.hasCover(data);
    if (e == '.ape') return Ape.hasCover(data);
    if (e == '.dsf') return Dsf.isDsf(data) && Dsf.hasCover(data);
    return false;
  }

  /// 返回带点小写扩展名。
  static String extOf(String name) {
    final int dot = name.lastIndexOf('.');
    if (dot < 0) return '';
    return name.substring(dot).toLowerCase();
  }

  static int _syncsafe(Uint8List b, int off) =>
      ((b[off] & 0x7F) << 21) |
      ((b[off + 1] & 0x7F) << 14) |
      ((b[off + 2] & 0x7F) << 7) |
      (b[off + 3] & 0x7F);

  static String _shortError(Object t) {
    final String msg = t.toString();
    final String text = msg.trim().isEmpty ? t.runtimeType.toString() : msg.trim();
    return text.length > 180 ? text.substring(0, 180) : text;
  }
}
