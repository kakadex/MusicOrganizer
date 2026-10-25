/// 一个已授权的目录树（安卓 SAF treeUri + rootDocId；桌面为根路径）。
class TreeRef {
  const TreeRef({required this.treeUri, required this.rootDocId});

  /// 授权 uri（桌面即目录路径）。
  final String treeUri;

  /// 树根文档 id（桌面即目录路径）。
  final String rootDocId;

  @override
  bool operator ==(Object other) =>
      other is TreeRef && other.treeUri == treeUri;

  @override
  int get hashCode => treeUri.hashCode;

  @override
  String toString() => 'TreeRef($rootDocId)';
}
