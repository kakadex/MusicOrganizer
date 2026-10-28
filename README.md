# MusicOrganizer

本地音乐标签 / 歌词整理工具，双端：Android + Windows。

## 下载安装

**国内推荐走 Gitee**（不用代理，直接下就行）：

- **Gitee Releases**：[gitee.com/kakadex/MusicOrganizer/releases](https://gitee.com/kakadex/MusicOrganizer/releases) —— 同一个 Release 里同时挂三个 ABI 的 APK 与 Windows 桌面版 zip
- **Gitee 仓库**：[gitee.com/kakadex/MusicOrganizer](https://gitee.com/kakadex/MusicOrganizer)（源码镜像 + 版本清单 `dist/latest.txt`）

GitHub（备用）：

- **Releases**：[下载最新版本](https://github.com/kakadex/MusicOrganizer/releases/latest) —— 带完整更新说明

安卓按机型选一个装：主流手机装 `arm64-v8a`，很老的 32 位机装 `armeabi-v7a`，Intel 平板或模拟器装 `x86_64`。
Windows 解压 zip 后运行 `musicorganizer.exe`（免安装）。

> App 内的「检查更新」也是**国内优先**：先读 Gitee 上的 `dist/latest.txt`，连不上再退到 GitHub，
> 下载同样优先给 Gitee 的直链。

## 功能

- **曲库**：递归扫描（文件没变就不重读标签）、筛选、排序、搜索（命中处高亮，下拉可刷新）；搜索支持 `artist:xxx`、`size:>10m` 这类条件
- **批量标签**：多源查询后给出候选，逐字段显示「旧值 → 新值」，确认后才写入；写入后可按批次撤销；一批里中途失败可以整批退回
- **批量歌词 / 封面**：先列出候选与来源（歌词可逐首换成别的一条），确认后写入；歌词可整批转简体、合成双语；跑到一半被打断也能接着上次继续
- **歌词工具**：清洗歌词、时间轴整体偏移、查看原词
- **整理**：按模板（歌手 / 专辑、年代 / 歌手等）生成移动计划（目标已存在同名文件则跳过），重复文件筛选（比对文件内容区分「同一份」与「只是名字像」），垃圾文件识别，清理空文件夹，标签文本清理，文件名清理与按模板改名
- **单文件编辑**：标题 / 艺术家 / 专辑艺术家 / 专辑 / 年份 / 音轨 / 流派 / 注释 + 歌词 + 封面（选择 / 在线取 / 移除 / 导出）+ 在线匹配候选 + 单项回滚 + 乱码编码修正
- **批量维护**：批量改标签、按标签改名、删除全部标签和歌词
- **体检与 CSV**：统计缺项，导出曲库清单（含目录、大小、时长、码率）
- **运行日志与崩溃提示**：设置里可查看与导出日志；出错时给出可复制的错误信息
- **检查更新**：国内优先；桌面端可直接「下载并更新」（自动解压替换并重启）

## 使用提示

- 所有写入都先预览，确认后才动文件；写错了可在「撤销历史」里整批回退
- 网络默认直连；也可以选「自动」（跟随系统环境变量里的代理）或手填代理地址，设置页提供「测试连通」
- 曲库目录授权一次即可，下次启动自动恢复；授权失效会提示重新选择
- 联网只用于查标签 / 歌词 / 封面与检查更新，不收集任何个人信息，详见 [PRIVACY.md](PRIVACY.md)

## 平台

- **Android 7.0（API 24）及以上**：用系统文件选择器授权目录，只在授权的范围内读写
- **Windows 10 及以上**：直接读写所选文件夹，支持把文件夹拖进窗口切换曲库；可选关联音频文件（双击进编辑器）

## 构建

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --split-per-abi --release
flutter build windows --release
```
