/// 同基名的音频 + 歌词文件组 —— 移植自旧 core/TrackGroup.java。
library;

import 'vfile.dart';

class TrackGroup {
  /// 音频格式权重（allFiles 排序用）。
  static const List<String> _audioExtOrder = <String>[
    '.mp3', '.flac', '.m4a', '.wav', '.ogg', '.aac', '.wma', '.ape', '.opus',
  ];

  final VFile dir;
  final String basename;
  final List<VFile> audio = <VFile>[];
  final List<VFile> lyrics = <VFile>[];

  TrackGroup(this.dir, this.basename);

  static int _audioOrder(VFile f) {
    final int i = _audioExtOrder.indexOf(f.ext());
    return i < 0 ? _audioExtOrder.length : i;
  }

  /// 音频优先（按格式权重），歌词随后 —— 原子移动顺序与旧版一致。
  List<VFile> allFiles() {
    final List<VFile> a = List<VFile>.of(audio)
      ..sort((VFile x, VFile y) {
        final int d = _audioOrder(x) - _audioOrder(y);
        if (d != 0) return d;
        return x.name.toLowerCase().compareTo(y.name.toLowerCase());
      });
    final List<VFile> l = List<VFile>.of(lyrics)
      ..sort((VFile x, VFile y) =>
          x.name.toLowerCase().compareTo(y.name.toLowerCase()));
    return <VFile>[...a, ...l];
  }

  /// 主音频文件；没有返回 null。
  VFile? primaryAudio() {
    for (final VFile f in allFiles()) {
      if (f.audio()) return f;
    }
    return null;
  }

  String displayName() => '$basename（${audio.length + lyrics.length} 个文件）';
}
