#!/usr/bin/env bash
# 核心逻辑回归测试（纯 JVM，不需要手机 / 模拟器）
#
# 覆盖：
#   1. 文件名权重决策（0% / 50% / 100% 与备选值）
#   2. 百分比换算与越界收缩
#   3. TaskControl 进度上报（百分比、总量未知）
#   4. TaskControl 取消 / 暂停 / 暂停中取消
#   5. Net 并发编排（保序 / 并发度 / 取消 / 预算 / 容错）
#   6. PartialSink 已获取结果缓冲区（暂停预览用，并发安全）
#   7. 接口地址注册表（默认值 / 用户覆盖 / 启用开关 / 地址校验）
#   8. 艺人判定与目录归一（占位歌手标签 / 同义写法合并）
#   9. 歌词格式（增强型 LRC 逐字 / TTML 转 LRC / 时间格式）
#  10. 写入历史批次视图（折叠 / 倒序 / 已撤销扣减 / 上限）
#  11. 文件名模板（占位符 / 补零 / 非法字符 / 扩展名 / 截断）
#  12. 整理目录结构（艺人 / 艺人-专辑 / 平铺、专辑为空回退）
#  13. 曲库体检（五项维度累加 / 完整度 / 清单上限 / 尺寸格式化）
#  14. 歌词时间轴偏移（元信息保留 / 钳零 / 小数位 / 逐字 / 多时间戳）
#  15. 曲库清单 CSV（BOM / CRLF / 转义 / 行数）
#  16. 默认设置表与差异计算（恢复默认用）
#  17. 歌词时间轴判定（行定位 / 逐字进度 / 排序）
#  18. 垃圾文件识别（0 字节 / .lrc.bak / 临时 / 系统垃圾）
#  19. 整理移动日志（TSV 往返 / 批次折叠 / 逆序）
#  20. 酷狗 KRC（真实线上样本 / base64 / XOR+zlib / 逐字转增强型 LRC）
#  21. 媒体库条目（显示 / 筛选 / 排序 / 导入文件名）
#  22. 数据源优先级（国内优先 / 同分排序 / 容差）
#  26. 重复文件分组（同大小 + 同哈希 / 建议保留 / 浪费排序）
#  25. 缓存回填（标签/封面/歌词/时长/码率必须整体还原）
#  25. 缓存回填（标签/封面/歌词/时长/码率必须整体还原）
#  24. 曲目技术信息格式化（时长四舍五入 / 跨小时 / 未知返回空）
#  24. 曲目技术信息格式化（时长四舍五入 / 跨小时 / 未知返回空）
#  23. 标签文本解码容错（GBK 冒充 UTF-8 / 双重编码 / NUL / 不误伤正常 UTF-8）
#  24. 增量扫描（未变文件接力标签 / 大小或时间变了必须重读 / 新增移除）
#
# 用法：./tools/run_core_test.sh
set -e
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$(cd "$PROJ/.." && pwd)"
CORE="$PROJ/app/src/main/java/com/dsh/musicorganizer/core"
OUT="$PKG/.workbuddy/coretest"
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
    "$CORE/CancelToken.java" "$CORE/TextUtil.java" \
    "$CORE/NameWeight.java" "$CORE/TaskControl.java" \
    "$CORE/Tags.java" "$CORE/TrackInfo.java" "$CORE/TagFill.java" "$CORE/PartialSink.java" \
    "$CORE/SettingsBackup.java" "$CORE/AppLog.java" \
    "$CORE/Json.java" "$CORE/BatchMemory.java" "$CORE/MatchQueue.java" "$CORE/BatchSkip.java" "$CORE/LyricsDoc.java" "$CORE/Ttml.java" "$CORE/CoverArt.java" \
    "$CORE/VFile.java" "$CORE/Duplicates.java" "$CORE/Progress.java" \
    "$CORE/SearchQuery.java" "$CORE/SearchIndex.java" "$CORE/TrackRestore.java" "$CORE/DupFiles.java" \
    "$CORE/ScanStats.java" "$CORE/TrackGroup.java" "$CORE/ScanSnapshot.java" "$CORE/Zh.java" \
    "$CORE/ScanMerge.java" \
    "$CORE/AppUpdate.java" "$CORE/JournalHistory.java" \
    "$CORE/Theme.java" "$CORE/NameParser.java" "$CORE/ArtistRules.java" "$CORE/NameTemplate.java" \
    "$CORE/Layout.java" "$CORE/HealthCheck.java" "$CORE/LyricsShift.java" "$CORE/CsvExport.java" \
    "$CORE/LyricsTimeline.java" "$CORE/Junk.java" "$CORE/MoveLog.java" "$CORE/Krc.java" \
    "$CORE/MediaTrack.java" "$CORE/SourceRank.java" "$CORE/TagText.java" "$CORE/Id3.java" "$CORE/Bitrate.java" \
    "$CORE/LyricsTool.java" "$CORE/TagFix.java" "$CORE/MatchDedupe.java" \
    "$PROJ/app/src/main/java/com/dsh/musicorganizer/net/Net.java" \
    "$PROJ/app/src/main/java/com/dsh/musicorganizer/net/Endpoints.java" \
    "$PROJ/tools/NameWeightTest.java" "$PROJ/tools/TagFillTest.java" \
    "$PROJ/tools/NetTest.java" "$PROJ/tools/PartialSinkTest.java" \
    "$PROJ/tools/EndpointsTest.java" "$PROJ/tools/TextUtilTest.java" \
    "$PROJ/tools/SettingsBackupTest.java" "$PROJ/tools/AppLogTest.java" \
    "$PROJ/tools/BatchMemoryTest.java" "$PROJ/tools/LyricsDocTest.java" \
    "$PROJ/tools/CoverArtTest.java" "$PROJ/tools/DuplicatesTest.java" \
    "$PROJ/tools/SearchIndexTest.java" "$PROJ/tools/ScanSnapshotTest.java" "$PROJ/tools/ZhTest.java" \
    "$PROJ/tools/AppUpdateTest.java" \
    "$PROJ/tools/ThemeTest.java" "$PROJ/tools/ArtistRulesTest.java" \
    "$PROJ/tools/JournalHistoryTest.java" "$PROJ/tools/NameTemplateTest.java" "$PROJ/tools/LayoutTest.java" \
    "$PROJ/tools/HealthCheckTest.java" "$PROJ/tools/LyricsShiftTest.java" "$PROJ/tools/CsvExportTest.java" \
    "$PROJ/tools/SettingsDefaultsTest.java" "$PROJ/tools/LyricsTimelineTest.java" "$PROJ/tools/JunkTest.java" \
    "$PROJ/tools/MoveLogTest.java" "$PROJ/tools/KrcTest.java" "$PROJ/tools/MediaTrackTest.java" \
    "$PROJ/tools/SourceRankTest.java" "$PROJ/tools/TagTextTest.java" "$PROJ/tools/TrackInfoTest.java" "$PROJ/tools/TrackRestoreTest.java" "$PROJ/tools/DupFilesTest.java" \
    "$PROJ/tools/ScanMergeTest.java" \
    "$PROJ/tools/LyricsFormatTest.java" "$PROJ/tools/BitrateTest.java" \
    "$PROJ/tools/LyricsToolTest.java" "$PROJ/tools/TagFixTest.java" "$PROJ/tools/MatchDedupeTest.java" \
    "$PROJ/tools/MatchQueueTest.java"

"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" NameWeightTest
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" TagFillTest
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" NetTest
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" PartialSinkTest
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" EndpointsTest
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" TextUtilTest
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" SettingsBackupTest
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" AppLogTest
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" BatchMemoryTest
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" LyricsDocTest
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" CoverArtTest
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" DuplicatesTest
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" SearchIndexTest
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" ScanSnapshotTest "$OUT/snapfixtures"
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" ZhTest
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" AppUpdateTest
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" ThemeTest
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" ArtistRulesTest
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" JournalHistoryTest
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" NameTemplateTest
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" LayoutTest
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" HealthCheckTest
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" LyricsShiftTest
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" CsvExportTest
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" SettingsDefaultsTest
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" LyricsTimelineTest
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" JunkTest
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" MoveLogTest
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" KrcTest "$PROJ/tools/fixtures"
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" MediaTrackTest
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" SourceRankTest
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" TagTextTest
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" TrackInfoTest
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" TrackRestoreTest
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" DupFilesTest
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" ScanMergeTest
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" LyricsFormatTest
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" BitrateTest
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" LyricsToolTest
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" TagFixTest
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" MatchDedupeTest
"$JAVA" -Dfile.encoding=UTF-8 -cp "$OUT/classes" MatchQueueTest
