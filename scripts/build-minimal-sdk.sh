#!/bin/sh
# deepGit macOS SDK 精简包：把 1.7GB 系统 SDK 裁成 <1MB，只保留仓颉链接器所需的 arm64-macos 元数据。
#
# 为什么需要：macOS 26+ SDK 只声明 arm64e-macos（与仓颉自带 ld64.lld 15.0.4 不兼容）；
# 系统 SDK 在 26+ 上丢失 arm64-macos ABI 切片，导致 undefined symbol 错误。
# 解法：从 macOS 15.5 SDK（最后含 arm64-macos 的版本）中挑出链器真正用到的元数据。
#
# 用法：
#   sh scripts/build-minimal-sdk.sh                  # 从你机器上的 MacOSX15.5.sdk 裁剪
#   sh scripts/build-minimal-sdk.sh <path-to-sdk>    # 或显式指定源
#
# 输出：~/.local/share/sdks/MacOSX.minimal/<version>/
set -e

DST="${DEEPGIT_MIN_SDK:-$HOME/.local/share/sdks/MacOSX.minimal/latest}"

# 找源 SDK（优先用旧 15.5，再考虑 Xcode 自带）
SRC=""
if [ -n "$1" ]; then SRC="$1"
else
  for CAND in \
    "$HOME/.local/share/sdks/MacOSX15.5.sdk" \
    "$HOME/Downloads/MacOSX15.5.sdk" \
    "$HOME/Downloads/MacOSX15.4.sdk" \
    ; do
    if [ -d "$CAND" ]; then SRC="$CAND"; break; fi
  done
fi

if [ -z "$SRC" ]; then
  cat <<'EOF'
[错误] 未找到 macOS 15.x SDK。

deepGit 需要一份含 arm64-macos ABI 的 macOS SDK 才能在 macOS 26+ 上链接
（仓颉自带的 ld64.lld 15.0.4 无法解析新 SDK 的 arm64e-macos 切片）。

可选来源：
  1) https://github.com/joseluisq/macosx-sdks/releases/tag/15.5
     下载 MacOSX15.5.sdk.tar.xz 后放到 ~/.local/share/sdks/
  2) Apple 旧版 Xcode 自带（Xcode 15.x）

然后重跑本脚本即可。
EOF
  exit 1
fi

echo "源 SDK：$SRC"
echo "目标 SDK：$DST"
echo

mkdir -p "$DST"
# 1) 必要的 TBD 元数据（链器解析 arm64-macos 切片用）
mkdir -p "$DST/usr/lib"
for TBD in libSystem.tbd libSystem.B.tbd libc.tbd libm.tbd libdl.tbd libpthread.tbd; do
  [ -f "$SRC/usr/lib/$TBD" ] && cp "$SRC/usr/lib/$TBD" "$DST/usr/lib/"
# SQLite 存储（graph db / confidence db，2026-10-12）：极简 SDK 补手写 tbd
# （系统 libsqlite3.dylib 在 dyld shared cache，源 SDK 无 tbd 可拷）
if [ ! -f "$DST/usr/lib/libsqlite3.tbd" ]; then
  printf '%s\n' \
    '--- !tapi-tbd' \
    'tbd-version:     4' \
    'targets:         [ x86_64-macos, arm64-macos ]' \
    "install-name:    '/usr/lib/libsqlite3.dylib'" \
    'current-version: 406' \
    'compatibility-version: 9' \
    'exports:' \
    '  - targets:         [ x86_64-macos, arm64-macos ]' \
    '    symbols:         [ _sqlite3_bind_int64, _sqlite3_bind_text, _sqlite3_close,' \
    '                       _sqlite3_column_int64, _sqlite3_column_text, _sqlite3_errmsg,' \
    '                       _sqlite3_exec, _sqlite3_finalize, _sqlite3_free,' \
    '                       _sqlite3_open_v2, _sqlite3_prepare_v2, _sqlite3_reset,' \
    '                       _sqlite3_step ]' \
    > "$DST/usr/lib/libsqlite3.tbd"
fi
done

# 2) SDK 元数据
[ -f "$SRC/SDKSettings.plist" ] && cp "$SRC/SDKSettings.plist" "$DST/"

# 3) 空的 System 目录（链器要求存在；实际无需任何内容）
mkdir -p "$DST/System/Library/Frameworks"

echo
SIZE=$(du -sh "$DST" | cut -f1)
echo "✓ 完成：${DST}（${SIZE}）"
echo
echo "用法：export SDKROOT=\"$DST\""
echo "     或在 deepgit install.sh 中已自动检测该路径。"