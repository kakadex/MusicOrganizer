#!/usr/bin/env bash
# 音乐整理工具（安卓版）· 一键发布：构建 APK → 同步 GitHub（发布素材分支 + tag + main）
#
# 用法：
#   ./publish.sh              # 构建 + 推送（最常用）
#   ./publish.sh --no-build   # 复用 release/v<版本>/ 里已有的 APK，只做推送
#   ./publish.sh --no-tag     # 推送素材分支与 main，不打 tag（因而不触发 Actions 建 Release）
#
# 做的事：
#   1. ./build.sh 构建并签名，产物归档到 release/v<版本>/
#   2. 同步 dist/ 目录（main 分支直接下载的安装包），并提交
#   3. 用孤儿分支 release-assets 覆盖式更新发布素材（APK / notes.md / 版本信息.txt）
#      —— 这是 Actions 自动建 Release 的数据源，也是下载兜底入口
#   4. 打 annotated tag v<版本> 并推送（触发 .github/workflows/release-apk.yml）
#   5. 推送 main
#
# 前提：当前工作区干净（未提交的源码改动不会被顺手推上去，先自行提交）。
# 注意：tag 同名时会被删掉重建，从而重新触发一次 Actions。
set -e

PKG="$(cd "$(dirname "$0")" && pwd)"
DO_BUILD=1
DO_TAG=1
for arg in "$@"; do
    case "$arg" in
        --no-build) DO_BUILD=0 ;;
        --no-tag)   DO_TAG=0 ;;
        -h|--help)  sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "[错误] 未知参数：$arg（可用 --no-build / --no-tag）" >&2; exit 1 ;;
    esac
done

