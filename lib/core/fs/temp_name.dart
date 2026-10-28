/// 临时文件唯一命名（纯 Dart）。
///
/// 只用 `microsecondsSinceEpoch` 会撞名：两个 isolate（测试并行、或写盘队列
/// 与封面缓存同时在跑）完全可能落在同一微秒，于是「复制到临时文件」直接
/// 撞上别人正在用的文件，报一句莫名其妙的 E_IO。加一个进程内递增序号即可。
library;

import 'dart:io';

int _seq = 0;

/// 生成一个临时文件名（不含目录）。
///
/// [prefix] 建议带上用途（`mo_tx_` / `mo_lrc_` / `mo_raw_`），排查时一眼能看出
/// 是谁留下的；[ext] 需要以点开头。
String uniqueTempName(String prefix, [String ext = '']) {
  final int n = _seq++;
  return '$prefix${DateTime.now().microsecondsSinceEpoch}_$n$ext';
}

/// 本 app 自己会留下的临时文件名前缀（清理时只认这些，绝不碰别人的文件）。
const List<String> moTempPrefixes = <String>['mo_tx_', 'mo_lrc_', 'mo_raw_'];

/// 清掉 [dir] 里本 app 留下的过期临时文件，返回删掉的个数。
///
/// 清理责任：事务在 finally 里删自己的临时文件，但**进程被杀 / 断电**时没人
/// 收尾，缓存目录会一天天涨。所以启动时扫一遍：只认 [moTempPrefixes] 前缀、
/// 只删超过 [olderThan]（默认 6 小时）的，正在跑的任务不会被误删。
/// 失败一律吞掉——清不掉最多是占点空间，不该影响启动。
int sweepTemp(
  Directory dir, {
  Duration olderThan = const Duration(hours: 6),
  List<String> prefixes = moTempPrefixes,
  DateTime? now,
}) {
  final DateTime n = now ?? DateTime.now();
  int removed = 0;
  try {
    if (!dir.existsSync()) return 0;
    for (final FileSystemEntity e in dir.listSync()) {
      if (e is! File) continue;
      final String name = e.path.contains('/')
          ? e.path.substring(e.path.lastIndexOf('/') + 1)
          : (e.path.contains('\\')
              ? e.path.substring(e.path.lastIndexOf('\\') + 1)
              : e.path);
      if (!prefixes.any(name.startsWith)) continue;
      try {
        final DateTime modified = e.statSync().modified;
        if (n.difference(modified) < olderThan) continue;
        e.deleteSync();
        removed++;
      } catch (_) {}
    }
  } catch (_) {}
  return removed;
}
