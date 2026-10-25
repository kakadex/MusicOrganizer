# MusicOrganizer（Flutter 重构版）

本地音乐标签 / 歌词整理工具，Flutter 重构版（greenfield，双端：Android + Windows）。

## 功能

- **曲库**：递归扫描 + 增量（文件没变就沿用上次读到的标签）、筛选、排序、搜索（支持 `artist:` / `size:>` 这类条件）
- **批量标签**：多源并发匹配 → 打分去重 → 逐字段「旧值 → 新值」预览 → 事务写盘 → 可按批次撤销
- **批量歌词 / 封面**：先给候选与来源，确认后写入
- **整理**：按「歌手 / 专辑」出移动计划（同名跳过），文件名查重，垃圾文件识别，标签文本清理
- **单文件编辑器**：七字段 + 封面（选图 / 移除 / 导出）+ 编码修正
- **体检与 CSV**：缺项统计、曲库清单导出

## 设计约束

- **双端一致**：`core/` 是纯 Dart 域层，不依赖 Flutter，双端共用同一套扫描 / 编解码 / 事务 / 匹配逻辑
- **写盘安全**：任何标签写入都走「副本 → 校验 → 备份 → 写回 → 回读 → 日志」，失败自动恢复
- **先预览后写盘**：联网结果必须经用户确认才落盘
- **可离线回归**：`core/` 与 UI 解耦，341 项单元测试全绿，`flutter analyze` 零告警

## 平台

- Android 7.0（API 24）及以上；用系统文件选择器授权目录，只在你授权范围内读写
- Windows 10 及以上；直接读写所选文件夹

## 工程约定

- **依赖白名单**：`path_provider` / `file_selector` / `shared_preferences` /
  `url_launcher`；网络一律 `dart:io HttpClient`，不引 http 包。新增依赖须经架构评审。
- **版本链**：`VERSION` 为唯一真源；`dart run tools/stamp-version.dart`
  依据源码内容哈希生成 `lib/core/version.dart`（`kAppVersionFull = 'X.Y.Z-abc123'`）。
- **结构纪律**：feature-first UI + 强纯 Dart core 域层；单文件软上限 400 行。
- **红线**：代码注释 / 文件 / 提交信息不得出现本机路径、身份与凭据。

## 常用命令

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --split-per-abi --release
flutter build windows --release
```
