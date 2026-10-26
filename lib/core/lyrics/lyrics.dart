/// 歌词层：歌词文档模型 + 5 家歌词源解析。
///
/// - `lyric_doc.dart`：LRC / TTML / KRC 解密（16 字节密钥 + base64 + XOR
///   + zlib）/ 双语 / 偏移 / 时间轴；
/// - `lyrics_shift.dart`：整体偏移；
/// - `krc_cipher.dart`：酷狗 KRC 解密（fixture krc_real.b64 回归）。
library;
