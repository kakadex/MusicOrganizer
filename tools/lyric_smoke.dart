// ignore_for_file: file_names, avoid_print

/// 歌词链路自检（手工运行，不进单元测试）。
///
/// 走 App 里同一套：五源并发 → offerScore 打分 → 打印每条候选的来源与分数。
/// 用来分辨「源没返回」还是「打分把候选筛掉了」。
///
/// 用法：`dart run tools/lyric_smoke.dart "陈慧琳-记事本.mp3" [--proxy host:port]`
library;

import 'dart:io';

import 'package:musicorganizer/core/match/local_query.dart';
import 'package:musicorganizer/core/model/lyric_hit.dart';
import 'package:musicorganizer/core/model/query.dart';
import 'package:musicorganizer/core/model/tags.dart';
import 'package:musicorganizer/core/model/vfile.dart';
import 'package:musicorganizer/core/net/proxy_settings.dart';
import 'package:musicorganizer/core/source/aggregator.dart';
import 'package:musicorganizer/core/source/lyric_source.dart';
import 'package:musicorganizer/core/source/offer_score.dart';

Future<void> main(List<String> args) async {
  final String name = args.isNotEmpty && !args.first.startsWith('--')
      ? args.first
      : '示例歌手-示例歌名.mp3';
  final int at = args.indexOf('--proxy');
  if (at >= 0 && at + 1 < args.length) {
    final String spec = args[at + 1];
    NetworkProxy.configure(
      ProxyMode.manual,
      host: spec.substring(0, spec.lastIndexOf(':')),
      port: spec.substring(spec.lastIndexOf(':') + 1),
    );
  }

  final VFile f = VFile(docId: name, name: name);
  final Query q = LocalQuery.forFile(f, Tags());
  final LyricQuery lq = LocalQuery.lyric(q);
  final bool cn = LocalQuery.chinese(q);
  print('检索：title="${lq.title}" artist="${lq.artist}" 中文=$cn');
  print('代理：${NetworkProxy.describe()}');
  print('');

  final LyricAggregateResult agg = await Aggregator.lyricCandidates(lq);
  final List<LyricHit> hits = agg.hits;
  if (agg.errors.isNotEmpty) {
    print('源报错：${agg.errors}');
  }
  print('候选 ${hits.length} 条');
  int pass = 0;
  for (final LyricHit h in hits) {
    final double s = offerScore(
      localTitle: lq.title,
      localArtist: lq.artist,
      localDuration: lq.duration,
      candidateTitle: h.title,
      candidateArtist: h.artist,
      candidateDuration: h.duration,
      source: h.source,
      chinese: cn,
      hasTiming: h.synced.isNotEmpty,
    );
    if (s > 0) pass++;
    print('  [${h.source}] ${h.title} / ${h.artist}  '
        '${h.synced.isNotEmpty ? '有时间轴' : '无时间轴'}  '
        '${h.translation.isNotEmpty ? '有译文' : ''}  分=${s.toStringAsFixed(2)}'
        '${s < 0 ? '（淘汰）' : ''}');
  }
  print('');
  print('通过打分 $pass 条');
  if (pass == 0) exitCode = 1;
}
