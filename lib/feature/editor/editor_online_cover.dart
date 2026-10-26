/// 编辑器里的「在线取封面」：多源查出候选封面，下载后让用户挑一张。
///
/// 只下载候选里的封面图（不写盘），选中后由页面持有字节，走同一条事务写回。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app/ui_kit.dart';
import '../../core/match/local_query.dart';
import '../../core/model/candidate.dart';
import '../../core/model/query.dart';
import '../../core/model/tags.dart';
import '../../core/model/vfile.dart';
import '../../core/net/http_client.dart';
import '../../core/source/aggregator.dart';

/// 下载上限（单张封面）。
const int kCoverMaxBytes = 8 * 1024 * 1024;

/// 在线取封面：返回用户选中的图片字节（没选返回 null）。
Future<Uint8List?> pickOnlineCover(
    BuildContext context, VFile file, Tags current) async {
  final Query q = LocalQuery.forFile(file, current);
  showMoSheet<void>(
    context,
    title: '正在找封面…',
    children: <Widget>[
      const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      ),
    ],
  );
  final AggregateResult agg = await Aggregator.tagCandidates(
      q, chinese: LocalQuery.chinese(q));
  if (!context.mounted) return null;
  Navigator.of(context).pop();
  final List<Candidate> withCover = agg.candidates
      .where((Candidate c) => c.coverUrl.trim().isNotEmpty)
      .toList();
  if (withCover.isEmpty) {
    moSnack(context, '候选里没有带封面的条目');
    return null;
  }
  return showModalBottomSheet<Uint8List>(
    context: context,
    isScrollControlled: true,
    backgroundColor: MoKit.bg(context),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (BuildContext ctx) => _CoverSheet(candidates: withCover),
  );
}

/// 候选封面网格（点一张即选中）。
class _CoverSheet extends StatelessWidget {
  const _CoverSheet({required this.candidates});

  final List<Candidate> candidates;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(MoKit.pagePad, 14, MoKit.pagePad, 6),
              child: Text('在线封面（${candidates.length} 张）',
                  style: TextStyle(
                      fontSize: MoKit.fsTitle, color: MoKit.text(context))),
            ),
            Flexible(
              child: GridView.builder(
                padding: const EdgeInsets.all(MoKit.pagePad),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                ),
                itemCount: candidates.length,
                itemBuilder: (BuildContext ctx, int i) {
                  final Candidate c = candidates[i];
                  return _CoverTile(
                    url: c.coverUrl,
                    label: '${c.title}\n${c.artist}',
                    onPick: () async {
                      final Uint8List? bytes = await Http.getBytes(
                          c.coverUrl, null, null, Http.readTimeoutOverseasMs,
                          kCoverMaxBytes);
                      if (!ctx.mounted) return;
                      if (bytes == null || bytes.isEmpty) {
                        moSnack(ctx, '封面下载失败');
                        return;
                      }
                      Navigator.of(ctx).pop(bytes);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 一张候选封面。
class _CoverTile extends StatelessWidget {
  const _CoverTile({required this.url, required this.label, required this.onPick});

  final String url;
  final String label;
  final Future<void> Function() onPick;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onPick(),
      borderRadius: BorderRadius.circular(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(url,
                  fit: BoxFit.cover,
                  errorBuilder: (BuildContext context, Object error, StackTrace? stack) =>
                      Container(
                        color: MoKit.line(context),
                        child: Icon(Icons.broken_image_outlined,
                            color: MoKit.faint(context)),
                      )),
            ),
          ),
          const SizedBox(height: 4),
          Text(label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, color: MoKit.sub(context))),
        ],
      ),
    );
  }
}
