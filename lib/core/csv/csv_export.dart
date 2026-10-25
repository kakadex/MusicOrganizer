/// 曲库清单导出（CSV）—— 移植自旧 core/CsvExport.java。
///
/// 转义按 RFC 4180（含逗号/引号/换行加引号，内部引号翻倍），带 UTF-8 BOM。
library;

import '../model/tags.dart';
import '../model/vfile.dart';

/// 曲库清单 CSV 导出（纯 Dart）。
abstract final class CsvExport {
  static const List<String> header = <String>[
    '文件名', '标题', '歌手', '专辑', '年份', '音轨', '流派', '大小(字节)',
    '有无封面', '有无歌词', '所在目录',
  ];

  /// 一行清单数据。
  static Row rowOf(VFile file, Tags tags, bool cover, bool lyrics) {
    final Row r = Row()
      ..name = file.name
      ..size = file.size
      ..cover = cover
      ..lyrics = lyrics;
    r.title = tags.get('title').trim();
    r.artist = tags.get('artist').trim();
    r.album = tags.get('album').trim();
    r.year = tags.get('year').trim();
    r.track = tags.get('track').trim();
    r.genre = tags.get('genre').trim();
    return r;
  }

  /// 生成整份 CSV 文本（带 BOM，CRLF 换行）。
  static String build(List<Row> rows) {
    final StringBuffer sb = StringBuffer();
    sb.write('\uFEFF');
    for (int i = 0; i < header.length; i++) {
      if (i > 0) sb.write(',');
      sb.write(esc(header[i]));
    }
    sb.write('\r\n');
    for (final Row r in rows) {
      _appendCell(sb, r.name, 0);
      _appendCell(sb, r.title, 1);
      _appendCell(sb, r.artist, 2);
      _appendCell(sb, r.album, 3);
      _appendCell(sb, r.year, 4);
      _appendCell(sb, r.track, 5);
      _appendCell(sb, r.genre, 6);
      _appendCell(sb, '${r.size}', 7);
      _appendCell(sb, r.cover ? '有' : '', 8);
      _appendCell(sb, r.lyrics ? '有' : '', 9);
      _appendCell(sb, r.dir, 10);
      sb.write('\r\n');
    }
    return sb.toString();
  }

  /// 单字段转义：含逗号 / 引号 / 换行才加引号，内部引号翻倍。
  static String esc(String? value) {
    if (value == null || value.isEmpty) return '';
    bool need = false;
    for (final int c in value.codeUnits) {
      if (c == 0x2C || c == 0x22 || c == 0x0A || c == 0x0D) {
        need = true;
        break;
      }
    }
    if (!need) return value;
    final StringBuffer sb = StringBuffer();
    sb.write('"');
    for (final int c in value.codeUnits) {
      if (c == 0x22) sb.write('"');
      sb.writeCharCode(c);
    }
    sb.write('"');
    return sb.toString();
  }

  /// 数据行数（不含表头）。
  static int rowCount(String csv) {
    if (csv.isEmpty) return 0;
    int n = 0;
    bool inQuote = false;
    for (final int c in csv.codeUnits) {
      if (c == 0x22) {
        inQuote = !inQuote;
      } else if (c == 0x0A && !inQuote) {
        n++;
      }
    }
    if (csv.codeUnitAt(csv.length - 1) != 0x0A) n++;
    return n - 1 < 0 ? 0 : n - 1;
  }

  /// 默认文件名：音乐整理-曲库清单-yyyyMMdd-HHmm.csv
  static String defaultFileName(DateTime now) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '音乐整理-曲库清单-${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}.csv';
  }

  /// 只保留音频行（导出前过滤用）。
  static List<VFile> audioOnly(List<VFile>? files) {
    final List<VFile> out = <VFile>[];
    if (files == null) return out;
    for (final VFile f in files) {
      if (f.audio()) out.add(f);
    }
    return out;
  }

  static void _appendCell(StringBuffer sb, String value, int index) {
    if (index > 0) sb.write(',');
    sb.write(esc(value));
  }
}

/// 一行清单数据。
class Row {
  String name = '';
  String title = '';
  String artist = '';
  String album = '';
  String year = '';
  String track = '';
  String genre = '';
  int size = 0;
  bool cover = false;
  bool lyrics = false;
  String dir = '';
}
