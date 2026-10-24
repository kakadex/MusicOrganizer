#!/usr/bin/env bash
# 音乐整理工具（安卓版）· 收尾存档：把「当前状态」刷进 START-HERE.md
#
# 用法：
#   ./checkpoint.sh                       # 刷新入口文档并打印状态
#   ./checkpoint.sh --quiet               # 只刷新，不打印（给 publish.sh 调用）
#   ./checkpoint.sh --log "一句话说明"     # 顺便往当日流水追加一条记录
#
# 目的：上下文被压缩或换窗口时，新会话读 START-HERE.md 即可接上，不靠记忆。
set -e

PKG="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$PKG/.." && pwd)"   # 工作区根（工具链 env/ 与 .workbuddy/memory 都在这一层）
MEMDIR="$ROOT/.workbuddy/memory"
cd "$PKG"
# 显示给用户/粘进新窗口的路径要 Windows 风格（Read 工具认这个），别用 /c/... 形式
PKG_W="$(cygpath -m "$PKG" 2>/dev/null || echo "$PKG")"
MEM_W="$(cygpath -m "$MEMDIR" 2>/dev/null || echo "$MEMDIR")"

QUIET=0
LOGMSG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --quiet) QUIET=1; shift ;;
        --log)   LOGMSG="$2"; shift 2 ;;
        -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "[错误] 未知参数：$1（可用 --quiet / --log \"说明\"）" >&2; exit 1 ;;
    esac
done

