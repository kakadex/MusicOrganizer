/// 内容样本：文件大小 + 首、中、尾各 64KB。
///
/// 用于「文件名字像但内容是不是同一份」的判定：文件名查重只给线索，
/// 真正定论要靠内容——两首同名歌时长可能一样，但内容指纹一定不同。
///
/// 只看首尾在**理论上**会误判：两个文件头尾相同、中间不同（同一份音频被
/// 从中间剪一刀 / 拼一段，标签和尾部都没动）会被判成同一份。所以再加上
/// 正中间的一段。中段是**可选能力**（FileStore.rangeBytes），取不到时
/// [mid] 为 null，判定自动退回「大小 + 首尾」，不会让整次查重失败。
library;

import 'dart:typed_data';

/// 一个文件的内容指纹样本。
class ContentSample {
  ContentSample(this.size, this.head, this.tail, {Uint8List? mid})
      : mid = (mid == null || mid.isEmpty) ? null : mid;

  /// 文件字节数。
  final int size;

  /// 文件头（最多 64KB）。
  final Uint8List head;

  /// 文件尾（最多 64KB）。
  final Uint8List tail;

  /// 文件中段（最多 64KB）；取不到为 null。
  final Uint8List? mid;

  /// 两个样本是否来自同一份内容。
  bool sameAs(ContentSample other) {
    if (size != other.size) return false;
    if (!_equal(head, other.head)) return false;
    if (!_equal(tail, other.tail)) return false;
    // 两边都取到了中段才比；任一侧没有就维持原有判定强度
    final Uint8List? a = mid, b = other.mid;
    if (a != null && b != null && !_equal(a, b)) return false;
    return true;
  }

  static bool _equal(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
