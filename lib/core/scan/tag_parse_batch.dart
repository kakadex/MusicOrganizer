/// 批量标签解析（性能排查报告 §5.1 主方案的数据层，0.2.73）。
///
/// 纯函数、零 flutter 依赖：输入一批「扩展名 + 字节」，输出一批可序列化的
/// 结果（标签键值 + 封面字节）。调用方（lib/app/tag_parse_isolate.dart）
/// 用 `Isolate.run` 把它送进后台 isolate，UI 线程上不再有大块解析。
///
/// ## 为什么要批
///
/// `Isolate.run` 每次起一个 isolate 开销约 1~3ms，一首一个反而更慢；
/// 按批（20~50 首）摊薄这个成本才划算。
///
/// ## 为什么用 Map 而不是直接传 Tags / ScannerHead
///
/// isolate 之间只能传「可序列化」的东西；Tags 虽然理论上可传，但走 Map 更
/// 直白，也避免 Tags 内部结构变化时悄悄破坏 isolate 传输。
library;

import 'dart:typed_data';

import '../model/tags.dart';
import '../tag/cover_reader.dart';
import '../tag/tag_io.dart';

/// 一首的解析输入。
class ParseInput {
  ParseInput({required this.ext, required this.bytes});

  /// 扩展名（含点，如 `.mp3`）。
  final String ext;

  /// 已读出的文件字节（头部片段或整文件，由调用方决定）。
  final Uint8List bytes;
}

/// 一首的解析输出（全部可序列化）。
class ParseOutput {
  ParseOutput({
    required this.values,
    this.cover,
  });

  /// 标签键值（不含空值）。
  final Map<String, String> values;

  /// 内嵌封面字节；没有为 null。
  final Uint8List? cover;
}

/// 批量解析：输入 N 首，输出 N 首（顺序一一对应）。
///
/// 单首解析失败不影响整批：该首的 values 为空 map、cover 为 null，
/// 调用方按「空标签」处理——与 `Scanner.readHead` 的单首容错语义一致。
List<ParseOutput> parseTagBytesBatch(List<ParseInput> inputs) {
  final List<ParseOutput> out = <ParseOutput>[];
  for (final ParseInput input in inputs) {
    try {
      final Tags tags = TagIO.readLocal(input.bytes, input.ext);
      final Uint8List? cover = CoverReader.read(input.bytes, input.ext);
      out.add(ParseOutput(
        values: Map<String, String>.from(tags.values),
        cover: cover,
      ));
    } catch (_) {
      out.add(ParseOutput(values: <String, String>{}));
    }
  }
  return out;
}
