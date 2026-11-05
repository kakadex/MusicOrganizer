// ignore_for_file: file_names, avoid_print

/// 全量曲库端到端跑一遍：用 App 同一套聚合 / 专辑第二跳逻辑，
/// 统计「匹配到多少、封面从哪来、多少没结果、多少是源不可用」。
///
/// 只读本地文件，不写盘、不改标签。
///
/// 用法：
/// ```bash
/// dart run tools/library_round.dart --limit 20                    # 先小样本
/// dart run tools/library_round.dart                               # 全量
/// dart run tools/library_round.dart --dir D:/music --out D:/r.jsonl
/// ```
library;

import 'dart:convert';
import 'dart:io';

import 'package:musicorganizer/core/match/name_parser.dart';
import 'package:musicorganizer/core/model/query.dart';
import 'package:musicorganizer/core/model/tags.dart';
import 'package:musicorganizer/core/source/aggregator.dart';
import 'package:musicorganizer/core/source/album_cover.dart';
import 'package:musicorganizer/core/source/album_cover_cache.dart';
import 'package:musicorganizer/core/source/tag_source.dart';
import 'package:musicorganizer/core/tag/tag_io.dart';
import 'package:musicorganizer/feature/covers/covers_logic.dart';

String? _arg(List<String> args, String key) {
  final int at = args.indexOf(key);
  if (at < 0 || at + 1 >= args.length) return null;
  return args[at + 1];
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

Future<void> main(List<String> args) async {
  final String dir = _arg(args, '--dir') ?? r'C:/Android/test/MP3X2026';
  final int limit = int.tryParse(_arg(args, '--limit') ?? '') ?? 0;
  final String out = _arg(args, '--out') ?? r'C:/DSHX/out/library-round.jsonl';
  final String cachePath =
      _arg(args, '--cache') ?? r'C:/DSHX/out/library-round-covers.json';

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
  print('曲库 ${files.length} 首，本轮 ${target.length} 首');
  print('明细 → $out');
  print('');

  final AlbumCoverCache cache = AlbumCoverCache.open(File(cachePath));
  final File outFile = File(out);
  outFile.parent.createSync(recursive: true);
  final IOSink sink = outFile.openWrite();

  int matched = 0;
  int unmatched = 0;
  int throttledUnmatched = 0;
  int coverTrack = 0;
  int coverAlbum = 0;
  final Map<String, int> coverBySource = <String, int>{};
  int noCover = 0;
  int coverThrottled = 0;

  int done = 0;
  final Stopwatch total = Stopwatch()..start();

  for (final File f in target) {
    done++;
    final String name = f.uri.pathSegments.last;
    final String stem =
        name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name;
    final String ext =
        name.contains('.') ? name.substring(name.lastIndexOf('.') + 1) : '';
    Tags tags = Tags();
    try {
      tags = TagIO.readLocal(await f.readAsBytes(), ext);
    } catch (_) {}
    final Query q = Query()
      ..filenameCandidates = NameParser.candidatePairs(stem)
      ..embeddedTags = tags.toMap();
    final bool chinese = TagQuery.isChineseTrack(q);

    String coverUrl = '';
    String coverSource = '';
    bool temporary = false;
    int candidates = 0;
    bool throttled = false;

    try {
      final AggregateResult agg = await Aggregator.tagCandidates(q,
          chinese: chinese, preferCover: true);
      throttled = agg.throttled;
      candidates = agg.candidates.length;
      if (agg.candidates.isNotEmpty) {
        matched++;
        coverUrl = CoverPick.urlOf(agg.candidates);
        if (coverUrl.isNotEmpty) {
          coverSource = '曲目候选';
        } else {
          // 第二跳：所有能给图的专辑库都问到，再对比挑最像的
          final String localArtist = TagQuery.artist(q);
          final (String album, String artist) =
              AlbumCover.fromCandidates(agg.candidates, localArtist);
          final AlbumCoverLookup hit =
              await AlbumCover.lookup(album, artist, cache: cache);
          coverUrl = hit.url;
          coverSource = hit.source;
          temporary = hit.temporary;
        }
      } else {
        unmatched++;
        if (throttled) throttledUnmatched++;
      }
    } catch (e) {
      unmatched++;
      coverSource = 'error:${e.runtimeType}';
    }

    if (coverUrl.isNotEmpty) {
      if (coverSource == '曲目候选') {
        coverTrack++;
      } else {
        coverAlbum++;
        coverBySource[coverSource] = (coverBySource[coverSource] ?? 0) + 1;
      }
    } else if (temporary) {
      coverThrottled++;
    } else {
      noCover++;
    }

    sink.writeln(jsonEncode(<String, Object?>{
      'file': name,
      'title': TagQuery.title(q),
      'artist': TagQuery.artist(q),
      'album': tags.get('album'),
      'chinese': chinese,
      'candidates': candidates,
      'matched': candidates > 0,
      'throttled': throttled,
      'cover': coverUrl,
      'coverSource': coverSource,
      'temporary': temporary,
    }));

    if (done % 20 == 0) {
      final double sec = total.elapsedMilliseconds / 1000;
      print('$done/${target.length}  '
          '匹配 $matched · 无结果 $unmatched（源不可用 $throttledUnmatched）· '
          '封面 曲目 $coverTrack / 专辑 $coverAlbum / 无 $noCover  '
          '（${(sec / done).toStringAsFixed(2)}s/首）');
    }
  }
  await sink.flush();
  await sink.close();
  cache.save();

  final double sec = total.elapsedMilliseconds / 1000;
  print('');
  print('=== 全量结果（${target.length} 首，用时 ${(sec / 60).toStringAsFixed(1)} 分钟）===');
  print('匹配到标签候选：$matched 首（${_pct(matched, target.length)}）');
  print('没有候选：$unmatched 首，其中因源不可用：$throttledUnmatched 首');
  print('封面：曲目候选带图 $coverTrack 首（${_pct(coverTrack, target.length)}）');
  print('      专辑第二跳补到 $coverAlbum 首（${_pct(coverAlbum, target.length)}）'
      '${coverBySource.isEmpty ? '' : ' · ${coverBySource.entries.map((MapEntry<String, int> e) => '${e.key}:${e.value}').join(', ')}'}');
  print('      联网暂不可用（可重试）$coverThrottled 首');
  print('      确实没图 $noCover 首');
  print('封面合计：${coverTrack + coverAlbum} 首（${_pct(coverTrack + coverAlbum, target.length)}）');
  print('明细 → $out');
}

String _pct(int n, int total) =>
    total == 0 ? '0%' : '${(n * 100 / total).toStringAsFixed(1)}%';
