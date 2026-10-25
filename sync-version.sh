#!/bin/sh
# 版本同步：VERSION（唯一真源）→ pubspec.yaml 的 version 行 → lib/core/version.dart
#
# 用法：
#   ./sync-version.sh                 # 用 VERSION 里的版本 + 现有 build 号，重算哈希并写文件
#   ./sync-version.sh 0.2.1           # 同时改 VERSION
#   ./sync-version.sh 0.2.1 --code 113# 同时指定 versionCode（build 号）
#   ./sync-version.sh --check         # 只校验（CI 用）
#
# 版本号规则（与另一端一致）：二、三段 0-99，满 100 进位；
#   build 号（+NNN）单调递增，必须为整数。
# 逃生门：MO_ALLOW_ANY_VERSION=1 跳过规则校验（回退 / 补发时使用）。
set -e
cd "$(dirname "$0")"

CHECK=0
NEW_VER=""
NEW_CODE=""
ALLOW_ANY="${MO_ALLOW_ANY_VERSION:-0}"

while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1 ;;
    --code) shift; NEW_CODE="$1" ;;
    --code=*) NEW_CODE="${1#--code=}" ;;
    -*) echo "未知参数：$1" >&2; exit 2 ;;
    *) NEW_VER="$1" ;;
  esac
  shift
done

if [ "$CHECK" = 1 ]; then
  dart run tools/stamp-version.dart --check
  exit $?
fi

# --- 1. 目标版本 ---
if [ -n "$NEW_VER" ]; then
  if ! echo "$NEW_VER" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "版本格式应为 X.Y.Z，当前：$NEW_VER" >&2
    exit 2
  fi
  OLD_VER=$(cat VERSION 2>/dev/null || echo "")
  if [ -n "$OLD_VER" ] && [ "$OLD_VER" != "$NEW_VER" ] && [ "$ALLOW_ANY" != 1 ]; then
    IFS=. read -r o1 o2 o3 <<EOF
$OLD_VER
EOF
    IFS=. read -r n1 n2 n3 <<EOF
$NEW_VER
EOF
    # 二、三段必须在 0-99；满 100 必须进位
    if [ "$n2" -gt 99 ] || [ "$n3" -gt 99 ]; then
      if [ "$n2" -gt 99 ] && [ "$n3" -ne 0 ]; then
        echo "版本号越界：第二段/第三段都必须 0-99（满 100 进位），建议 ${n1}.$((n2 + 1)).0" >&2
        exit 2
      fi
      echo "版本号越界：第二段/第三段都必须 0-99（满 100 进位）" >&2
      exit 2
    fi
    if [ "$o1" = "$n1" ] && [ "$n2" -lt "$o2" ]; then
      echo "版本号回退：$OLD_VER → $NEW_VER（确需回退用 MO_ALLOW_ANY_VERSION=1）" >&2
      exit 2
    fi
  fi
  echo "$NEW_VER" > VERSION
fi

VER=$(cat VERSION | tr -d '[:space:]')

# --- 2. build 号 ---
CUR_CODE=$(sed -n 's/^version: *[0-9.]*+\([0-9][0-9]*\).*/\1/p' pubspec.yaml | head -1)
if [ -z "$CUR_CODE" ]; then
  CUR_CODE=1
fi
if [ -n "$NEW_CODE" ]; then
  CODE="$NEW_CODE"
else
  CODE=$((CUR_CODE + 1))
fi

# --- 3. 写 pubspec（只改 version 行，别的行原样保留）---
python3 - "$VER" "$CODE" <<'PY'
import io, re, sys
ver, code = sys.argv[1], sys.argv[2]
p = 'pubspec.yaml'
s = io.open(p, encoding='utf-8').read()
new_line = 'version: %s+%s' % (ver, code)
if re.search(r'^version:.*$', s, flags=re.M):
    s = re.sub(r'^version:.*$', new_line, s, count=1, flags=re.M)
else:
    s = s.replace('publish_to:', new_line + '\npublish_to:', 1)
io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('pubspec: %s' % new_line)
PY

# --- 4. 生成 version.dart（内容哈希后缀）---
dart run tools/stamp-version.dart

echo "OK  VERSION=$VER  build=$CODE"
grep -n '^version:' pubspec.yaml
grep -n 'kAppVersionFull' lib/core/version.dart | head -1
