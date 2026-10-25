# MusicOrganizer（Flutter 重构版）

本地音乐标签 / 歌词整理工具，Flutter 重构版（greenfield，双端：Android + Windows）。

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
