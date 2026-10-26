/// 统一写入预览模型：任何要动到磁盘的操作，都必须先变成这个结构交给用户确认。
///
/// **为什么要有这一层**：本项目有九条写盘路径（单曲编辑、批量改标签、在线匹配、
/// 封面、歌词、歌词工具、撤销、重命名、删除），原来各自为政——有的直接写、
/// 有的只弹一句话确认，用户看不到自己到底要改掉什么。
/// 这里把它们统一成同一份「逐文件、逐行的旧值 → 新值」清单：
/// 界面负责展示与勾选，业务层只写用户勾中的那部分。
///
/// 本文件不读盘、不联网、不打日志 —— 全部是纯数据，便于离线回归。
library;

/// 变更种类（决定界面配色与汇总口径）。
enum WriteKind {
  /// 写标签字段。
  tag,

  /// 写内嵌封面。
  cover,

  /// 写内嵌歌词或同名 .lrc。
  lyrics,

  /// 重命名。
  rename,

  /// 删除文件。
  delete,

  /// 移动 / 归类到别的目录。
  move,
}

/// 一行「旧值 → 新值」（界面上可单独勾选）。
class WriteLine {
  WriteLine({
    required this.label,
    this.oldText = '',
    this.newText = '',
    this.key,
    this.payload,
    this.selected = true,
  });

  /// 这一行改的是什么（「标题」「封面」「文件名」「删除」…）。
  final String label;

  /// 原值（空串表示原来没有）。
  final String oldText;

  /// 新值（空串表示清空）。
  final String newText;

  /// 标签字段名（[WriteKind.tag] 时用；交给 `TagTransaction.apply` 的 Map 键）。
  final String? key;

  /// 附带数据（封面字节、歌词文本）；不走 Map 的变更用这个。
  final Object? payload;

  /// 是否勾选；取消勾选后这一行不参与写入。
  bool selected;

  /// 值与原来不同（没变的行界面上标灰，默认不写）。
  bool get changed => oldText != newText;

  /// 界面用：原值为空显示「（空）」，新值为空显示「（清空）」。
  String get oldShown => oldText.isEmpty ? '（空）' : oldText;

  String get newShown => newText.isEmpty ? '（清空）' : newText;

  @override
  String toString() => '$label：$oldShown → $newShown';
}

/// 一个文件的全部变更（界面上是一张可勾选的卡片）。
class WriteTarget {
  WriteTarget({
    required this.docId,
    required this.name,
    required this.kind,
    this.path = '',
    this.note = '',
    this.risky = false,
    this.lowConfidence = false,
    List<WriteLine>? lines,
    this.file,
    this.data,
  }) : lines = lines ?? <WriteLine>[];

  /// 文件标识（SAF docId / 桌面绝对路径）。
  final String docId;

  /// 显示名（文件名）。
  final String name;

  /// 所在目录（副标题）。
  final String path;

  /// 变更种类。
  final WriteKind kind;

  /// 说明（来源、置信度、跳过原因…）。
  final String note;

  /// 危险操作（删除 / 覆盖已有封面）：界面标红。
  final bool risky;

  /// 低置信（在线结果不可靠）：界面标黄提示人工确认。
  final bool lowConfidence;

  /// 逐行变更。
  final List<WriteLine> lines;

  /// 原始文件对象（调用方需要时自取；core 层不认识它，所以用 Object?）。
  final Object? file;

  /// 调用方自留的数据（比如要写的封面字节、歌词文本）。
  final Object? data;

  /// 整项是否参与写入。
  bool selected = true;

  /// 至少有一行被勾中且真变了。
  bool get hasChange => lines.any((WriteLine l) => l.selected && l.changed);

  /// 勾中的变更行数。
  int get changedCount =>
      lines.where((WriteLine l) => l.selected && l.changed).length;

  /// 导出要交给 `TagTransaction.apply` 的字段更新；只含勾中且真变了的标签行。
  Map<String, String> toUpdates() {
    final Map<String, String> out = <String, String>{};
    for (final WriteLine l in lines) {
      if (!l.selected || !l.changed) continue;
      final String? k = l.key;
      if (k == null || k.isEmpty) continue;
      out[k] = l.newText;
    }
    return out;
  }

  /// 勾中的歌词文本（没有返回 null）。
  String? toLyrics() {
    for (final WriteLine l in lines) {
      if (l.selected && l.changed && l.key == 'lyrics') return l.newText;
    }
    return null;
  }
}

/// 汇总与批量操作（纯函数）。
abstract final class WritePreview {
  /// 一行汇总：「共 12 项，待写入 8 项，其中 2 项来自低置信结果」。
  static String summarize(
    List<WriteTarget> targets, {
    String unit = '项',
    String verb = '写入',
  }) {
    final int total = targets.length;
    final int pending =
        targets.where((WriteTarget t) => t.selected && t.hasChange).length;
    final int low = targets
        .where((WriteTarget t) => t.selected && t.hasChange && t.lowConfidence)
        .length;
    final StringBuffer sb = StringBuffer('共 $total $unit，待$verb $pending $unit');
    if (low > 0) sb.write('，其中 $low $unit来自低置信结果');
    return sb.toString();
  }

  /// 过滤出勾中且有变更的项。
  static List<WriteTarget> onlySelected(List<WriteTarget> targets) =>
      targets.where((WriteTarget t) => t.selected && t.hasChange).toList();

  /// 全选 / 全不选。
  static void setAll(List<WriteTarget> targets, bool on) {
    for (final WriteTarget t in targets) {
      t.selected = on;
    }
  }

  /// 只保留有变更的项（没变的不显示，省得刷屏）。
  static List<WriteTarget> dropEmpty(List<WriteTarget> targets) =>
      targets.where((WriteTarget t) => t.lines.isNotEmpty).toList();
}

/// 常用的行构造器，避免各页面重复拼「（空）/（清空）」。
abstract final class WriteLineX {
  /// 标签字段行。
  static WriteLine field(String key, String label, String oldText, String newText) =>
      WriteLine(label: label, oldText: oldText, newText: newText, key: key);

  /// 删除行（旧值 = 文件名，新值 = 空）。
  static WriteLine delete(String name) =>
      WriteLine(label: '删除文件', oldText: name, newText: '');

  /// 重命名行。
  static WriteLine rename(String oldName, String newName) =>
      WriteLine(label: '文件名', oldText: oldName, newText: newName);

  /// 移动行。
  static WriteLine move(String oldPath, String newPath) =>
      WriteLine(label: '所在目录', oldText: oldPath, newText: newPath);
}
