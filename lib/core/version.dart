/// 应用版本（**生成文件，勿手改**）。
///
/// 由 `tools/stamp-version.dart` 依据 VERSION（唯一真源）+ lib/ 源码内容
/// 哈希生成；内容哈希后缀（6 位）随源码变化。pubspec 的 version 行只放
/// `X.Y.Z+NNN`（build 号 = versionCode，须为整数）—— 见架构设计 §6 / R6。
library;

/// 完整版本串：`X.Y.Z-abc123`（UI 顶栏 / 设置页展示）。
const String kAppVersionFull = '0.2.2-ihdbst';

/// 语义版本（与 VERSION 文件一致）。
const String kAppVersion = '0.2.2';

/// 构建号（= versionCode = pubspec build 号）。
const int kAppBuild = 114;
