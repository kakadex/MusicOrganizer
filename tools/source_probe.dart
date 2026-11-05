// ignore_for_file: file_names, avoid_print

/// 多家数据源实测对比（手工运行，不进单元测试）。
///
/// 对曲库里的每首歌，用 App 同一套源实现去问 8 家标签源，记录
/// 「能不能连、返回几条、有没有封面地址、耗时」，并汇总跨源一致度。
/// 结果按歌曲写 JSONL（可续跑），最后打印汇总。
///
/// 用法：
/// ```bash
/// dart run tools/source_probe.dart --limit 20                 # 先跑 20 首验证
/// dart run tools/source_probe.dart                            # 全量
/// dart run tools/source_probe.dart --dir D:/music --out D:/x.jsonl
/// ```
library;

import 'dart:convert';
import 'dart:io';

import 'package:musicorganizer/core/match/name_parser.dart';
import 'package:musicorganizer/core/match/text_util.dart';
import 'package:musicorganizer/core/model/candidate.dart';
import 'package:musicorganizer/core/model/query.dart';
import 'package:musicorganizer/core/model/tags.dart';
import 'package:musicorganizer/core/net/http_client.dart';
import 'package:musicorganizer/core/source/source_registry.dart';
import 'package:musicorganizer/core/source/tag_source.dart';
import 'package:musicorganizer/core/tag/tag_io.dart';

/// 标签源顺序（与 SourceRank 一致）。
const List<String> sourceKeys = <String>[
  'netease',
  'qqmusic',
  'kugou',
  'kuwo',
  'migu',
  'musicbrainz',
  'deezer',
  'itunes',
];

/// 单源单曲的探测结果。
class SourceProbe {
  int calls = 0;
  int fails = 0;
  int count = 0;
  int covers = 0;
  int ms = 0;
  String error = '';
  String firstTitle = '';
  bool get hasResult => count > 0;
  bool get hasCover => covers > 0;
}

/// 单曲结果。
class SongProbe {
  SongProbe(this.file, this.title, this.artist);

  final String file;
  final String title;
  final String artist;
  final Map<String, SourceProbe> sources = <String, SourceProbe>{};

  Map<String, Object?> toJson() => <String, Object?>{
        'file': file,
        'title': title,
        'artist': artist,
        'sources': <String, Object?>{
          for (final MapEntry<String, SourceProbe> e in sources.entries)
            e.key: <String, Object?>{
              'calls': e.value.calls,
              'fail': e.value.fails,
              'n': e.value.count,
              'cover': e.value.covers,
              'ms': e.value.ms,
              'err': e.value.error,
            },
        },
      };
}

String? _arg(List<String> args, String key) {
  final int at = args.indexOf(key);
  if (at < 0 || at + 1 >= args.length) return null;
  return args[at + 1];
}

/// 源实现自己会带的请求头；注入 fetch 时要手动补上，否则国内几家会返回空。
Map<String, String>? headersFor(String url) {
  if (url.contains('music.163.com')) {
    return <String, String>{
      'Referer': 'https://music.163.com/',
      'Cookie': 'appver=2.0.2',
    };
  }
  if (url.contains('y.qq.com')) return <String, String>{'Referer': 'https://y.qq.com/'};
  if (url.contains('migu.cn')) {
    return <String, String>{'Referer': 'https://app.c.nf.migu.cn/'};
  }
  return null;
}

Future<void> main(List<String> args) async {
  final String dir = _arg(args, '--dir') ?? r'C:/Android/test/MP3X2026';
  final int limit = int.tryParse(_arg(args, '--limit') ?? '') ?? 0;
  final String out =
      _arg(args, '--out') ?? r'C:/DSHX/out/source-probe.jsonl';
  final int timeoutMs = int.tryParse(_arg(args, '--timeout') ?? '') ?? 6000;

  final Directory root = Directory(dir);
  if (!root.existsSync()) {
    stderr.writeln('曲库不存在：$dir');
    exitCode = 2;
    return;
  }

  final List<File> files = root
      .listSync(recursive: true)
      .whereType<File>()
      .where((File f) => _isAudio(f.path))
      .toList()
    ..sort((File a, File b) => a.path.compareTo(b.path));
  final List<File> target = limit > 0 ? files.take(limit).toList() : files;
  print('曲库 ${files.length} 首，本轮 ${target.length} 首 → $out');
  print('');

  final File outFile = File(out);
  outFile.parent.createSync(recursive: true);
  final IOSink sink = outFile.openWrite();
  final Map<String, SourceProbe> totals = <String, SourceProbe>{
    for (final String k in sourceKeys) k: SourceProbe(),
  };
  final Map<String, int> songsWithResult = <String, int>{
    for (final String k in sourceKeys) k: 0,
  };
  final Map<String, int> songsWithCover = <String, int>{
    for (final String k in sourceKeys) k: 0,
  };
  int done = 0;
  int coverAny = 0;
  int multiAgree = 0;
  int multiSongs = 0;

  for (final File f in target) {
    done++;
    final SongProbe song = await _probeOne(f, timeoutMs);
    sink.writeln(jsonEncode(song.toJson()));

    // 汇总
    for (final MapEntry<String, SourceProbe> e in song.sources.entries) {
      final SourceProbe t = totals[e.key]!;
      t.calls += e.value.calls;
      t.fails += e.value.fails;
      t.count += e.value.count;
      t.covers += e.value.covers;
      t.ms += e.value.ms;
      if (e.value.error.isNotEmpty && t.error.isEmpty) t.error = e.value.error;
      if (e.value.hasResult) songsWithResult[e.key] = songsWithResult[e.key]! + 1;
      if (e.value.hasCover) songsWithCover[e.key] = songsWithCover[e.key]! + 1;
    }
    if (song.sources.values.any((SourceProbe p) => p.covers > 0)) coverAny++;
    final List<String> withResult = song.sources.entries
        .where((MapEntry<String, SourceProbe> e) => e.value.count > 0)
        .map((MapEntry<String, SourceProbe> e) => e.key)
        .toList();
    if (withResult.length >= 2) {
      multiSongs++;
      if (_agree(song)) multiAgree++;
    }

    if (done % 25 == 0) {
      print('已跑 $done/${target.length}（有封面 $coverAny，多源一致 $multiAgree/$multiSongs）');
    }
  }
  await sink.flush();
  await sink.close();

  _printSummary(totals, songsWithResult, songsWithCover, target.length, coverAny,
      multiSongs, multiAgree);
}

