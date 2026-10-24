#!/usr/bin/env bash
# 音乐整理工具（安卓版）· 一键构建并签名（Windows Git Bash / macOS / Linux 可用）
#
# 脚本会自己找工具链，两种情形都支持：
#   ① 项目内/上一级有便携工具链（env/jdk17、env/gradle-8.9、env/Sdk）→ 优先用，不碰系统环境
#   ② 没有的话 → 用你系统里已有的 JDK 17、Android SDK 和项目自带的 gradlew
#      前提：JAVA_HOME 指向 JDK 17，且已装 Android SDK（platform-34 + build-tools 34.0.0），
#      或者设置 ANDROID_HOME / ANDROID_SDK_ROOT
#
# 签名证书与口令不随仓库分发，见 signing.properties.example
#
# 用法：
#   ./build.sh            # Release：构建 + zipalign + 签名 + 校验 + 归档
#   ./build.sh debug      # Debug：用调试证书自动签名，可直接安装
#   ./build.sh install    # Release 构建后 adb install -r 到已连接设备
set -e

PKG="$(cd "$(dirname "$0")" && pwd)"
PROJ="$PKG"
MODE="${1:-release}"

# --- 定位工具链：便携优先，其次系统环境 ---
TOOLS=""
if [ -d "$PKG/env/jdk17" ]; then
    TOOLS="$PKG"
elif [ -d "$PKG/../env/jdk17" ]; then
    TOOLS="$(cd "$PKG/.." && pwd)"
fi

if [ -n "$TOOLS" ]; then
    export JAVA_HOME="$TOOLS/env/jdk17"
    export ANDROID_HOME="$TOOLS/env/Sdk"
    export ANDROID_SDK_ROOT="$ANDROID_HOME"
    export GRADLE_USER_HOME="$TOOLS/gradle-home"
    export PATH="$JAVA_HOME/bin:$PATH"
    GRADLE_CMD="$TOOLS/env/gradle-8.9/bin/gradle.bat"
    [ -f "$GRADLE_CMD" ] || GRADLE_CMD="$TOOLS/env/gradle-8.9/bin/gradle"
else
    # 标准环境：尊重用户已有的 JAVA_HOME / ANDROID_HOME，用仓库自带的 wrapper
    if [ -z "$JAVA_HOME" ]; then
        echo "[错误] 未找到便携工具链，且 JAVA_HOME 未设置。请先安装 JDK 17 并设置 JAVA_HOME。" >&2
        exit 1
    fi
    if [ -z "$ANDROID_HOME" ] && [ -z "$ANDROID_SDK_ROOT" ]; then
        echo "[错误] 未设置 ANDROID_HOME（Android SDK 路径）。" >&2
        exit 1
    fi
    : "${ANDROID_HOME:=${ANDROID_SDK_ROOT}}"
    export ANDROID_HOME ANDROID_SDK_ROOT
    GRADLE_CMD="sh $PROJ/gradlew"
fi

# build-tools 版本自适应（用户机器上的版本可能不是 34.0.0）
SDK_BT=""
if [ -d "$ANDROID_HOME/build-tools/34.0.0" ]; then
    SDK_BT="$ANDROID_HOME/build-tools/34.0.0"
