/// 临时文件唯一命名（纯 Dart）。
///
/// 只用 `microsecondsSinceEpoch` 会撞名：两个 isolate（测试并行、或写盘队列
/// 与封面缓存同时在跑）完全可能落在同一微秒，于是「复制到临时文件」直接
/// 撞上别人正在用的文件，报一句莫名其妙的 E_IO。加一个进程内递增序号即可。
library;

int _seq = 0;

/// 生成一个临时文件名（不含目录）。
///
/// [prefix] 建议带上用途（`mo_tx_` / `mo_lrc_` / `mo_raw_`），排查时一眼能看出
/// 是谁留下的；[ext] 需要以点开头。
String uniqueTempName(String prefix, [String ext = '']) {
  final int n = _seq++;
  return '$prefix${DateTime.now().microsecondsSinceEpoch}_$n$ext';
}