# --- 版本与产物 ---
VER_NAME="$(grep -oE 'versionName[[:space:]]+"[^"]+"' app/build.gradle | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
VER_CODE="$(grep -oE 'versionCode[[:space:]]+[0-9]+' app/build.gradle | head -1 | grep -oE '[0-9]+')"
VER_DIR="release/v$VER_NAME"
APK="$VER_DIR/音乐整理工具-v$VER_NAME.apk"
INFO="$VER_DIR/版本信息.txt"

BUILD_TIME="（未构建）"
APK_SIZE="0"
APK_SHA="（无）"
if [ -f "$INFO" ]; then
    BUILD_TIME="$(grep '^构建时间:' "$INFO" | sed 's/^构建时间: *//')"
    APK_SIZE="$(grep '^大小:' "$INFO" | grep -oE '[0-9]+' | head -1)"
    APK_SHA="$(grep '^SHA-256:' "$INFO" | sed 's/^SHA-256: *//')"
fi
[ -n "$BUILD_TIME" ] || BUILD_TIME="（未构建）"
[ -n "$APK_SIZE" ] || APK_SIZE="0"
[ -n "$APK_SHA" ] || APK_SHA="（无）"
APK_SHA_SHORT="$(echo "$APK_SHA" | cut -c1-12)"
APK_EXISTS="否"
[ -f "$APK" ] && APK_EXISTS="是"

# --- git 状态 ---
HEAD_SHORT="$(git rev-parse --short HEAD 2>/dev/null || echo '-')"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
[ -n "$DIRTY" ] || DIRTY=0
REMOTE_RAW="$(git ls-remote origin main 2>/dev/null | cut -c1-7 || true)"
if [ -z "$REMOTE_RAW" ]; then
    SYNC="远端取不到（SSH 抖动，可稍后重试）"
elif [ "$REMOTE_RAW" = "$HEAD_SHORT" ]; then
    SYNC="与远端一致（\`$HEAD_SHORT\`）"
else
    AHEAD="$(git rev-list --count "origin/main..HEAD" 2>/dev/null || echo '?')"
    SYNC="本地 \`$HEAD_SHORT\` / 远端 \`$REMOTE_RAW\`（领先 $AHEAD 个提交，未推送）"
fi

TAG_LIST="$(git tag -l 'v*' | sort -V | tail -3 | tr '\n' ' ' | sed 's/ *$//')"
[ -n "$TAG_LIST" ] || TAG_LIST="（无）"

# --- 待办（HANDOFF 里前 3 条未勾选） ---
TODO="$(grep -E '^- \[ \]' HANDOFF.md 2>/dev/null | head -3 | sed -E 's/^- \[ \] //; s/[：:，,。]$//' || true)"
if [ -z "$TODO" ]; then
    TODO="（HANDOFF.md 没有未勾选的顶层待办）"
fi
TODO_BLOCK="$(echo "$TODO" | sed 's/^/  - /')"

# --- 生成入口文档 ---
TMP="START-HERE.md.tmp"
{
    echo "# 从这里开始 · 音乐整理工具（安卓版）"
    echo
    echo "> 新窗口第一句直接粘这句："
    echo "> \`读 $PKG_W/START-HERE.md，按里面的路径和待办继续\`"
    echo ">"
    echo "> 本文件由 \`./checkpoint.sh\` 生成，**手改会被覆盖**；要改内容请改脚本里的模板。"
    echo
    echo "## 0. 当前状态"
    echo
    echo "<!-- AUTO:BEGIN -->"
    echo "- 版本：**v$VER_NAME**（versionCode $VER_CODE）｜构建于 $BUILD_TIME"
    echo "- APK：\`$VER_DIR/音乐整理工具-v$VER_NAME.apk\`，$APK_SIZE 字节，SHA-256 前 12 位 \`$APK_SHA_SHORT\`（本地存在：$APK_EXISTS）"
    echo "- 代码：$SYNC｜未提交改动 $DIRTY 个文件"
    echo "- 最近 tag：$TAG_LIST"
    echo "- 下一步（HANDOFF 前 3 条待办）："
    echo "$TODO_BLOCK"
    echo "<!-- AUTO:END -->"
    echo
    echo "## 1. 开新窗口按顺序读三份（约 2 分钟）"
    echo
    echo "| 顺序 | 文件 | 内容 |"
    echo "|---|---|---|"
    echo "| 1 | \`$PKG_W/HANDOFF.md\` | 版本进度、已定约束、关键路径、完整待办（细节最多） |"
    echo "| 2 | \`$MEM_W/MEMORY.md\` | 长期硬约束：工具链位置、发版规则、代码架构、能力边界（**每次会话自动注入**） |"
    echo "| 3 | \`$MEM_W/<日期>.md\` | 当日流水：刚改了什么、踩了什么坑（读最新一份） |"
    echo
    echo "## 2. 常用命令"
    echo
    echo '| 场景 | 命令 |'
    echo '|---|---|'
    echo "| 构建签名 | \`cd $PKG_W && ./build.sh\` |"
    echo '| 构建 + 推 GitHub | `./publish.sh`（`--no-build` 复用已有 APK，`--no-tag` 只同步） |'
    echo '| 收尾存档 | `./checkpoint.sh`（刷新本文件） |'
    echo '| 离线回归 | `./tools/run_core_test.sh && ./tools/run_tag_test.sh` |'
    echo '| 联网自检 | `tools/SourceSmokeTest.java`（注释里有 javac/java 命令） |'
    echo '| 下载最新 APK | <https://github.com/kakadex/MusicOrganizer/tree/release-assets> |'
    echo
    echo "## 3. 防断流纪律"
    echo
    echo "1. **每做完一块工作就跑一次 \`./checkpoint.sh\`**，10 秒，把状态写进磁盘而不是留在对话里。"
    echo "2. **每次发版 \`./publish.sh\` 会自动调 checkpoint** 并把刷新结果一起提交，不用单独跑。"
    echo "3. 判断「能不能安全中断」只有一个标准：**下一步要做什么，是否已经写进 HANDOFF.md 的待办**。"
    echo "   没写就等于没交接 —— 因为上下文一旦被压缩，只有文件活下来。"
    echo "4. 长任务（>30 分钟或跨多个功能）中途也要 checkpoint，不要攒到最后。"
} > "$TMP"
mv -f "$TMP" START-HERE.md

# --- 可选：追加当日流水 ---
if [ -n "$LOGMSG" ]; then
    mkdir -p "$MEMDIR"
    LOGFILE="$MEM_W/$(date '+%Y-%m-%d').md"
    [ -f "$LOGFILE" ] || echo "# $(date '+%Y-%m-%d')" > "$LOGFILE"
    echo "- $(date '+%H:%M') checkpoint：$LOGMSG" >> "$LOGFILE"
fi

if [ "$QUIET" = 0 ]; then
    echo "已刷新 START-HERE.md"
    echo "  版本      v$VER_NAME（versionCode $VER_CODE）"
    echo "  代码      $SYNC｜未提交 $DIRTY 个文件"
    echo "  下一步    $(echo "$TODO" | head -1)"
    echo
    echo "  新窗口开场：读 $PKG_W/START-HERE.md，按里面的路径和待办继续"
fi
