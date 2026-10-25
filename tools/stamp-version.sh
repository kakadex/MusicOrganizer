#!/usr/bin/env bash
# 把 app/build.gradle 里 versionName 的「后缀」改成源码内容哈希（6 位十六进制）。
#
# 为什么用内容哈希而不是随机串 / 提交 SHA：
#   * 随机串：同一份代码每次打包后缀都不一样，无法判断两个包是不是同一份源码；
#   * 提交 SHA：本项目的流程是「先构建、后提交」，构建时那个 SHA 还是上一版代码的，
#     反而会标错。
#   内容哈希对同一份源码稳定、对任何改动敏感，且不需要先提交。
#
# 哈希口径：把工作区（含未跟踪的新文件、遵守 .gitignore）写进一个临时索引得到 tree，
# 再对 tree 里的 blob 做 sha256 —— 只排除 app/build.gradle 自己（它存着版本号，
# 否则「写版本号」这件事本身会改变哈希，永远算不稳）。
#
# 用法：
#   tools/stamp-version.sh          # 改写 versionName 后缀并打印结果
#   tools/stamp-version.sh --print  # 只打印将要使用的哈希，不改文件
#
# 由 build.sh 自动调用；MO_NO_STAMP=1 可跳过。
set -e

PROJ="$(cd "$(dirname "$0")/.." && pwd)"
GRADLE="$PROJ/app/build.gradle"
cd "$PROJ"

PRINT_ONLY=0
[ "$1" = "--print" ] && PRINT_ONLY=1

if [ ! -d "$PROJ/.git" ]; then
    echo "[stamp] 不是 git 仓库，无法计算内容哈希，沿用 build.gradle 里的值" >&2
    exit 0
fi

GIT_DIR="$(git rev-parse --git-dir)"
TMP_INDEX="$GIT_DIR/mo-stamp-index.$$"
cleanup() { rm -f "$TMP_INDEX"; }
trap cleanup EXIT

# 用临时索引把当前工作区（含未跟踪文件）做成 tree，不碰真实索引、不改工作区
GIT_INDEX_FILE="$TMP_INDEX" git read-tree HEAD
GIT_INDEX_FILE="$TMP_INDEX" git add -A >/dev/null 2>&1 || true
TREE="$(GIT_INDEX_FILE="$TMP_INDEX" git write-tree)"

# 排除版本元数据（否则「写版本号」本身会改变哈希）与已构建产物（dist/ 里是最新 APK，
# 每次发版都会变，会污染源码指纹）。release/ 已被 .gitignore 排除，不必另写。
HASH="$(git ls-tree -r "$TREE" \
    | awk -F'\t' '$2 != "app/build.gradle" && $2 !~ /^dist\// {print $1 "\t" $2}' \
    | LC_ALL=C sort -k2 \
    | sha256sum | cut -c1-6)"

CUR="$(grep -oE 'versionName[[:space:]]+"[^"]+"' "$GRADLE" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
BASE="${CUR%%-*}"
NEW="$BASE-$HASH"

if [ "$PRINT_ONLY" = "1" ]; then
    echo "$NEW"
    exit 0
fi

if [ "$CUR" = "$NEW" ]; then
    echo "  versionName      = $NEW（后缀已是当前内容哈希，未改动）"
    exit 0
fi

sed -i -E 's/versionName[[:space:]]+"[^"]*"/versionName "'"$NEW"'"/' "$GRADLE"
echo "  versionName      = $CUR → $NEW（内容哈希）"
