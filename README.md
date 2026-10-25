# 音乐整理 MusicOrganizer

[![CI](https://github.com/kakadex/MusicOrganizer/actions/workflows/ci.yml/badge.svg)](https://github.com/kakadex/MusicOrganizer/actions/workflows/ci.yml)

整理手机里散乱的本地音乐：批量补标签、配歌词、查重、按「艺人 / 专辑」归位。

纯 Java + Android 框架 API 实现，**零第三方依赖**（无 AndroidX、无 Material、无 OkHttp）。
ID3 / FLAC 读写、多源元数据聚合、HTTP 客户端、界面控件全部手写。

---

## 下载安装

**国内推荐走 Gitee**（不用代理，直接下就行）：

- **Gitee 直连（国内推荐）**：[musicorganizer-latest.apk](https://gitee.com/kakadex/MusicOrganizer/raw/main/dist/musicorganizer-latest.apk) —— 永远是最新一版
- **Gitee 仓库**：[gitee.com/kakadex/MusicOrganizer](https://gitee.com/kakadex/MusicOrganizer)（源码镜像 + 版本清单 `dist/latest.txt`）

GitHub（备用）：

- **Releases**：[下载最新版本](https://github.com/kakadex/MusicOrganizer/releases/latest) — 带完整更新说明，附件名形如 `MusicOrganizer-v0.1.x.apk`
- **分支直下**：[dist/musicorganizer-latest.apk](dist/musicorganizer-latest.apk)（`main` 分支，点开 → Download raw file）

要求 Android 7.0（API 24）及以上；`0.1.x` 各版可直接覆盖安装。

**Windows 桌面版**（Win10/11 64 位，免安装单文件 exe，无需 Python）：

- **Gitee Releases**：[gitee.com/kakadex/MusicOrganizer/releases](https://gitee.com/kakadex/MusicOrganizer/releases) —— 附件名形如 `MusicOrganizer-desktop-v0.1.x.exe`
- **GitHub Releases**：[github.com/kakadex/MusicOrganizer/releases](https://github.com/kakadex/MusicOrganizer/releases) —— 同一个 Release 里同时挂 APK 与桌面版 exe

> 桌面版与安卓版共用同一个版本号（例如 `0.1.89-236781`），功能与标签逻辑保持同步。

> App 内的「检查更新」也是**国内优先**：先读 Gitee 上的 `dist/latest.txt`，
> 连不上再退到 GitHub（清单 → Release API），下载同样优先给 Gitee 的直链。

---

## 功能

### ① 扫描整理

选中目录（系统文件选择器，无需存储权限），按「艺人 / 专辑 / 曲目 - 标题」重建目录。
歌名歌手优先读标签，缺失时从文件名反解，两者权重可调。识别不出的进「未识别/」。

### ② 文件名清理

去掉广告前缀、重复序号、重编码标记、多余空格。先列出改名计划，确认后才动手。

同一张卡片里还有**文件名查重**：递归扫描整个目录，把文件名归一后相同或相似度 ≥ 90% 的文件分组，
每组标出「建议保留」，其余逐条勾选后删除。

### ③ 文件浏览与搜索（工作台）

列表每行三行信息：**标题（标签优先）/ 艺人 · 专辑 / 路径 · 大小**，右侧徽标标出`无封面`、`无歌词`、`待补`。
标签按需后台读取 —— 只读滚到可见的那些行，进页面不会为整个库扫盘。

- **排序**：文件名 / 大小 / 修改时间 / 标签完整度 / 路径，可升降序
- **筛选**：全部 / 无标签 / 无封面 / 无歌词
- **多选批量**（长按进入）：改标签 / 取歌词 / 补封面 / 按标签重命名 / 删除
- **搜索**：空格分词（全部命中），支持 `artist:周杰伦`、`album:叶惠美`、`ext:flac`、`size:>10m`、
  `歌词:下雨` 这类字段写法与中文别名，命中处高亮；自由词会同时搜文件名、路径、标签与歌词

### ④ 单文件标签编辑

分区折叠：**封面 / 基本信息 / 歌词 / 在线匹配**。

- 改过的字段右侧亮「● 已改」，点它单项回滚；底部按钮实时显示「保存（N 项）」
- 封面可「在线取」/「从文件选」/「移除」（封面替换不可整批撤销，界面上有提示）
- 歌词可编辑、可在线取、可清除
- 在线候选是卡片：只填勾选中的字段，不再整条覆盖
- 保存前仍列出「旧值 → 新值」清单，字段与封面走同一条事务

### ⑤ 批量在线标签

多源聚合逐首匹配 → 预览（逐字段「旧值 → 新值」）→ 勾选确认后才写盘。
默认只补空缺字段，可勾选强制覆盖；也能逐字段设「不写 / 只补空 / 覆盖」。
数据源 8 个：MusicBrainz / Deezer / iTunes / 网易云 / QQ 音乐 / 酷狗 / 酷我 / 咪咕。

同一张卡片里还能**批量补专辑封面**（Deezer / iTunes / 网易 / QQ 的专辑图），先预览再下载写入。

**增量模式**：记住每首歌上次的查询结果 —— 库里没有的、被校验拦下的、已写好的，下一批直接跳过；
文件被替换会自动重查。

### ⑥ 批量歌词

四源并发兜底（LRCLIB / 网易云 / QQ 音乐 / lyrics.ovh），统一打分择优，写同名 `.lrc` 或嵌入标签。
候选要过标题、艺人、时长三道校验，避免配错。
网易 `tlyric` / QQ `trans` 的译文会**按毫秒对齐合成双语 LRC**（原文一行 + 译文一行），
并自动清掉「作词：xxx」这类制作信息行。

港台源常常只给繁体，默认会**转成简体**再写入（内置 1200+ 字对照表，零依赖）：
只动汉字，时间轴、译文轨、标点原样保留；**日文歌词（含假名）自动跳过**，不会被误转。
可在「批量歌词」卡片里关闭。

### ⑦ 安全网

写盘走事务层（副本 → 校验 → 备份 → 替换），批量写入可整批撤销。
设置可**导出 / 导入**（权重、字段策略、数据源地址、各开关存成一份 JSON），换机或重装一键还原。

### ⑧ 关于与更新

点顶栏的版本号（或「整理 → ⑥ 关于与更新 → 检查更新」）即可查 GitHub 上的最新 Release：
显示当前 / 最新版本对比、更新说明摘要，一键用浏览器下载 APK（安装由系统确认）。
启动时也会静默查一次（**每天最多一次**，可在卡片里关掉）；查到新版本时顶栏会挂红字提示。

GitHub 在境内有时连不上 —— 这一项也走「数据源设置」，可以换成镜像地址，或直接停用。
检查只读 Release 信息，不上传任何本地数据，也不改动任何文件。

### 其他

- 查重的归一规则认得 `(1)` / `- 副本` / `copy` / `_2` 这类复制痕迹，也做繁简与标点归一；
  **短名（4 字以内）一字之差不算重复**，避免「晴天 / 雨天」被误删
- 长任务可暂停 / 停止 / 后台运行；暂停时可预览已获取部分
- 接口地址不写死，可在「数据源设置」里改地址、单独停用某个源
- 运行日志分级落盘（保留 7 天，含崩溃堆栈），可一键导出 txt 反馈问题

---

## 支持格式

| 格式 | 读标签 | 写标签 | 备注 |
|---|:---:|:---:|---|
| MP3 | ✅ | ✅ | ID3v2.2 / v2.3 / v2.4 |
| FLAC | ✅ | ✅ | Vorbis Comment |
| M4A / MP4 | ✅ | ✅ | 含封面 `covr`；写入时修正采样偏移 |
| WAV / OGG / OPUS | 系统元数据 | ❌ | 可参与整理与文件名清理 |

可写字段：标题、艺人、专辑、年份、音轨号、流派、注释、歌词、封面。

---

## 从源码构建

需要 JDK 17 + Android SDK（`platform-34`、`build-tools 34.0.0`）。

```bash
./build.sh debug   # Debug 包，调试证书签名
./build.sh         # Release 包（先 cp signing.properties.example signing.properties 并填证书）
```

---

## 说明

- 元数据来自各平台**公开接口**，只传歌名 / 艺人 / 时长，**不上传音频、不含下载功能**；内容版权归各权利人。
- 整理和改名会移动文件，第一次建议先拿小文件夹试。
- 已知限制：封面写入不进撤销链路（文本字段可以整批撤销）；界面仅中文。

## 许可

[MIT](LICENSE)
