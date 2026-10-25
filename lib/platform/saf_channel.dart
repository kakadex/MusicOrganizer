import 'package:flutter/services.dart';

/// SAF MethodChannel 名（与 android 侧 `SafPlugin.kt` 的注册名保持一致）。
///
/// 契约表见架构设计 §2.2：pickTree / listRoots / stat / listChildren /
/// copyDocToCache / writeCacheToDoc / readHead / readTail / createDocument /
/// createDir / deleteDocument / renameDocument / moveDocument。
const String kSafChannelName = 'com.dsh.musicorganizer/saf';

/// 全局 SAF 通道（T03 起填充方法调用；此处先固定通道名，防两端写漂移）。
final MethodChannel safChannel = MethodChannel(kSafChannelName);
