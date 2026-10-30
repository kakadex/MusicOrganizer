/// 封面缩略图缓存的命名与淘汰策略（纯逻辑，0.2.59）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/cover/thumb_policy.dart';
import 'package:musicorganizer/core/model/vfile.dart';

VFile song(String name, {int size = 5 * 1024 * 1024, int mtime = 1000}) => VFile(
      docId: 'r/$name',
      parentId: 'r',
      name: name,
      size: size,
      lastModified: mtime,
    );

void main() {
  test('缓存键带大小与修改时间：换封面就会换键', () {
    final VFile a = song('示例歌名.mp3');
    final VFile b = song('示例歌名.mp3', mtime: 2000);
    final VFile c = song('示例歌名.mp3', size: 9);
    expect(ThumbPolicy.keyOf(a), isNot(ThumbPolicy.keyOf(b)));
    expect(ThumbPolicy.keyOf(a), isNot(ThumbPolicy.keyOf(c)));
  });

  test('文件名是固定 16 位十六进制 + .png，同一首每次算出来一样', () {
    final VFile f = song('示例歌名.mp3');
    final String n1 = ThumbPolicy.fileName(ThumbPolicy.keyOf(f));
    final String n2 = ThumbPolicy.fileName(ThumbPolicy.keyOf(f));
    expect(n1, n2);
    expect(n1, matches(RegExp(r'^[0-9a-f]{16}\.png$')));
    // 不同歌不撞名
    final String other = ThumbPolicy.fileName(ThumbPolicy.keyOf(song('另一首.mp3')));
    expect(other, isNot(n1));
  });

  test('哈希高位是 1 时也不能出现负号（Dart int 是有符号 64 位）', () {
    // 这几个键的 FNV-1a 高位为 1：曾经会算出「-8cd967bb4845657.png」这种名字
    final List<String> keys = <String>[
      'r/a.mp3|10|1',
      'r/示例歌名.mp3|1000|1',
      for (int i = 0; i < 40; i++) 'r/第$i首.mp3|1000|1',
    ];
    for (final String k in keys) {
      final String name = ThumbPolicy.fileName(k);
      expect(name.startsWith('-'), isFalse, reason: '负面例子：$k -> $name');
      expect(name, matches(RegExp(r'^[0-9a-f]{16}\.png$')), reason: name);
    }
  });

  test('哈希按下标算出来是稳定的（防止偷偷换了算法让整批缓存失效）', () {
    expect(ThumbPolicy.fnv1a64(''), 0xcbf29ce484222325);
    expect(ThumbPolicy.fnv1a64('a'), 0xaf63dc4c8601ec8c);
  });

  test('没超预算什么都不删', () {
    final List<ThumbEntry> entries = <ThumbEntry>[
      const ThumbEntry('a.png', 1000, 1),
      const ThumbEntry('b.png', 1000, 2),
    ];
    expect(ThumbPolicy.prunePlan(entries, maxFiles: 10, maxBytes: 10000), isEmpty);
  });

  test('超条数时按最旧优先删，删到预算的 3/4', () {
    final List<ThumbEntry> entries = <ThumbEntry>[
      for (int i = 0; i < 10; i++) ThumbEntry('f$i.png', 100, i),
    ];
    final List<String> plan =
        ThumbPolicy.prunePlan(entries, maxFiles: 8, maxBytes: 1000000);
    // 条数 10 > 8：目标 6 条，删掉最旧的 4 个
    expect(plan, <String>['f0.png', 'f1.png', 'f2.png', 'f3.png']);
  });

  test('超体积时同样按最旧优先删，删到预算的 3/4 以内', () {
    final List<ThumbEntry> entries = <ThumbEntry>[
      const ThumbEntry('old.png', 600, 1),
      const ThumbEntry('mid.png', 600, 2),
      const ThumbEntry('new.png', 600, 3),
    ];
    // 总 1800 > 上限 1000；目标 750 → 删最旧的 old(剩 1200) + mid(剩 600)
    final List<String> plan =
        ThumbPolicy.prunePlan(entries, maxFiles: 100, maxBytes: 1000);
    expect(plan, <String>['old.png', 'mid.png']);
  });
}