bool _isAudio(String path) {
  final String p = path.toLowerCase();
  return p.endsWith('.mp3') ||
      p.endsWith('.flac') ||
      p.endsWith('.m4a') ||
      p.endsWith('.ogg') ||
      p.endsWith('.opus') ||
      p.endsWith('.wav') ||
      p.endsWith('.wma') ||
      p.endsWith('.ape');
}

/// 多源是否「大体一致」：各源第一条候选的标题两两相似度平均 ≥ 0.7。
bool _agree(SongProbe song) {
  final List<String> titles = <String>[];
  for (final String key in sourceKeys) {
    final SourceProbe p = song.sources[key]!;
    if (p.count > 0 && p.firstTitle.isNotEmpty) titles.add(p.firstTitle);
  }
  if (titles.length < 2) return false;
  double sum = 0;
  int n = 0;
  for (int i = 0; i < titles.length; i++) {
    for (int j = i + 1; j < titles.length; j++) {
      sum += TextUtil.textSimilarity(titles[i], titles[j]);
      n++;
    }
  }
  return n > 0 && sum / n >= 0.7;
}

Future<SongProbe> _probeOne(File f, int timeoutMs) async {
  final String name = f.uri.pathSegments.last;
  final String stem = name.contains('.')
      ? name.substring(0, name.lastIndexOf('.'))
      : name;
  final String ext = name.contains('.')
      ? name.substring(name.lastIndexOf('.') + 1).toLowerCase()
      : '';
  Tags tags = Tags();
  try {
    tags = TagIO.readLocal(await f.readAsBytes(), ext);
  } catch (_) {}
  final Query q = Query()
    ..filenameCandidates = NameParser.candidatePairs(stem)
    ..embeddedTags = tags.toMap();
  final String title = TagQuery.title(q);
  final String artist = TagQuery.artist(q);
  final SongProbe song = SongProbe(name, title, artist);

  await Future.wait(sourceKeys.map((String key) async {
    final TagSource? src = SourceRegistry.get(key);
    final SourceProbe p = SourceProbe();
    song.sources[key] = p;
    if (src == null) return;
    final Stopwatch sw = Stopwatch()..start();
    try {
      final List<Candidate> items = await src.search(q,
          fetch: (String url, Map<String, String>? params) async {
            p.calls++;
            final Object? r =
                await Http.getJson(url, params, headersFor(url), timeoutMs);
            if (r == null) p.fails++;
            return r;
          });
      p.count = items.length;
      p.covers = items.where((Candidate c) => c.coverUrl.trim().isNotEmpty).length;
      if (items.isNotEmpty) p.firstTitle = items.first.title;
    } catch (e) {
      p.error = e.runtimeType.toString();
    }
    p.ms = sw.elapsedMilliseconds;
  }));
  return song;
}

void _printSummary(
  Map<String, SourceProbe> totals,
  Map<String, int> songsWithResult,
  Map<String, int> songsWithCover,
  int songs,
  int coverAny,
  int multiSongs,
  int multiAgree,
) {
  print('');
  print('=== 各源汇总（$songs 首）===');
  print('源            调用   失败   返回条数  有封面条数  有结果的歌  有封面的歌  平均耗时');
  for (final String key in sourceKeys) {
    final SourceProbe t = totals[key]!;
    final String avg = (t.ms / (songs == 0 ? 1 : songs)).toStringAsFixed(0);
    print('${key.padRight(12)} '
        '${t.calls.toString().padLeft(5)} '
        '${t.fails.toString().padLeft(6)} '
        '${t.count.toString().padLeft(8)} '
        '${t.covers.toString().padLeft(10)} '
        '${songsWithResult[key].toString().padLeft(10)} '
        '${songsWithCover[key].toString().padLeft(10)} '
        '${avg}ms');
  }
  print('');
  print('有封面（任一家给图）：$coverAny/$songs');
  print('多源都返回结果：$multiSongs 首，其中标题大体一致：$multiAgree 首');
  print('明细：见 JSONL（--out 指定）');
}
