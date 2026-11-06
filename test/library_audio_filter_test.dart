/// 曲库列表只收音频，不收歌词（0.2.98）。
///
/// 真机日志实证：247 首「缺封面」全是 `.lrc` 歌词文件。
/// `walkMusic` 按设计同时收音频与歌词，但 `Repo.files` 是列表数据源，
/// 歌词一首一行是错的——它们没有封面，却占满补图名额、每秒重试。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/model/vfile.dart';

VFile f(String name) => VFile(docId: 'a/$name', parentId: 'a', name: name, size: 100);

void main() {
  test('歌词扩展名不算音频', () {
    for (final String n in <String>[
      'a.lrc', 'a.krc', 'a.qrc', 'a.trc', 'a.srt', 'a.lrc.txt',
    ]) {
      expect(f(n).audio(), isFalse, reason: '$n 不是音频');
    }
  });

  test('常见音频扩展名算音频', () {
    for (final String n in <String>[
      'a.mp3', 'a.flac', 'a.m4a', 'a.wav', 'a.ogg', 'a.ape', 'a.wma',
    ]) {
      expect(f(n).audio(), isTrue, reason: '$n 是音频');
    }
  });

  test('过滤后歌词被剔除，音频保留（模拟 Repo.files 的收口）', () {
    final List<VFile> scanned = <VFile>[
      f('刀郎-喀什噶尔胡杨.lrc'),
      f('刀郎-大敦煌.lrc'),
      f('李慧珍-爱死了昨天.mp3'),
      f('HITA-犹有未归人.mp3'),
    ];
    final List<VFile> kept =
        scanned.where((VFile x) => !x.dir && x.audio()).toList();
    expect(kept.length, 2);
    expect(kept.map((VFile x) => x.name),
        <String>['李慧珍-爱死了昨天.mp3', 'HITA-犹有未归人.mp3'],
        reason: '歌词必须被剔除');
  });

  test('目录也算非音频（不该进列表）', () {
    final VFile d = VFile(docId: 'a/sub', name: 'sub', dir: true);
    expect(d.audio(), isFalse);
  });
}
