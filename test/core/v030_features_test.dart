import 'package:flutter_test/flutter_test.dart' hide Tags;
import 'package:musicorganizer/core/cleanup/name_template.dart';
import 'package:musicorganizer/core/lyrics/lyrics_shift.dart';
import 'package:musicorganizer/core/lyrics/lyrics_tool.dart';
import 'package:musicorganizer/core/match/batch_edit.dart';
import 'package:musicorganizer/core/model/tags.dart';
import 'package:musicorganizer/core/model/vfile.dart';

/// v0.3.0 新增能力的纯逻辑回归：歌词工具、批量编辑、文件名模板。
void main() {
  const String lrc = '[ti:示例]\r\n[ar:示例歌手]\r\n'
      '[00:12.30]第一行\r\n[00:15]第二行\r\n\r\n'
      '[00:20.100]重复行\r\n[00:20.100]重复行\r\n';

  group('歌词工具', () {
    test('删空行', () {
      final String out = LyricsTool.stripEmptyLines(lrc);
      expect(out.contains('\r\n\r\n'), isFalse);
      expect(out.contains('第一行'), isTrue);
    });

    test('去头部元信息', () {
      final String out = LyricsTool.stripHeaders(lrc);
      expect(out.contains('[ti:'), isFalse);
      expect(out.contains('[ar:'), isFalse);
      expect(out.contains('第一行'), isTrue);
    });

    test('去时间轴', () {
      final String out = LyricsTool.stripTimestamps(lrc);
      expect(out.contains('[00:'), isFalse);
      expect(out.contains('第二行'), isTrue);
    });

    test('去重复行', () {
      final String out = LyricsTool.dedupeLines(lrc);
      expect('重复行'.allMatches(out).length, 1);
    });

    test('时间轴整体偏移：所有时间戳同步加减', () {
      final String out = LyricsShift.shift(lrc, 500);
      expect(out.contains('[00:12.80]'), isTrue);
      expect(out.contains('[00:15.500]'), isTrue);
      expect(out.contains('[00:20.600]'), isTrue);
    });

    test('偏移不会跑到负数', () {
      final String out = LyricsShift.shift(lrc, -20000);
      expect(out.contains('-00:'), isFalse);
      expect(out.contains('[00:00.00]'), isTrue);
    });

    test('偏移量不会被吞掉：整数秒的时间戳也要带上毫秒', () {
      // 原本没有小数位，偏移后多出的毫秒必须写出来，
      // 否则「[00:15] 往后推 500ms」会变成还是 [00:15]。
      final String out = LyricsShift.shift('[00:15]第二行', 500);
      expect(out, contains('[00:15.500]'));
    });

    test('偏移后全部挤到 0 秒会被识别出来', () {
      expect(LyricsShift.collapsesToZero('[00:00.500]第一行', -1000), isTrue);
      expect(LyricsShift.collapsesToZero(lrc, -1500), isFalse);
    });

    test('时间戳数量与首尾位置', () {
      expect(LyricsShift.count(lrc), 4);
      expect(LyricsShift.firstStamp(lrc), 12300);
      expect(LyricsShift.lastStamp(lrc), 20100);
    });

    test('组合应用：先偏移再清洗', () {
      final String out = LyricsTool.apply(LyricsShift.shift(lrc, 500),
          LyricsTool.opEmpty | LyricsTool.opHeader | LyricsTool.opDedupe);
      expect(out.contains('[ti:'), isFalse);
      expect('重复行'.allMatches(out).length, 1);
      expect(out.contains('[00:12.80]'), isTrue);
    });
  });

  group('批量编辑', () {
    test('按顺序重排音轨号', () {
      final BatchEditSpec spec = BatchEditSpec()..renumberTrack = true;
      expect(spec.updatesFor(0)['track'], '1');
      expect(spec.updatesFor(2)['track'], '3');
    });

    test('音轨起始编号可指定', () {
      final BatchEditSpec spec = BatchEditSpec()
        ..renumberTrack = true
        ..trackStart = 11;
      expect(spec.updatesFor(0)['track'], '11');
      expect(spec.updatesFor(1)['track'], '12');
    });

    test('设字段：空串表示清除', () {
      final BatchEditSpec spec = BatchEditSpec()
        ..values['album'] = '示例专辑'
        ..values['genre'] = '';
      final Map<String, String> u = spec.updatesFor(0);
      expect(u['album'], '示例专辑');
      expect(u['genre'], '');
      expect(u.containsKey('track'), isFalse);
    });

    test('描述里含字段与清空提示', () {
      final BatchEditSpec spec = BatchEditSpec()..values['genre'] = '';
      expect(spec.summary().contains('流派'), isTrue);
      expect(spec.summary().contains('（清空）'), isTrue);
      expect(BatchEditSpec().isEmpty, isTrue);
    });

    test('只算可写标签的文件', () {
      final List<VFile> files = <VFile>[
        VFile(docId: 'r/a.mp3', parentId: 'r', name: 'a.mp3'),
        VFile(docId: 'r/b.wma', parentId: 'r', name: 'b.wma'),
        VFile(docId: 'r/c.flac', parentId: 'r', name: 'c.flac'),
      ];
      expect(BatchEditSpec.editableCount(files), 2);
    });
  });

  group('文件名模板', () {
    test('按标签拼文件名', () {
      final Map<String, String> f = NameTemplate.fields(
          Tags()
            ..put('artist', '示例歌手')
            ..put('title', '示例歌名'));
      expect(NameTemplate.render('{artist} - {title}', f, '.mp3'),
          '示例歌手 - 示例歌名.mp3');
    });

    test('音轨号补零', () {
      expect(NameTemplate.padTrack('3'), '03');
      expect(NameTemplate.padTrack('12'), '12');
    });

    test('模板里缺字段时留空而不是报错', () {
      final Map<String, String> f = NameTemplate.fields(Tags());
      final String out = NameTemplate.render('{artist} - {title}', f, '.mp3');
      // 字段全空时返回空串（不硬补扩展名，否则会造出 ".mp3" 这种怪文件名）
      expect(out, isEmpty);
    });

    test('清理多余分隔符', () {
      expect(NameTemplate.tidy('示例歌手 - 示例歌名'), '示例歌手 - 示例歌名');
    });

    test('非法字符换成合法形式', () {
      final String out = NameTemplate.sanitize('a/b:c*d?e"f<g>h|i');
      expect(out.contains('/'), isFalse);
      expect(out.contains(':'), isFalse);
    });

    test('重名时加序号', () {
      expect(NameTemplate.withIndex('示例.mp3', 2), '示例 (2).mp3');
    });
  });
}
