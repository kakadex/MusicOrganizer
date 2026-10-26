// ignore_for_file: file_names, avoid_print

/// 匹配链路自检（手工运行，不进单元测试）。
///
/// 与 App 里「匹配标签」走完全相同的代码：文件名解析 → 多源并发 → 打分去重。
/// 用来回答「到底是网络不通，还是解析/打分把候选筛没了」。
///
/// 用法：
/// ```bash
/// dart run tools/match_smoke.dart "示例歌手-示例歌名.mp3"
/// dart run tools/match_smoke.dart "示例歌手-示例歌名.mp3" --proxy 127.0.0.1:7890
/// ```
library;

import 'dart:io';

import 'package:musicorganizer/core/match/name_parser.dart';
import 'package:musicorganizer/core/model/query.dart';
import 'package:musicorganizer/core/net/proxy_settings.dart';
import 'package:musicorganizer/core/source/aggregator.dart';
import 'package:musicorganizer/core/source/tag_source.dart';

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

  final String stem = name.contains('.')
      ? name.substring(0, name.lastIndexOf('.'))
      : name;
  final List<List<String>> pairs = NameParser.candidatePairs(stem);
  print('文件名：$name');
  print('解析候选：$pairs');

  final Query q = Query()
    ..filenameCandidates = pairs
    ..embeddedTags = <String, String>{}
    ..localDuration = null;

  print('检索词：title="${TagQuery.title(q)}" artist="${TagQuery.artist(q)}" '
      '中文=${TagQuery.isChineseTrack(q)}');
  print('代理：${NetworkProxy.describe()}');
  print('');

  final AggregateResult r = await Aggregator.tagCandidates(q);
  print('去重前 ${r.totalBeforeDedupe} 条，去重后 ${r.candidates.length} 条'
      '${r.errors.isEmpty ? '' : '，失败源：${r.errors}'}');
  for (final c in r.candidates) {
    print('  [${c.source}] ${c.title} / ${c.artist} / ${c.album}'
        '  年份=${c.year} 时长=${c.duration} 分=${c.confidence.toStringAsFixed(2)}'
        ' 合并=${c.merged}${c.coverUrl.isEmpty ? '' : ' 有封面'}');
  }
  if (r.candidates.isEmpty) {
    print('  （没有候选：检查检索词是否可搜、或接口是否需要代理）');
    exitCode = 1;
  }
}
