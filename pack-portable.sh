#!/usr/bin/env bash
# 音乐整理工具（安卓版）· 打包便携包：干净 git 副本 + 交接文档 + 证书 + 最新 APK
#
# 用法：./pack-portable.sh
#
# 产物（放在工作区根目录，两种格式内容相同）：
#   音乐整理工具-便携包-<日期>.7z   （推荐，需 7-Zip）
#   音乐整理工具-便携包-<日期>.zip  （备用，双击即可解压）
#
# 包里有什么：
#   - 完整源码 + .git 历史（main 分支）
#   - HANDOFF.md / START-HERE.md 交接文档
#   - release/v<最新版本>/ 已签名 APK + 版本信息 + Release 说明
#   - signing/release.keystore + signing.properties（storeFile 留空，命中项目内证书）
#   - 换机继续-先读我.md
#
# 不带：env/、gradle-home/、app/build/、历史版本 APK、BUG.jpeg、旧 7z、local.properties
#       （都可重建；私钥不打进包，见换机指南）
set -e

PKG="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$PKG/.." && pwd)"

# --- 0. 前置检查 ---
if [ -n "$(git -C "$PKG" status --porcelain)" ]; then
    echo "[错误] 工作区有未提交改动，先提交再打包：" >&2
    git -C "$PKG" status --short >&2
    exit 1
fi

VER_NAME="$(grep -oE 'versionName[[:space:]]+"[^"]+"' "$PKG/app/build.gradle" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
[ -n "$VER_NAME" ] || { echo "[错误] 读不到 versionName" >&2; exit 1; }

STAMP="$(date '+%Y%m%d')"
OUT7Z="$ROOT/音乐整理工具-便携包-$STAMP.7z"
OUTZIP="$ROOT/音乐整理工具-便携包-$STAMP.zip"
TMP="$ROOT/.pack-portable"

# 定位 7-Zip
SZ7Z=""
for c in "C:/Program Files/7-Zip/7z.exe" "C:/Program Files (x86)/7-Zip/7z.exe"; do
    [ -f "$c" ] && { SZ7Z="$c"; break; }
done
[ -z "$SZ7Z" ] && SZ7Z="$(command -v 7z 2>/dev/null || command -v 7za 2>/dev/null || echo '')"
[ -z "$SZ7Z" ] && { echo "[错误] 找不到 7-Zip，请先安装或加入 PATH" >&2; exit 1; }

# 从本地 signing.properties 读口令（不在脚本里写死任何口令）
prop() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$PKG/signing.properties" | head -1 | tr -d '\r'; }
SP="$(prop storePassword)"
KA="$(prop keyAlias)"
KP="$(prop keyPassword)"
[ -n "$KA" ] || KA="musicorganizer"
[ -n "$SP" ] || { echo "[错误] 读不到 signing.properties 的 storePassword" >&2; exit 1; }
[ -n "$KP" ] || KP="$SP"

# --- 1. 干净副本 ---
echo "== 克隆干净副本 =="
rm -rf "$TMP"
mkdir -p "$TMP"
git -C "$PKG" clone --local --quiet "$PKG" "$TMP/MusicOrganizer"
cd "$TMP/MusicOrganizer"
git checkout -q main

# --- 2. 交接文档 ---
cp -f "$PKG/HANDOFF.md" .
[ -f "$PKG/START-HERE.md" ] && cp -f "$PKG/START-HERE.md" .

# --- 3. 最新版 APK ---
if [ -d "$PKG/release/v$VER_NAME" ]; then
    mkdir -p release
    cp -r "$PKG/release/v$VER_NAME" release/
fi

# --- 4. 签名材料（证书 + 便携版 signing.properties，storeFile 留空） ---
mkdir -p signing
cp -f "$ROOT/signing/release.keystore" signing/
{
    echo "# 便携包签名配置 —— 证书在 signing/release.keystore"
    echo "# storeFile 故意留空，build.sh 会自动命中 \$PKG/signing/release.keystore"
    echo "storePassword=$SP"
    echo "keyAlias=$KA"
    echo "keyPassword=$KP"
} > signing.properties

# --- 5. 换机指南 ---
cat > "换机继续-先读我.md" <<EOF
# 换机继续 · 音乐整理工具（安卓版）

本包 = 完整源码 + git 历史 + 交接文档 + 已签名 APK（v$VER_NAME）+ 签名证书。

## 1. 解压后先跑一次，刷新入口页

\`\`\`bash
cd <解压目录>/MusicOrganizer
./checkpoint.sh
\`\`\`

它会用**当前机器的真实路径**重新生成 \`START-HERE.md\`（包里的那份还是旧机器的路径）。
之后开新窗口按 START-HERE.md 里的指引继续即可。

## 2. 构建环境（二选一）

包里**不含** JDK/SDK/Gradle 缓存，需要在新机器准备：

- **能联网**：装 JDK 17 + Android SDK（\`platforms;android-34\`、\`build-tools;34.0.0\`），
  设好 \`JAVA_HOME\` / \`ANDROID_HOME\`，\`build.sh\` 会自动用系统环境 + 项目自带的 gradlew。
- **不能联网**：从旧机器拷贝 \`env/\` 下这 5 个目录（合计约 717 MB）到新机器，
  保持 \`env/\` 与 \`MusicOrganizer/\` 同级：
  \`jdk17\`、\`gradle-8.9\`、\`Sdk/platforms/android-34\`、\`Sdk/build-tools/34.0.0\`、\`Sdk/platform-tools\`

## 3. 构建 / 发版

\`\`\`bash
./build.sh          # 构建 + 签名（证书已在 signing/release.keystore，口令在 signing.properties）
./publish.sh        # 构建 + 推送 GitHub（需先配好 SSH，见下）
./tools/run_core_test.sh && ./tools/run_tag_test.sh   # 离线回归
\`\`\`

## 4. GitHub 推送（新机器需重新配 SSH）

本机到 github.com 的 HTTPS 不通，只能走 \`ssh.github.com:443\`。生成新密钥并加入
GitHub 账号后，在 \`~/.ssh/config\` 加：

\`\`\`
Host github.com
    HostName ssh.github.com
    Port 443
    User git
    IdentityFile ~/.ssh/id_ed25519_musicorganizer
\`\`\`

## 5. 安全提醒

- \`signing/release.keystore\` 是签名私钥，\`signing.properties\` 含口令，**勿外传本包**。
- 本包**没有** SSH 私钥；如需推送 GitHub，自己在目标机器重新生成（见上）。
EOF

# --- 6. 压缩 ---
echo "== 压缩（7z + zip）=="
cd "$TMP"
"$SZ7Z" a -t7z -mx=9 -bso0 -bsp0 "$OUT7Z" MusicOrganizer
"$SZ7Z" a -tzip -mx=9 -bso0 -bsp0 "$OUTZIP" MusicOrganizer

# --- 7. 清理 ---
cd "$ROOT"
rm -rf "$TMP"

echo
echo "完成："
ls -lh "$OUT7Z" "$OUTZIP" | awk '{print "  " $5 "  " $9}'
echo "  解压后内容：源码 + .git + HANDOFF/START-HERE + release/v$VER_NAME/ + signing/"
