MusicOrganizer v0.2.15 分发包（本地直发，非官方发布页）
====================================================

构建时间：2026-10-28
版本：0.2.15（build 129，版本戳 0.2.15-omdyba）
说明：本目录用于直接发给他人使用，官方发布以 Gitee / GitHub Releases 为准。

文件
----
musicorganizer-windows-x64.zip    Windows 桌面版（解压后运行 musicorganizer.exe）
musicorganizer-arm64-v8a.apk      安卓 64 位（绝大多数现代手机）
musicorganizer-x86_64.apk         安卓 x86_64（少数 Intel 平板 / 模拟器）
musicorganizer-armeabi-v7a.apk    安卓 32 位（老旧设备）
SHA256SUMS.txt                    以上文件的 SHA-256 校验和

安装 / 使用
----------
Windows：解压 zip，双击 musicorganizer.exe。首次运行若被 SmartScreen 拦，
  点「更多信息 → 仍要运行」即可（安装包未向微软付费签名，属正常提示）。

Android：允许「未知来源」后安装对应 ABI 的 APK。
  - 不确定机型就装 arm64-v8a（主流）；很老的 32 位机装 armeabi-v7a；
    x86_64 仅用于 Intel 芯片平板或安卓模拟器。
  - 本包为 release 构建，使用与官方发布一致的正式签名，可直接覆盖升级。

校验（可选）
----------
sha256sum -c SHA256SUMS.txt

升级说明
--------
自 v0.2.3 起统一使用同一把正式签名，之后所有版本都能直接覆盖安装，
不再需要先卸载旧版。若从 v0.2.2 及更早版本（debug 签名）升级，需先卸载一次。
