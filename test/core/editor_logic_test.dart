/// T13 三个页面的纯逻辑回归：编码修正 / 封面 URL 取舍 / 歌词选取排序。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicorganizer/core/model/candidate.dart';
import 'package:musicorganizer/core/model/lyric_hit.dart';
import 'package:musicorganizer/core/model/query.dart';
import 'package:musicorganizer/core/model/vfile.dart';
import 'package:musicorganizer/feature/covers/covers_logic.dart';
import 'package:musicorganizer/feature/editor/encoding_fix.dart';
import 'package:musicorganizer/feature/lyrics_batch/lyrics_logic.dart';

import '../support/gen.dart';

/// 把字节按「单字节字符」显示出来，模拟标签被错误解码后的样子。
String asLatin1(List<int> bytes) => String.fromCharCodes(bytes);

LyricHit hit({
  String source = 'netease',
  String title = '晴天',
  String artist = '周杰伦',
  double? duration,
  String synced = '',
  String plain = '',
}) {
  return LyricHit()
    ..source = source
    ..title = title
    ..artist = artist
    ..duration = duration
    ..synced = synced
    ..plain = plain;
}

void main() {
  group('EncodingFix', () {
    test('UTF-8 被当成单字节读入后能还原', () {
      final String broken = asLatin1(utf8.encode('晴天'));
      expect(EncodingFix.looksMojibake(broken), isTrue);
      final List<EncodingCandidate> list = EncodingFix.candidates(broken);
      final EncodingCandidate? utf8Hit = list
          .where((EncodingCandidate c) => c.charset == 'UTF-8')
          .firstOrNull;
      expect(utf8Hit, isNotNull);
      expect(utf8Hit!.text, '晴天');
    });

    test('GBK 乱码能按 GBK 还原', () {
      final String broken = asLatin1(<int>[0xC7, 0xE7, 0xCC, 0xEC]);
      expect(EncodingFix.looksMojibake(broken), isTrue);
      final List<EncodingCandidate> list = EncodingFix.candidates(broken);
      final EncodingCandidate? gbk =
          list.where((EncodingCandidate c) => c.charset == 'GBK').firstOrNull;
      expect(gbk, isNotNull);
      expect(gbk!.text, '晴天');
    });

    test('Big5 乱码能按 Big5 还原', () {
      final String broken = asLatin1(<int>[0xA4, 0xA4, 0xA4, 0xE5]);
      final List<EncodingCandidate> list = EncodingFix.candidates(broken);
      final EncodingCandidate? big5 =
          list.where((EncodingCandidate c) => c.charset == 'Big5').firstOrNull;
      expect(big5, isNotNull);
      expect(big5!.text, '中文');
    });

    test('正常文本不触发修正', () {
      expect(EncodingFix.looksMojibake('晴天'), isFalse);
      expect(EncodingFix.looksMojibake('Hello'), isFalse);
      expect(EncodingFix.looksMojibake(''), isFalse);
      expect(EncodingFix.candidates('晴天'), isEmpty);
    });

    test('单字节重音文本不硬凑成汉字', () {
      // é 的 UTF-8 字节只有 0xE9，不是合法的 UTF-8 序列；GBK/Big5 也不该硬解
      const String text = 'caf\u00E9';
      expect(EncodingFix.looksMojibake(text), isTrue);
      expect(EncodingFix.candidates(text), isEmpty);
    });
  });

  group('CoverPick', () {
    Candidate candidate(String url) => Candidate()..coverUrl = url;

    test('跳过空地址与非 http(s) 地址', () {
      final String url = CoverPick.urlOf(<Candidate>[
        candidate(''),
        candidate('file:///tmp/a.jpg'),
        candidate('not a url'),
        candidate('http://img.example.com/a.jpg'),
        candidate('https://img.example.com/b.jpg'),
      ]);
      expect(url, 'http://img.example.com/a.jpg');
    });

    test('没有可用地址返回空串', () {
      expect(CoverPick.urlOf(<Candidate>[candidate('')]), '');
      expect(CoverPick.urlOf(const <Candidate>[]), '');
    });

    test('图片按文件头识别，HTML 不当图片', () {
      expect(CoverPick.looksLikeImage(fakeJpeg(300, 300)), isTrue);
      expect(CoverPick.looksLikeImage(fakePng(64, 64)), isTrue);
      expect(
          CoverPick.looksLikeImage(
              Uint8List.fromList(utf8.encode('<html>not found</html>'))),
          isFalse);
    });
  });

  group('LyricPick', () {
    Query query({String title = '晴天', String artist = '周杰伦'}) => Query()
      ..embeddedTags = <String, String>{'title': title, 'artist': artist}
      ..filenameCandidates = <List<String>>[
        <String>[artist, title]
      ]
      ..localDuration = 269;

    test('按 offerScore 从高到低排序，最高分排第一', () {
      final List<LyricChoice> ranked = LyricPick.rank(
        query(),
        <LyricHit>[
          hit(
            source: 'lrclib',
            duration: 269,
            synced: '[00:01.00]故事的小黄花',
          ),
          hit(
            source: 'netease',
            duration: 269,
            synced: '[00:01.00]故事的小黄花',
          ),
          hit(
            source: 'lyricsovh',
            duration: 269,
            plain: '故事的小黄花',
          ),
        ],
      );
      expect(ranked.length, 3);
      expect(ranked.first.hit.source, 'netease');
      for (int i = 1; i < ranked.length; i++) {
        expect(ranked[i - 1].score >= ranked[i].score, isTrue);
      }
      expect(LyricPick.best(query(), <LyricHit>[
        hit(source: 'lrclib', duration: 269, plain: '故事的小黄花'),
        hit(source: 'netease', duration: 269, synced: '[00:01.00]故事的小黄花'),
      ])!.hit.source,
          'netease');
    });

    test('另一个版本（伴奏 / 现场）被淘汰', () {
      final List<LyricChoice> ranked = LyricPick.rank(query(), <LyricHit>[
        hit(title: '晴天（伴奏）', duration: 269, synced: '[00:01.00]伴奏'),
        hit(title: '晴天 (Live)', duration: 269, synced: '[00:01.00]现场'),
      ]);
      expect(ranked, isEmpty);
      expect(
          LyricPick.best(query(), <LyricHit>[
            hit(title: '晴天（伴奏）', duration: 269, synced: '[00:01.00]伴奏'),
          ]),
          isNull);
    });

    test('时长差超过 6 秒的候选被淘汰', () {
      final List<LyricChoice> ranked = LyricPick.rank(query(), <LyricHit>[
        hit(duration: 300, synced: '[00:01.00]别的录音'),
      ]);
      expect(ranked, isEmpty);
    });

    test('低置信分档与 .lrc 命名', () {
      final LyricChoice choice = LyricChoice(
        hit: hit(plain: '纯文本'),
        score: 0.4,
      );
      expect(choice.low, isTrue);
      final VFile f = VFile(docId: 'primary:Music/a.mp3', name: 'a.mp3');
      expect(LyricPick.lrcName(f), 'a.lrc');
    });

    test('有时间轴优先取时间轴文本', () {
      final LyricChoice choice = LyricChoice(
        hit: hit(synced: '[00:01.00]带轴', plain: '无轴'),
        score: 0.9,
      );
      expect(choice.hasTiming, isTrue);
      expect(choice.text, '[00:01.00]带轴');
      expect(choice.note.contains('带时间轴'), isTrue);
    });
  });
}
