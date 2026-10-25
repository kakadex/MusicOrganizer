#!/usr/bin/env bash
# 把安卓 APK 与 Windows 桌面版 exe 挂到 Gitee 的 Release（v0.1.89 起）。
#
# 为什么需要它：GitHub 那边靠 Actions 自动建 Release 挂附件，Gitee 没有等价机制，
# 只能走 API。Token 从工作区根的 gitee.txt 读，不打印。
#
# 用法：
#   ./tools/gitee-release.sh <tag> <notes.md> [apk] [exe]
# 例：
#   ./tools/gitee-release.sh v0.1.89-236781 release/v0.1.89-236781/GitHub-Release说明.md \
#       release/v0.1.89-236781/音乐整理工具-v0.1.89-236781.apk \
#       ../MusicOrganizerWIN64/dist/MusicOrganizer.exe
set -uo pipefail

PKG="$(cd "$(dirname "$0")/.." && pwd)"
TOKEN_FILE="$PKG/../gitee.txt"
API="https://gitee.com/api/v5/repos/kakadex/MusicOrganizer"

TAG="${1:-}"
NOTES="${2:-}"
APK="${3:-}"
EXE="${4:-}"
if [ -z "$TAG" ]; then
    echo "用法：$0 <tag> <notes.md> [apk] [exe]" >&2
    exit 1
fi
if [ ! -f "$TOKEN_FILE" ]; then
    echo "[跳过] 找不到 $TOKEN_FILE（Gitee 凭据）" >&2
    exit 0
fi
TOKEN="$(tr -d ' \r\n' < "$TOKEN_FILE")"

pyjson() {
    # 从 stdin 的 JSON 里取一个字段；取不到输出空
    "$PYBIN" -c 'import sys,json
try:
    print(json.load(sys.stdin).get(sys.argv[1], "") or "")
except Exception:
    print("")' "$1"
}
PYBIN="$(command -v python || command -v python3 || true)"
[ -n "$PYBIN" ] || { echo "[错误] 没找到 python，无法解析 JSON" >&2; exit 1; }

TITLE="$(head -n 1 "$NOTES" 2>/dev/null | sed 's/^#\{1,\}[[:space:]]*//')"
[ -n "$TITLE" ] || TITLE="$TAG"
BODY_FILE="$(mktemp)"
[ -f "$NOTES" ] && tail -n +2 "$NOTES" > "$BODY_FILE" || : > "$BODY_FILE"

echo "== Gitee Release $TAG =="
RESP="$(curl -s -H "Authorization: token $TOKEN" "$API/releases/tags/$TAG")"
RELEASE_ID="$(printf '%s' "$RESP" | pyjson id)"
if [ -z "$RELEASE_ID" ]; then
    echo "   创建 Release…"
    RESP="$(curl -s -X POST -H "Authorization: token $TOKEN" \
        --data-urlencode "tag_name=$TAG" \
        --data-urlencode "name=$TITLE" \
        --data-urlencode "body@$BODY_FILE" \
        --data-urlencode "target_commitish=main" \
        "$API/releases")"
    RELEASE_ID="$(printf '%s' "$RESP" | pyjson id)"
fi
if [ -z "$RELEASE_ID" ]; then
    echo "[失败] 建 Release 未拿到 id：$(printf '%s' "$RESP" | head -c 200)" >&2
    rm -f "$BODY_FILE"
    exit 1
fi
echo "   release id = $RELEASE_ID"

upload() {
    local file="$1"
    [ -f "$file" ] || { echo "   [跳过] 不存在：$file"; return 0; }
    local name
    name="$(basename "$file")"
    case "$name" in
        *.apk) name="MusicOrganizer-$TAG.apk" ;;
        *.exe) name="MusicOrganizer-desktop-$TAG.exe" ;;
        *.md|*.txt) name="notes${name##*.}" ;;
    esac
    local out
    out="$(curl -s -X POST -H "Authorization: token $TOKEN" \
        -F "file=@$file;filename=$name" "$API/releases/$RELEASE_ID/attach_files")"
    local url
    url="$(printf '%s' "$out" | pyjson browser_download_url)"
    if [ -n "$url" ]; then
        echo "   已上传 $(basename "$file") → $url"
    else
        echo "   [失败] $(basename "$file")：$(printf '%s' "$out" | head -c 160)"
    fi
}

upload "$APK"
upload "$EXE"
rm -f "$BODY_FILE"
echo "   页面：https://gitee.com/kakadex/MusicOrganizer/releases/tag/$TAG"