else
    for d in "$ANDROID_HOME"/build-tools/*/; do
        [ -d "$d" ] && SDK_BT="${d%/}"
    done
fi
SDK_PT="$ANDROID_HOME/platform-tools"
REL="$PROJ/app/build/outputs/apk/release"

JAVA_BIN="$JAVA_HOME/bin/java.exe"
[ -x "$JAVA_BIN" ] || JAVA_BIN="$JAVA_HOME/bin/java"

# 生成 local.properties（用正斜杠的 Windows 路径，Gradle/AGP 可直接识别，免反斜杠转义踩坑）
# 把 /c/xxx 形式转成 C:/xxx，已是 Windows 路径则原样使用
SDK_WIN="$ANDROID_HOME"
if command -v cygpath >/dev/null 2>&1; then
    SDK_WIN="$(cygpath -m "$ANDROID_HOME")"
fi
printf 'sdk.dir=%s\n' "$SDK_WIN" > "$PROJ/local.properties"

echo "== 构建环境 =="
echo "  JAVA_HOME        = $JAVA_HOME"
echo "  ANDROID_HOME     = $ANDROID_HOME"
echo "  工具链来源       = ${TOOLS:-系统环境 + gradlew}"
echo "  build-tools      = $SDK_BT"
echo "  工程目录         = $PROJ"

if [ "$MODE" = "debug" ]; then
    echo "== [1/1] 构建 Debug APK =="
    $GRADLE_CMD -p "$PROJ" assembleDebug --no-daemon
    echo "完成: $PROJ/app/build/outputs/apk/debug/app-debug.apk"
    exit 0
fi

# ---------------------------------------------------------------------------
# 签名配置：仓库里不含任何证书与口令，全部从本地 signing.properties 或环境变量取。
# 优先级：环境变量 > signing.properties > 常见默认路径
# ---------------------------------------------------------------------------
KS_FILE="${SIGNING_KS:-}"
KS_ALIAS="${SIGNING_ALIAS:-musicorganizer}"
KS_PASS="${SIGNING_STORE_PASS:-}"
KEY_PASS="${SIGNING_KEY_PASS:-}"

PROPS="$PKG/signing.properties"
if [ -f "$PROPS" ]; then
    # 极简 key=value 解析；不用 source，避免口令里的特殊字符被 shell 解释
    prop() {
        sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$PROPS" | head -1 | tr -d '\r'
    }
    _v="$(prop storeFile)";      if [ -n "$_v" ]; then KS_FILE="$_v"; fi
    _v="$(prop keyAlias)";       if [ -n "$_v" ]; then KS_ALIAS="$_v"; fi
    if [ -z "$KS_PASS" ];  then KS_PASS="$(prop storePassword)"; fi
    if [ -z "$KEY_PASS" ]; then KEY_PASS="$(prop keyPassword)"; fi
fi

if [ -z "$KS_FILE" ]; then
    for _c in "$TOOLS/signing/release.keystore" "$PKG/signing/release.keystore"; do
        if [ -f "$_c" ]; then KS_FILE="$_c"; break; fi
    done
fi
if [ -z "$KEY_PASS" ]; then KEY_PASS="$KS_PASS"; fi

if [ -z "$KS_FILE" ] || [ ! -f "$KS_FILE" ]; then
    cat >&2 <<'EOF'
[错误] 找不到签名证书。

Release 包必须签名才能安装。三种解决办法：

  1) 复制配置模板并填入自己的证书：
       cp signing.properties.example signing.properties
     （signing.properties 已被 .gitignore 忽略，不会提交到仓库）

  2) 用环境变量指定：
       export SIGNING_KS=/path/to/release.keystore
       export SIGNING_STORE_PASS=你的口令

  3) 只想装到自己的手机上验证，直接出 Debug 包（用调试证书自动签名）：
       ./build.sh debug
EOF
    exit 1
fi
if [ -z "$KS_PASS" ]; then
    echo "[错误] 未提供证书口令：请设置 signing.properties 的 storePassword 或环境变量 SIGNING_STORE_PASS" >&2
    exit 1
fi

echo "  签名证书         = $KS_FILE（别名 $KS_ALIAS）"

# 读取 app/build.gradle 里的 versionName，产物按版本归档到 release/v<版本>/
VER_NAME="$(grep -oE 'versionName[[:space:]]+"[^"]+"' "$PROJ/app/build.gradle" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
VER_CODE="$(grep -oE 'versionCode[[:space:]]+[0-9]+' "$PROJ/app/build.gradle" | head -1 | grep -oE '[0-9]+')"
[ -n "$VER_NAME" ] || VER_NAME="unknown"
VER_DIR="$PKG/release/v$VER_NAME"
APK_OUT="$VER_DIR/音乐整理工具-v$VER_NAME.apk"

# ---------------------------------------------------------------------------
# 防「忘升版本号」：别用新代码覆盖已归档的旧版本
#
# 产物路径由 versionName 决定，所以忘记 bump 时，build.sh 会把上一个版本的归档 APK
# 覆盖成「新代码 + 旧版本号」的混合包 —— 装上去版本号是旧的、功能是新的，
# 而且原来那个包只能从 GitHub Release 找回。这个坑在 v0.1.45 / v0.1.50 / v0.1.51
# 连续踩了三次，所以在这里直接拦住。
#
# 判定从简：目标版本目录里已经有 APK 就退出。不判断工作区脏否 —— 实测同代码重建的
# 产物与线上也不是逐字节相同（签名里有非确定性因素），「干净重建」一样会让归档漂移。
# 设 MO_BUILD_FORCE=1 可跳过（确实要重建同一版本时用，比如签名证书换了要重签）。
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# `./build.sh check`：只编译，不打包 / 不签名 / 不归档。
#
# 为什么需要它：下面的归档保护会拦住「同一版本重复构建」，而开发中改完代码
# 经常只想知道「能不能编译过」，不想为此升一次版本号。这个模式只跑 javac。
# ---------------------------------------------------------------------------
if [ "$1" = "check" ] || [ "$1" = "compile" ]; then
    echo "== 只编译（不产出 APK）=="
    $GRADLE_CMD -p "$PROJ" compileReleaseJavaWithJavac --no-daemon
    exit $?
fi

# 判定「已发布的版本」而不是「目录里有文件」：
# 开发期每次改完都会重新构建同一版本，用「目录里有 APK」当条件会把正常流程也拦住
# （publish.sh 内部还会再跑一次 build.sh）。真正要保护的是**已经推出去的那份**，
# 它一定有对应的 tag（v$VER_NAME）。
if [ -n "$MO_BUILD_FORCE" ]; then
    : # 显式要求重建
elif [ -f "$APK_OUT" ] && git -C "$PROJ" rev-parse -q --verify "refs/tags/v$VER_NAME" >/dev/null 2>&1; then
    cat >&2 <<EOF
[错误] v$VER_NAME 已经发布过（tag v$VER_NAME 存在），而归档包正在被重新构建。

  再构建会用当前代码覆盖 $VER_DIR 里的归档包：
    · 如果忘了升版本号 —— 得到「新代码 + 旧版本号」的混合包，装上去版本号是旧的、
      功能却是新的，原来那个包只能去 GitHub Release 找回；
    · 即使代码没变，产物也不会与线上逐字节相同（签名含非确定性因素），
      本地归档会与 GitHub Release 对不上。

  处理方式：
    · 正常发版：先把 versionCode / versionName 升一位，再跑本脚本
    · 确实要重建：MO_BUILD_FORCE=1 ./build.sh

  当前 versionName=$VER_NAME  versionCode=$VER_CODE
EOF
    exit 1
fi

echo "== [1/4] 构建 Release APK =="
$GRADLE_CMD -p "$PROJ" assembleRelease --no-daemon

echo "== [2/4] zipalign 对齐 =="
"$SDK_BT/zipalign.exe" -f -p 4 "$REL/app-release-unsigned.apk" "$REL/app-release-aligned.apk"

echo "== [3/4] apksigner 签名 =="
# 口令不写在命令行里（进程列表可见），改用 env: 传递
export SIGNING_STORE_PASS="$KS_PASS"
export SIGNING_KEY_PASS="$KEY_PASS"
"$JAVA_BIN" -jar "$SDK_BT/lib/apksigner.jar" sign \
    --ks "$KS_FILE" --ks-key-alias "$KS_ALIAS" \
    --ks-pass env:SIGNING_STORE_PASS --key-pass env:SIGNING_KEY_PASS \
    --out "$REL/app-release.apk" "$REL/app-release-aligned.apk"

echo "== [4/4] 校验签名 =="
"$JAVA_BIN" -jar "$SDK_BT/lib/apksigner.jar" verify -v "$REL/app-release.apk"

mkdir -p "$VER_DIR"
cp -f "$REL/app-release.apk" "$APK_OUT"

BUILD_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
APK_SHA="$(sha256sum "$APK_OUT" | cut -d' ' -f1)"
APK_SIZE="$(stat -c %s "$APK_OUT")"

{
    echo "音乐整理工具 · 安卓版 v$VER_NAME (versionCode $VER_CODE)"
    echo "构建时间: $BUILD_TIME"
    echo "包名: com.dsh.musicorganizer"
    echo "SDK: minSdk 24 / targetSdk 34"
    echo "签名: v2/v3（本地证书，别名 $KS_ALIAS）"
    echo "SHA-256: $APK_SHA"
    echo "大小: $APK_SIZE 字节"
    echo
    echo "安装说明：直接覆盖安装即可（versionCode 递增、证书与 0.1.x 各版一致，不会丢偏好设置）。"
    echo "          仅当从旧的 2.x 内部开发版（或其它证书签名的包）升级时，才需要先卸载。"
} > "$VER_DIR/版本信息.txt"

# 交接摘要：刷新 HANDOFF.md 的 AUTO 区块（版本/时间/SHA），并把快照放进版本目录
HANDOFF="$PKG/HANDOFF.md"
if [ -f "$HANDOFF" ]; then
    echo "== 刷新交接摘要 =="
    awk -v ver="$VER_NAME" -v code="$VER_CODE" -v bt="$BUILD_TIME" \
        -v sha="$APK_SHA" -v size="$APK_SIZE" '
        /<!-- AUTO:BEGIN -->/ {
            print
            print "- 最新版本：**v" ver "**（versionCode " code "）"
            print "- 构建时间：" bt
            print "- APK：`release/v" ver "/音乐整理工具-v" ver ".apk`（" size " 字节）"
            print "- SHA-256：`" sha "`"
            skip = 1
            next
        }
        /<!-- AUTO:END -->/ { skip = 0 }
        skip != 1 { print }
    ' "$HANDOFF" > "$HANDOFF.tmp" && mv -f "$HANDOFF.tmp" "$HANDOFF"
    cp -f "$HANDOFF" "$VER_DIR/交接摘要.md"
    echo "       $HANDOFF"
    echo "       $VER_DIR/交接摘要.md"
fi

echo "完成: $APK_OUT"
echo "       $VER_DIR/版本信息.txt"

if [ "$MODE" = "install" ]; then
    echo "== adb install -r =="
    ADB="$SDK_PT/adb"
    [ -f "$ADB.exe" ] && ADB="$ADB.exe"
    command -v adb >/dev/null 2>&1 && ADB="adb"
    "$ADB" install -r "$REL/app-release.apk"
fi
