import 'package:flutter_test/flutter_test.dart' hide Tags;
import 'package:musicorganizer/core/model/candidate.dart';
import 'package:musicorganizer/core/model/duplicate_group.dart';
import 'package:musicorganizer/core/model/health_check.dart';
import 'package:musicorganizer/core/model/journal_entry.dart';
import 'package:musicorganizer/core/model/lyric_hit.dart';
import 'package:musicorganizer/core/model/lyrics_doc.dart';
import 'package:musicorganizer/core/model/partial_sink.dart';
import 'package:musicorganizer/core/model/query.dart';
import 'package:musicorganizer/core/model/tags.dart';
import 'package:musicorganizer/core/model/task_control.dart';
import 'package:musicorganizer/core/model/track_group.dart';
import 'package:musicorganizer/core/model/vfile.dart';

void main() {
  group('VFile', () {
    test('扩展名/基本名/类型判定', () {
      final VFile f = VFile(docId: 'primary:Music/a.mp3', name: '晴天.mp3', size: 1024);
      expect(f.ext(), '.mp3');
      expect(f.stem(), '晴天');
      expect(f.audio(), isTrue);
      expect(f.lyric(), isFalse);
      expect(f.music(), isTrue);
      expect(f.isHidden(), isFalse);
      expect(VFile(docId: 'x', name: '.hidden.mp3').isHidden(), isTrue);
      expect(VFile(docId: 'x', name: 'noext').ext(), '');
      expect(VFile(docId: 'x', name: 'a.lrc').lyric(), isTrue);
    });

    test('缓存与 copyWith', () {
      final VFile f = VFile(docId: 'primary:Music/a.mp3', name: 'a.mp3');
      expect(f.metaCached(), isFalse);
      final Tags t = Tags()..put('title', '晴天');
      f.cacheMeta(t, cover: true, lyrics: true, durationMs: 250000, bitrateKbps: 320);
      expect(f.metaCached(), isTrue);
      expect(f.cachedHasCover, isTrue);
      expect(f.cachedDurationMs, 250000);
      f.clearMeta();
      expect(f.metaCached(), isFalse);
      expect(f.cachedHasCover, isFalse);

      final VFile f2 = f.copyWith(name: 'b.mp3');
      expect(f2.name, 'b.mp3');
      expect(f2.docId, f.docId);
    });

    test('路径', () {
      final VFile f =
          VFile(docId: 'primary:Music/周杰伦/晴天.mp3', name: '晴天.mp3');
      expect(f.pathAfterRoot(), 'Music/周杰伦/晴天.mp3');
      expect(f.relativePath('primary:Music'), '周杰伦/晴天.mp3');
    });
  });

  group('Tags', () {
    test('键集与 year 截断', () {
      final Tags t = Tags();
      expect(t.get('title'), '');
      t.put('title', '  晴天  ');
      expect(t.get('title'), '晴天');
      t.put('year', '2003-07-31');
      expect(t.get('year'), '2003');
      expect(t.anyValue(), isTrue);
      expect(Tags.keys.length, 8);
      expect(Tags.keys, contains('albumArtist'));
      expect(Tags.labels['lyrics'], '歌词');
      expect(Tags.labels['albumArtist'], '专辑艺术家');
    });

    test('copy 独立', () {
      final Tags t = Tags()..put('artist', '周杰伦');
      final Tags c = t.copy();
      c.put('artist', '林俊杰');
      expect(t.get('artist'), '周杰伦');
      expect(c.get('artist'), '林俊杰');
    });
  });

  group('TrackGroup', () {
    test('排序与主音频', () {
      final VFile dir = VFile(docId: 'primary:Music', name: 'Music', dir: true);
      final TrackGroup g = TrackGroup(dir, '晴天');
      g.audio.add(VFile(docId: 'a.flac', name: '晴天.flac'));
      g.audio.add(VFile(docId: 'a.mp3', name: '晴天.mp3'));
      g.lyrics.add(VFile(docId: 'a.lrc', name: '晴天.lrc'));
      final List<VFile> all = g.allFiles();
      expect(all[0].ext(), '.mp3');
      expect(all[1].ext(), '.flac');
      expect(all[2].ext(), '.lrc');
      expect(g.primaryAudio()!.ext(), '.mp3');
      expect(g.displayName(), '晴天（3 个文件）');
    });
  });

  group('LyricsDoc', () {
    test('解析', () {
      const String lrc = '[00:01.50]第一行\n[00:03.20][00:09.20]重复行\n[00:05.123]高精度\n';
      final List<LyricLine> lines = LyricsDoc.parse(lrc);
      expect(lines.length, 4);
      expect(lines[0].timeMs, 1500);
      expect(lines[1].timeMs, 3200);
      expect(lines[2].timeMs, 9200);
      expect(lines[3].timeMs, 5123);
      expect(lines[1].text, '重复行');
      expect(LyricsDoc.parse(null), isEmpty);
      expect(LyricsDoc.parse('随便写点什么'), isEmpty);
      expect(LyricsDoc.timedLineCount(lrc), 4);
    });

    test('元信息行识别', () {
      expect(LyricsDoc.isMetadataLine('作词：小寒'), isTrue);
      expect(LyricsDoc.isMetadataLine('作曲 : 某某'), isTrue);
      expect(LyricsDoc.isMetadataLine('OP：某某音乐'), isTrue);
      expect(LyricsDoc.isMetadataLine('编曲 陈伟'), isTrue);
      expect(LyricsDoc.isMetadataLine('Producer: Someone'), isTrue);
      expect(LyricsDoc.isMetadataLine('作词人的眼泪'), isFalse);
      expect(LyricsDoc.isMetadataLine('那一年的夏天'), isFalse);
      expect(LyricsDoc.isMetadataLine('  '), isFalse);
    });

    test('清洗', () {
      const String lrc =
          '作词 : 小寒\n作曲 : 某某\n[00:01.00]第一句\n[00:02.00]\n[00:03.00]第二句\n';
      final String clean = LyricsDoc.clean(lrc);
      expect(clean.contains('作词'), isFalse);
      expect(clean.contains('作曲'), isFalse);
      expect(clean.contains('[00:01.00]第一句'), isTrue);
      expect(clean.contains('[00:03.00]第二句'), isTrue);
      expect(clean.contains('[00:02.00]'), isTrue);
      expect(LyricsDoc.timedLineCount(clean), 3);

      const String plain = '作词 : 小寒\n这是第一句\n这是第二句\n';
      final String cleaned = LyricsDoc.clean(plain);
      expect(cleaned.contains('作词'), isFalse);
      expect(cleaned.contains('这是第一句'), isTrue);
    });

    test('合并译文', () {
      const String orig = '[00:19.629]Hello\n[00:22.100]World\n';
      const String trans = '[00:19.64]你好\n[00:22.12]世界\n';
      final String merged = LyricsDoc.mergeTranslation(orig, trans);
      expect(merged.contains('Hello'), isTrue);
      expect(merged.contains('World'), isTrue);
      expect(merged.contains('你好'), isTrue);
      expect(merged.contains('世界'), isTrue);
      expect(LyricsDoc.translationLineCount(merged), 2);
      expect(merged.indexOf('你好'), greaterThan(merged.indexOf('Hello')));
      expect(merged.indexOf('世界'), greaterThan(merged.indexOf('World')));

      expect(LyricsDoc.translationLineCount(
          LyricsDoc.mergeTranslation(orig, '[00:25.000]太晚了\n')), 0);
      expect(LyricsDoc.mergeTranslation(orig, ''), LyricsDoc.clean(orig));
      expect(LyricsDoc.translationLineCount(
          LyricsDoc.mergeTranslation('[00:01.00]纯音乐\n', '[00:01.00]纯音乐\n')), 0);
      expect(LyricsDoc.translationLineCount(
          LyricsDoc.mergeTranslation(orig, '[00:19.63]作词：某人\n')), 0);
      expect(LyricsDoc.translationLineCount(
          LyricsDoc.mergeTranslation('[00:10.00]A\n', '[00:10.14]B\n')), 1);
    });

    test('格式化与摘要', () {
      expect(LyricsDoc.format(0), '[00:00.00]');
      expect(LyricsDoc.format(65500), '[01:05.50]');
      expect(LyricsDoc.format(120000), '[02:00.00]');
      final String merged =
          LyricsDoc.mergeTranslation('[00:01.00]A\n[00:02.00]B\n', '[00:01.00]甲\n');
      final String sum = LyricsDoc.summary(merged);
      expect(sum.contains('3 行'), isTrue);
      expect(sum.contains('含译文 1 行'), isTrue);
      expect(LyricsDoc.summary('只有文字').contains('纯文本'), isTrue);
      expect(LyricsDoc.sorted('[00:05.00]B\n[00:01.00]A\n')[0].text, 'A');
    });
  });

  group('JournalEntry', () {
    test('jsonl 往返', () {
      final JournalEntry e = JournalEntry()
        ..id = 'j1'
        ..timestamp = '2026-10-25T00:00:00'
        ..uri = 'content://tree/doc1'
        ..batchId = 'b1'
        ..status = 'applied'
        ..targetId = 't1'
        ..name = '晴天.mp3';
      e.before = <String, String>{'title': '旧标题', 'artist': ''};
      e.after = <String, String>{'title': '晴天', 'artist': '周杰伦'};
      final JournalEntry back = JournalEntry.fromJsonLine(e.toJsonLine());
      expect(back.id, 'j1');
      expect(back.batchId, 'b1');
      expect(back.before['title'], '旧标题');
      expect(back.after['artist'], '周杰伦');
      expect(back.status, 'applied');
      expect(back.name, '晴天.mp3');
      expect(JournalEntry.fromJsonLine('not json').id, '');
    });
  });

  group('Candidate/Query/LyricHit', () {
    test('字段默认值', () {
      final Candidate c = Candidate();
      expect(c.merged, 1);
      expect(c.confidence, 0.0);
      c.source = 'netease';
      c.title = '晴天';
      expect(c.title, '晴天');

      final Query q = Query();
      expect(q.useCnSources, isTrue);
      expect(q.filenameWeight, 0.2);

      final LyricHit h = LyricHit()..synced = '[00:01.00]A';
      expect(h.hasLyrics(), isTrue);
      expect(LyricHit.label('netease'), '网易云');
    });
  });

  group('TaskControl', () {
    test('进度上报', () {
      final TaskControl c = TaskControl('准备中');
      c.report(3, 12, '正在匹配：a.mp3');
      expect(c.percent(), 25);
      c.report(0, 0, '扫描中');
      expect(c.percent(), -1);
      expect(c.summary().contains('扫描中'), isTrue);
    });

    test('取消', () {
      final TaskControl c = TaskControl();
      expect(c.isCancelled(), isFalse);
      c.cancel();
      expect(c.isCancelled(), isTrue);
      expect(c.isCancelledNow(), isTrue);
    });

    test('暂停/恢复/结束（Dart 单线程适配）', () {
      final TaskControl c = TaskControl();
      c.pause();
      expect(c.isPaused(), isTrue);
      c.resume();
      expect(c.isPaused(), isFalse);
      c.pause();
      c.cancel();
      expect(c.isPaused(), isFalse);
      expect(c.isCancelled(), isTrue);
      c.finish();
      expect(c.isFinished(), isTrue);
    });
  });

  group('PartialSink', () {
    test('基础语义', () {
      final PartialSink<String> sink = PartialSink<String>();
      expect(sink.size(), 0);
      expect(sink.snapshot(), isEmpty);
      expect(sink.isEmpty(), isTrue);
      sink.add(null);
      expect(sink.size(), 0);
      sink.add('a');
      final List<String> first = sink.snapshot();
      expect(first, ['a']);
      sink.add('b');
      expect(first, ['a']);
      expect(sink.size(), 2);
      sink.clear();
      expect(sink.size(), 0);
    });

    test('按序号归位', () {
      final PartialSink<int> sink = PartialSink<int>();
      sink.addAt(3, 30);
      sink.addAt(1, 10);
      sink.addAt(2, 20);
      sink.add(99);
      expect(sink.snapshot(), [99, 10, 20, 30]);
    });
  });

  group('HealthCheck', () {
    HealthItem item(String name, String ext, int size,
        {bool title = false,
        bool artist = false,
        bool album = false,
        bool cover = false,
        bool lyrics = false}) {
      return HealthItem(name, ext, size)
        ..title = title
        ..artist = artist
        ..album = album
        ..cover = cover
        ..lyrics = lyrics;
    }

    test('单条缺失与得分', () {
      final HealthItem full = item('a.mp3', '.mp3', 100,
          title: true, artist: true, album: true, cover: true, lyrics: true);
      expect(full.score(), 5);
      expect(full.missing(), isEmpty);
      final HealthItem bare = item('b.mp3', '.mp3', 100);
      expect(bare.score(), 0);
      expect(bare.missing().split('/').length, 5);
      final HealthItem nc = item('c.flac', '.flac', 100,
          title: true, artist: true, album: true);
      expect(nc.score(), 3);
      expect(nc.missing(), '缺封面/缺歌词');
    });

    test('累加与完整度', () {
      final HealthReport r = HealthReport();
      r.add(item('a.mp3', '.mp3', 100,
          title: true, artist: true, album: true, cover: true, lyrics: true));
      r.add(item('c.flac', '.flac', 100, title: true, artist: true, album: true));
      r.add(item('b.mp3', '.mp3', 100));
      expect(r.audio, 3);
      expect(r.bytes, 300);
      expect(r.noTitle, 1);
      expect(r.noArtist, 1);
      expect(r.noAlbum, 1);
      expect(r.noCover, 2);
      expect(r.noLyrics, 2);
      expect(r.complete(), 1);
      expect(r.issues.length, 2);
      expect(r.completeness(), 53);
      expect(r.headline().contains('3 首'), isTrue);
    });

    test('完整度/格式分布/尺寸', () {
      final HealthItem full = item('a.mp3', '.mp3', 1,
          title: true, artist: true, album: true, cover: true, lyrics: true);
      expect((HealthReport()..add(full)).completeness(), 100);
      expect((HealthReport()..add(full)).issues, isEmpty);
      final HealthReport empty = HealthReport();
      expect(empty.completeness(), 0);
      expect(empty.headline().contains('没有'), isTrue);

      final HealthReport exts = HealthReport();
      exts.add(item('1.mp3', '.mp3', 1,
          title: true, artist: true, album: true, cover: true, lyrics: true));
      exts.add(item('2.mp3', '.mp3', 1,
          title: true, artist: true, album: true, cover: true, lyrics: true));
      exts.add(item('3.flac', '.flac', 1,
          title: true, artist: true, album: true, cover: true, lyrics: true));
      expect(exts.extLine().startsWith('mp3 2 首'), isTrue);
      expect(exts.extLine().contains('flac 1 首'), isTrue);

      final HealthReport other = HealthReport()
        ..add(item('noext', '', 1,
            title: true, artist: true, album: true, cover: true, lyrics: true));
      expect(other.extLine().contains('其它'), isTrue);

      final HealthReport many = HealthReport();
      for (int i = 0; i < 260; i++) {
        many.add(item('x$i.mp3', '.mp3', 1));
      }
      expect(many.issues.length, 200);

      expect(HealthCheck.size(512), '512 B');
      expect(HealthCheck.size(2048), '2.0 KB');
      expect(HealthCheck.size(3 * 1024 * 1024), '3.0 MB');
      expect(HealthCheck.size(2 * 1024 * 1024 * 1024).startsWith('2.00 GB'), isTrue);
    });
  });

  group('DuplicateGroup', () {
    VFile vf(String docId, String name, {int size = 0}) =>
        VFile(docId: docId, name: name, size: size);

    test('归一键', () {
      expect(DuplicateGroup.normalizeDuplicateKey('晴天 (1)'), '晴天');
      expect(DuplicateGroup.normalizeDuplicateKey('晴天'), '晴天');
      expect(DuplicateGroup.titleKeyOf('陈奕迅-十年'), '十年');
      expect(DuplicateGroup.artistKeyOf('陈奕迅-十年'), '陈奕迅');
    });

    test('建议保留与摘要', () {
      final DuplicateGroup g = DuplicateGroup('晴天');
      g.files.add(
          DuplicateItem(vf('a.mp3', '晴天.mp3', size: 1000), '晴天.mp3', 1000, 240.0));
      g.files.add(DuplicateItem(
          vf('a2.mp3', '晴天(1).mp3', size: 900), '晴天(1).mp3', 900, 240.0));
      expect(DuplicateGroup.recommendKeep(g), 0);
      expect(g.wastedBytes(), 900);
      expect(DuplicateGroup.contentLabel(g), '');
      g.content = DuplicateGroup.contentSame;
      expect(DuplicateGroup.contentLabel(g), '内容一致（首尾采样相同）');
      final String summary = DuplicateGroup.summary([g]);
      expect(summary.contains('1 组'), isTrue);
      expect(summary.contains('1 个多余文件'), isTrue);
      expect(DuplicateGroup.durationSummary(g), isNotEmpty);
    });
  });
}
