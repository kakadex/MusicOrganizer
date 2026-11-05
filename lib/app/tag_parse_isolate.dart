/// 把批量标签解析送进后台 isolate（性能排查报告 §5.1 主方案，0.2.73）。
///
/// 这一层在 `lib/app/`（可以 import flutter），`lib/core/scan/tag_parse_batch.dart`
/// 里的纯函数保持零 flutter 依赖。
///
/// ## 用法与注意
///
/// - **必须按批调用**：`Isolate.run` 每次起一个 isolate 开销 1~3ms，
///   一首一个反而更慢；一批 20~50 首才划算。
/// - 入参的「字节」要在 UI isolate 先读好（`loadForTags` 走 SAF 跨进程，
///   这部分本来就在平台线程池上跑，不用挪）；真正挪走的是**解析**——
///   `TagIO.readLocal` + `CoverReader.read` 都是同步 CPU 调用，
///   输入 512KB~2MB 时一首要几毫秒，900 首就是几秒全压在 UI 线程上。
/// - 返回结果与输入**一一对应**，单首失败返回空 map（与 readHead 的
///   单首容错语义一致）。
library;

import 'dart:isolate';
import 'dart:typed_data';

import '../core/scan/tag_parse_batch.dart';

/// 一首待解析的文件（UI isolate 侧准备）。
class TagParseJob {
  TagParseJob({required this.ext, required this.bytes});

  /// 扩展名（含点，如 `.mp3`）。
  final String ext;

  /// 已读出的文件字节。
  final Uint8List bytes;
}

/// 一首解析完成的结果（UI isolate 侧消费）。
class TagParseResult {
  TagParseResult({required this.tags, this.cover});

  /// 解析出的标签；失败时是空 Tags。
  final Map<String, String> tags;

  /// 内嵌封面字节；没有为 null。
  final Uint8List? cover;
}

/// 批量解析：在后台 isolate 里跑 [parseTagBytesBatch]。
///
/// 返回结果与 [jobs] 一一对应。
Future<List<TagParseResult>> parseTagsInIsolate(List<TagParseJob> jobs) async {
  if (jobs.isEmpty) return <TagParseResult>[];
  final List<ParseInput> inputs = <ParseInput>[
    for (final TagParseJob j in jobs)
      ParseInput(ext: j.ext, bytes: Uint8List.fromList(j.bytes)),
  ];
  final List<ParseOutput> outputs = await Isolate.run(
    () => parseTagBytesBatch(inputs),
  );
  return <TagParseResult>[
    for (final ParseOutput o in outputs)
      TagParseResult(tags: o.values, cover: o.cover),
  ];
}
