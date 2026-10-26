/// 多根分派：按 docId 前缀匹配所属树。
library;

import 'tree_ref.dart';

/// 维护多棵已授权目录树，按 docId 前缀匹配所属树。
class TreeLookup {
  final List<TreeRef> _trees = <TreeRef>[];

  /// 登记（或替换同 treeUri）一棵树。
  void add(TreeRef t) {
    _trees.removeWhere((TreeRef e) => e.treeUri == t.treeUri);
    _trees.add(t);
  }

  void remove(String treeUri) {
    _trees.removeWhere((TreeRef e) => e.treeUri == treeUri);
  }

  List<TreeRef> all() => List<TreeRef>.unmodifiable(_trees);

  bool get isEmpty => _trees.isEmpty;

  /// 找 docId 所属的树（最长前缀匹配：docId == rootDocId 或 docId 以 rootDocId/ 开头）。
  TreeRef? treeFor(String docId) {
    TreeRef? best;
    int bestLen = -1;
    for (final TreeRef t in _trees) {
      if (docId == t.rootDocId || docId.startsWith('${t.rootDocId}/')) {
        if (t.rootDocId.length > bestLen) {
          best = t;
          bestLen = t.rootDocId.length;
        }
      }
    }
    return best;
  }
}
