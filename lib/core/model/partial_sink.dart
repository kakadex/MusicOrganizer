/// 「边跑边收」的已完成结果缓冲区。
///
/// 支撑「暂停时预览已获取部分」。Dart 单线程下用同步集合即可；
/// [snapshot] 返回独立副本，且按序号归位（= 文件列表原始顺序）。
library;

import 'dart:collection';

/// 按序号归位的已完成结果缓冲区。
class PartialSink<T extends Object> {
  /// 按序号归位；未指定序号（旧调用）时用自增序号兜底，保证稳定排序。
  final SplayTreeMap<int, T> _items = SplayTreeMap<int, T>();
  int _fallbackSeq = 0;

  /// 收一条已完成的结果（null 忽略，按完成顺序追加）。
  void add(T? item) {
    if (item == null) return;
    _items[_fallbackSeq++] = item;
  }

  /// 收一条已完成的结果，并指定它在文件列表中的原始序号（预览按此排序）。
  void addAt(int index, T? item) {
    if (item == null) return;
    _items[index] = item; // 同一序号重复投递时取最后一次（防御性处理）
  }

  int size() => _items.length;
  bool isEmpty() => _items.isEmpty;

  /// 取快照（独立副本，按序号升序 = 文件列表顺序）。
  List<T> snapshot() => _items.values.toList();

  void clear() {
    _items.clear();
    _fallbackSeq = 0;
  }
}