VER_NAME="$(grep -oE 'versionName[[:space:]]+"[^"]+"' "$PKG/app/build.gradle" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
VER_CODE="$(grep -oE 'versionCode[[:space:]]+[0-9]+' "$PKG/app/build.gradle" | head -1 | grep -oE '[0-9]+')"
[ -n "$VER_NAME" ] || { echo "[错误] 读不到 versionName" >&2; exit 1; }
TAG="v$VER_NAME"
VER_DIR="$PKG/release/$TAG"
APK="$VER_DIR/音乐整理工具-$TAG.apk"

# --- 同基版本检查（v0.1.87 起）---
# 后缀是内容哈希，同一数字版本在源码变化后会得到不同后缀 —— 少了这道检查，
# 「忘了升数字版号」也能发出去，线上就会同时存在两个 0.1.87。
# 同一份源码重发（后缀相同）不算冲突；确实要覆盖时用 MO_ALLOW_SAME_BASE=1。
BASE_VER="${VER_NAME%%-*}"
SAME_BASE="$(git tag -l "v${BASE_VER}-*" | grep -v "^${TAG}$" || true)"
if [ -n "$SAME_BASE" ] && [ "${MO_ALLOW_SAME_BASE:-0}" != "1" ]; then
    echo "[错误] 已存在同一数字版本的其他 tag，请先把 ${BASE_VER} 升一位：" >&2
    echo "$SAME_BASE" | sed 's/^/        /' >&2
    echo "        （如确需同基版本再发，设 MO_ALLOW_SAME_BASE=1）" >&2
    exit 1
fi

cd "$PKG"

# --- 0. 收尾存档：刷新 START-HERE.md（本地文件，已被 .gitignore 忽略）---
if [ -x ./checkpoint.sh ]; then
    ./checkpoint.sh --quiet
fi

# --- 0.1 前置检查 ---
if [ -n "$(git status --porcelain)" ]; then
    echo "[错误] 工作区有未提交的改动，先提交再发布：" >&2
    git status --short >&2
    exit 1
fi
if [ -n "$(git log origin/main..HEAD --oneline 2>/dev/null)" ] && [ "$DO_BUILD" = 0 ]; then
    echo "[提示] 本地有未推送的提交，发布时会一并推送。"
fi

# --- 1. 构建 ---
if [ "$DO_BUILD" = 1 ]; then
    echo "== 构建 v$VER_NAME =="
    ./build.sh
else
    echo "== 跳过构建（--no-build）=="
fi
[ -f "$APK" ] || { echo "[错误] 没找到 APK：$APK" >&2; exit 1; }

NOTES="$VER_DIR/GitHub-Release说明.md"
INFO="$VER_DIR/版本信息.txt"
[ -f "$NOTES" ] || NOTES="$INFO"

# --- 1.5 同步 dist/（main 分支直接下载的安装包）---
echo "== 同步 dist/ =="
rm -f dist/*.apk 2>/dev/null || true
mkdir -p dist
cp -f "$APK" dist/
cp -f "$INFO" dist/版本信息.txt
# 更新清单 + 定名直链：Gitee / GitHub 的 raw 都直接吃这两个文件，
# raw 上的中文名容易被各种客户端转义出错，所以另存一份纯 ASCII 名字的最新包。
cp -f "$APK" dist/musicorganizer-latest.apk
APK_SHA="$(sha256sum "$APK" | awk '{print $1}')"
APK_SIZE="$(stat -c %s "$APK")"
SUMMARY="$(head -n 1 "$NOTES" 2>/dev/null | sed 's/^#\{1,\}[[:space:]]*//')"
cat > dist/latest.txt <<EOF
# 版本清单（App 检查更新时优先读它：国内 Gitee 优先，GitHub 兜底）
# 格式见 AppUpdate.parseManifest：每行 key=value
version=$VER_NAME
code=$VER_CODE
tag=$TAG
apk=dist/musicorganizer-latest.apk
size=$APK_SIZE
sha256=$APK_SHA
summary=$SUMMARY
page=https://gitee.com/kakadex/MusicOrganizer/releases
github=https://github.com/kakadex/MusicOrganizer/releases
date=$(date '+%Y-%m-%d')
EOF
# 更新 README 里的 dist 文件名与体积占位（两处链接文本 + 一处体积）
sed -i -E "s|dist/音乐整理工具-v[0-9A-Za-z.-]+\.apk|dist/音乐整理工具-$TAG.apk|g" README.md
APK_KB="$(( $(stat -c %s "$APK") / 1024 ))"
sed -i -E "s|约 [0-9]+ KB|约 $APK_KB KB|g" README.md
git add dist README.md
if git diff --cached --quiet; then
    echo "       dist 无变化"
else
    git commit -q -m "发布 $TAG：更新 dist 安装包"
    echo "       dist 已更新并提交"
fi

# --- 2. 覆盖 release-assets 孤儿分支 ---
echo "== 更新 release-assets =="
WT="$PKG/../.publish-worktree"
rm -rf "$WT"
git fetch -q origin release-assets || true
git worktree add -q "$WT" --detach
cleanup() { git -C "$PKG" worktree remove "$WT" --force >/dev/null 2>&1 || rm -rf "$WT"; }
trap cleanup EXIT

(
    cd "$WT"
    git checkout -q --orphan "rel-$(date +%s)"
    git rm -rf . -q 2>/dev/null || true
    cp -f "$APK" .
    cp -f "$NOTES" notes.md
    cp -f "$INFO" .
    # 分支首页说明：优先沿用上一版（自动替换版本号），没有再生成一个简版
    if git show origin/release-assets:README.md > README.md 2>/dev/null; then
        sed -i "s|release/v[0-9A-Za-z.-]*|release/$TAG|g; s|\"v[0-9A-Za-z.-]* 发布素材\"|\"$TAG 发布素材\"|g" README.md
    else
        {
            echo "# $TAG 发布素材（临时分支）"
            echo
            echo "本分支只放发布产物，供 GitHub Actions 建 Release 使用，也作为下载兜底入口。"
            echo
            echo "- 安装包：\`音乐整理工具-$TAG.apk\`"
            echo "- 说明：\`notes.md\`（首行即 Release 标题）"
            echo "- 构建信息：\`版本信息.txt\`"
            echo
            echo "正式下载页：<https://github.com/kakadex/MusicOrganizer/releases/latest>"
        } > README.md
    fi
    git add -A
    git -c user.name=MusicOrganizer -c user.email=musicorganizer@users.noreply.github.com \
        commit -q -m "$TAG 发布素材"
    git push -q origin HEAD:release-assets --force
    echo "       APK $(stat -c %s "$APK") 字节 已上传"
)
cleanup
trap - EXIT
cd "$PKG"

# --- 3. 打 tag ---
if [ "$DO_TAG" = 1 ]; then
    echo "== 打 tag $TAG =="
    TITLE="$(head -1 "$NOTES" | sed 's/^#\{1,\}[[:space:]]*//')"
    git tag -d "$TAG" >/dev/null 2>&1 || true
    git push -q origin ":refs/tags/$TAG" >/dev/null 2>&1 || true
    git tag -a "$TAG" -m "$TITLE"
    git push -q origin "$TAG"
    echo "       $TAG -> $(git rev-parse --short HEAD)"
fi

# --- 4. 推 main ---
echo "== 推送 main =="
git push -q origin main
echo "       main -> $(git rev-parse --short HEAD)"

# --- 5. 推 Gitee 镜像（国内下载 / 更新走这里；没配远端就跳过）---
if git remote get-url gitee >/dev/null 2>&1; then
    echo "== 推送 Gitee 镜像 =="
    OK=0
    for i in 1 2 3; do
        if git push -q gitee main; then
            if [ "$DO_TAG" = 1 ]; then
                # Gitee 上同名 tag 已存在时 push 会被拒（force 也没用），先删再推
                git push -q gitee ":refs/tags/$TAG" >/dev/null 2>&1 || true
                git push -q gitee "$TAG" || true
            fi
            OK=1
            break
        fi
        echo "       第 $i 次失败，5 秒后重试…"
        sleep 5
    done
    if [ "$OK" = 1 ]; then
        echo "       Gitee 已更新 -> $(git rev-parse --short HEAD)"
    else
        echo "[警告] Gitee 推送失败（不影响 GitHub 发布），稍后可手动补推：" >&2
        echo "       git push gitee main && git push gitee $TAG" >&2
    fi
else
    echo "== 跳过 Gitee（未配置 gitee 远端，见 SETUP 里的镜像配置）=="
fi

echo
echo "完成：v$VER_NAME（versionCode $VER_CODE）"
echo "  本地 APK：$APK"
echo "  国内直连：https://gitee.com/kakadex/MusicOrganizer/raw/main/dist/musicorganizer-latest.apk"
echo "  下载兜底：https://github.com/kakadex/MusicOrganizer/tree/release-assets"
echo "  Release ：https://github.com/kakadex/MusicOrganizer/releases"
