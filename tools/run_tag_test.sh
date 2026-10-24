#!/usr/bin/env bash
# 标签读写回归测试（纯 JVM，不需要手机或模拟器）
#
# 覆盖：
#   1. ID3 全字段写入
#   2. 只改一个字段时其余字段必须保留（合并语义，防误清标签）
#   3. 歌词写入 USLT 帧后回读一致
#   4. 空字符串清除歌词
#   5. FLAC LYRICS 写入且其它 Vorbis 注释保留
#   6. MP4 标签写入 + **stco 采样偏移修正**（合成最小 MP4 验证）
#   7. WAV 标签读写（文件尾 ID3 块 / LIST-INFO 兼容 / chunk 对齐 / RIFF 长度）
#   8. OGG Vorbis / Opus 注释读写（页重建 / 音频包不变 / 拆页序号顺移 / 跨页拒绝）
#   9. 批量编辑规格（只写勾选字段 / 音轨递增 / 空规格）
#  10. APEv2 标签读写（文件尾 footer / 合并语义 / ID3v1 保留 / 封面 / 音频段不变）
#  11. WMA（ASF）只读标签（Content Description / Extended Content / 不可写提示）
#
# 用法：./tools/run_tag_test.sh
set -e
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$(cd "$PROJ/.." && pwd)"
CORE="$PROJ/app/src/main/java/com/dsh/musicorganizer/core"
OUT="$PKG/.workbuddy/tagtest"
JAVAC="$PKG/env/jdk17/bin/javac.exe"
JAVA="$PKG/env/jdk17/bin/java.exe"
[ -x "$JAVAC" ] || JAVAC="$PKG/env/jdk17/bin/javac"
[ -x "$JAVA" ] || JAVA="$PKG/env/jdk17/bin/java"
# 便携链不存在时退回 PATH（CI 或不带 env/ 的机器）
[ -x "$JAVAC" ] || JAVAC="$(command -v javac || true)"
[ -x "$JAVA" ] || JAVA="$(command -v java || true)"

rm -rf "$OUT"
mkdir -p "$OUT/classes"

"$JAVAC" -encoding UTF-8 -d "$OUT/classes" \
    "$CORE/Tags.java" "$CORE/TextUtil.java" "$CORE/TagText.java" "$CORE/Id3.java" "$CORE/Flac.java" "$CORE/Mp4.java" \
    "$CORE/Wav.java" "$CORE/Ogg.java" "$CORE/Ape.java" "$CORE/Wma.java" "$CORE/VFile.java" "$CORE/BatchEdit.java" \
    "$CORE/CoverArt.java" "$CORE/CoverReader.java" "$CORE/TagIO.java" \
    "$PROJ/tools/TagRoundTripTest.java" "$PROJ/tools/TagHeadTest.java" "$PROJ/tools/Mp4Test.java" \
    "$PROJ/tools/CoverReaderTest.java" "$PROJ/tools/WavTagTest.java" "$PROJ/tools/OggTagTest.java" "$PROJ/tools/BatchEditTest.java" "$PROJ/tools/ApeTagTest.java" "$PROJ/tools/WmaTagTest.java"

"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" TagRoundTripTest "$OUT/fixtures"
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" TagHeadTest "$OUT/headfixtures"
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" Mp4Test "$OUT/mp4fixtures"
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" CoverReaderTest "$OUT/coverfixtures"
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" WavTagTest "$OUT/wavfixtures"
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" OggTagTest "$OUT/oggfixtures"
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" BatchEditTest
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" ApeTagTest "$OUT/apefixtures"
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" WmaTagTest "$OUT/wmafixtures"
