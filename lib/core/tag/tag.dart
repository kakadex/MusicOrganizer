/// 标签编解码层（T06 落位）：8 格式自研编解码 + 统一读写入口。
///
/// - `tag_io.dart`：按格式分发（id3 / flac / mp4 / wav / ogg / ape / dsf / wma）；
/// - `id3.dart` / `flac_tag.dart` / `mp4_tag.dart` / `wav_tag.dart` /
///   `ogg_tag.dart` / `ape_tag.dart` / `dsf_tag.dart` / `wma_tag.dart`；
/// - `tag_fits_copy.dart`：尾区空间判定（写盘前容量检查）。
library;
