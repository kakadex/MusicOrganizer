/// 内容样本：文件大小 + 首尾各 64KB。
///
/// 用于「文件名字像但内容是不是同一份」的判定：文件名查重只给线索，
/// 真正定论要靠内容——两首同名歌时长可能一样，但内容指纹一定不同。
library;

import 'dart:typed_data';

/// 一个文件的内容指纹样本。
class ContentSample {
  ContentSample(this.size, this.head, this.tail);

  /// 文件字节数。
  final int size;

  /// 文件头（最多 64KB）。
  final Uint8List head;

  /// 文件尾（最多 64KB）。
  final Uint8List tail;

  /// 两个样本是否来自同一份内容。
  bool sameAs(ContentSample other) {
    if (size != other.size) return false;
    return _equal(head, other.head) && _equal(tail, other.tail);
  }

  static bool _equal(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
