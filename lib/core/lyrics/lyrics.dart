/// 歌词层：歌词文档模型 + 歌词处理工具 + 5 家歌词源解析。
///
/// - `model/lyrics_doc.dart`：LRC / TTML / KRC 解密（16 字节密钥 + base64 + XOR
///   + zlib）/ 双语 / 时间轴；
/// - `lyrics_tool.dart`：清洗（删空行 / 去元信息 / 去时间轴 / 规范时间轴 / 去重复行）；
/// - `lyrics_shift.dart`：时间轴整体偏移；
/// - `krc.dart`：酷狗 KRC 解密。
library;

export 'lyrics_shift.dart';
export 'lyrics_tool.dart';
