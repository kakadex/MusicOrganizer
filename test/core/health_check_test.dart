import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/health/health_check.dart';

HealthInput _input(
  String name, {
  String docId = 'r/a.mp3',
  int durationMs = 200000,
  bool title = true,
  bool artist = true,
  bool album = true,
  bool cover = true,
  bool lyrics = true,
}) {
  return HealthInput(
    docId: docId,
    name: name,
    size: 1024,
    durationMs: durationMs,
    title: title,
    artist: artist,
    album: album,
    cover: cover,
    lyrics: lyrics,
  );
}

void main() {
  group('单曲规则', () {
    test('五维齐全且文件名正常时没有问题', () {
      final Set<HealthIssue> issues = HealthAudit.issuesOf(_input('晴天.mp3'));
      expect(issues, isEmpty);
      expect(HealthTrack(_input('晴天.mp3'), issues).detail(), '五维齐全');
    });

    test('缺标签 / 封面 / 歌词逐项命中', () {
      final Set<HealthIssue> issues = HealthAudit.issuesOf(
        _input('晴天.mp3', title: false, artist: false, album: false, cover: false, lyrics: false),
      );
      expect(issues, <HealthIssue>{
        HealthIssue.noTitle,
        HealthIssue.noArtist,
        HealthIssue.noAlbum,
        HealthIssue.noCover,
        HealthIssue.noLyrics,
      });
    });

    test('时长异常边界：未知放行，短于 10 秒或长于 30 分钟命中', () {
      expect(HealthAudit.badDuration(0), isFalse);
      expect(HealthAudit.badDuration(9999), isTrue);
      expect(HealthAudit.badDuration(10000), isFalse);
      expect(HealthAudit.badDuration(30 * 60 * 1000), isFalse);
      expect(HealthAudit.badDuration(30 * 60 * 1000 + 1), isTrue);
    });

    test('可疑文件名：纯数字 / 占位名 / 未命名 / 空格与非法字符', () {
      expect(HealthAudit.suspiciousName('01.mp3'), isTrue);
      expect(HealthAudit.suspiciousName('track01.flac'), isTrue);
      expect(HealthAudit.suspiciousName('Track 02.mp3'), isTrue);
      expect(HealthAudit.suspiciousName('未命名.mp3'), isTrue);
      expect(HealthAudit.suspiciousName('unknown song.mp3'), isTrue);
      expect(HealthAudit.suspiciousName('副本.mp3'), isTrue);
      expect(HealthAudit.suspiciousName(' 晴天.mp3'), isTrue);
      expect(HealthAudit.suspiciousName('晴 天.mp3'), isFalse);
      expect(HealthAudit.suspiciousName('a?b.mp3'), isTrue);
      expect(HealthAudit.suspiciousName('晴天.mp3'), isFalse);
    });
  });

  group('汇总与筛选', () {
    HealthResult build() => HealthAudit.run(<HealthInput>[
          _input('完整.mp3', docId: 'r/1'),
          _input('缺封面.mp3', docId: 'r/2', cover: false),
          _input('01.mp3', docId: 'r/3'),
          _input('太短.mp3', docId: 'r/4', durationMs: 3000),
        ]);

    test('逐项统计与完整度只按标签五维计算', () {
      final HealthResult r = build();
      expect(r.audio, 4);
      expect(r.countOf(HealthIssue.noCover), 1);
      expect(r.countOf(HealthIssue.oddName), 1);
      expect(r.countOf(HealthIssue.badDuration), 1);
      // 20 个标签维度里缺 1 个 → 19/20
      expect(r.completeness(), 95);
      expect(r.complete, 3);
      expect(r.problems.length, 3);
    });

    test('可一键筛出命中某一项的曲目', () {
      final HealthResult r = build();
      expect(r.withIssue(HealthIssue.noCover).single.input.docId, 'r/2');
      expect(r.withIssue(HealthIssue.oddName).single.input.name, '01.mp3');
      expect(r.withIssue(HealthIssue.badDuration).single.input.name, '太短.mp3');
      expect(r.withIssue(HealthIssue.noTitle), isEmpty);
    });

    test('结论与逐项文案', () {
      final HealthResult r = build();
      expect(r.headline(), contains('完整度 95%'));
      expect(r.headline(), contains('待处理 3 首'));
      expect(r.lines(), contains('缺封面 1 首'));
      expect(r.lines(), contains('文件名可疑 1 首'));
      expect(HealthAudit.run(<HealthInput>[]).headline(), '还没有扫描到音频文件');
    });
  });
}
