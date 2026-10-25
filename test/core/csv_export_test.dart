import 'package:flutter_test/flutter_test.dart' hide Tags;
import 'package:musicorganizer/core/csv/csv_export.dart';
import 'package:musicorganizer/core/model/tags.dart';
import 'package:musicorganizer/core/model/vfile.dart';

void main() {
  group('转义', () {
    test('普通文本不加引号', () {
      expect(CsvExport.esc('示例标题'), '示例标题');
      expect(CsvExport.esc(''), '');
      expect(CsvExport.esc(null), '');
    });

    test('含逗号 / 引号 / 换行才加引号，内部引号翻倍', () {
      expect(CsvExport.esc('a,b'), '"a,b"');
      expect(CsvExport.esc('say "hi"'), '"say ""hi"""');
      expect(CsvExport.esc('第一行\n第二行'), '"第一行\n第二行"');
    });
  });

  group('行与整表', () {
    test('rowOf 取标签字段与标志位', () {
      final VFile f = VFile(
          docId: 'r/a.mp3', parentId: 'r', name: 'a.mp3', size: 2048);
      final Tags t = Tags()
        ..put('title', '测试标题')
        ..put('artist', '示例歌手')
        ..put('album', '示例专辑')
        ..put('year', '2020')
        ..put('track', '03')
        ..put('genre', 'Pop');
      final Row r = CsvExport.rowOf(f, t, true, false);
      expect(r.name, 'a.mp3');
      expect(r.title, '测试标题');
      expect(r.artist, '示例歌手');
      expect(r.album, '示例专辑');
      expect(r.year, '2020');
      expect(r.track, '03');
      expect(r.genre, 'Pop');
      expect(r.size, 2048);
      expect(r.cover, isTrue);
      expect(r.lyrics, isFalse);
    });

    test('build 带 BOM + CRLF，行数不含表头', () {
      final VFile f1 =
          VFile(docId: 'r/a.mp3', parentId: 'r', name: 'a.mp3', size: 1);
      final VFile f2 =
          VFile(docId: 'r/b.mp3', parentId: 'r', name: 'b,2.mp3', size: 2);
      final Row r1 = CsvExport.rowOf(f1, Tags(), false, false)
        ..title = '标题'
        ..dir = 'r';
      final Row r2 = CsvExport.rowOf(f2, Tags(), true, true)..dir = 'r';
      final String csv = CsvExport.build(<Row>[r1, r2]);

      expect(csv.startsWith('\uFEFF'), isTrue);
      expect(csv.contains('\r\n'), isTrue);
      expect(CsvExport.rowCount(csv), 2);
      // 逗号被转义后仍在引号里，列数不会串
      expect(csv.contains('"b,2.mp3"'), isTrue);
      expect(csv.split('\r\n')[1].startsWith('a.mp3'), isTrue);
    });

    test('空表只有表头', () {
      final String csv = CsvExport.build(<Row>[]);
      expect(CsvExport.rowCount(csv), 0);
      expect(csv.split('\r\n').first.contains('文件名'), isTrue);
    });
  });

  group('辅助', () {
    test('defaultFileName 形如 音乐整理-曲库清单-yyyyMMdd-HHmm.csv', () {
      final String n =
          CsvExport.defaultFileName(DateTime(2026, 10, 26, 9, 5));
      expect(n, '音乐整理-曲库清单-20261026-0905.csv');
    });

    test('audioOnly 只留音频', () {
      final List<VFile> files = <VFile>[
        VFile(docId: 'a', name: 'a.mp3'),
        VFile(docId: 'b', name: 'b.lrc'),
        VFile(docId: 'c', name: 'c.txt'),
      ];
      expect(CsvExport.audioOnly(files).map((VFile f) => f.name).toList(),
          <String>['a.mp3']);
      expect(CsvExport.audioOnly(null), isEmpty);
    });
  });
}
