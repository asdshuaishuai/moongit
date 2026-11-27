#!/bin/sh
# Cambium CI 检查：构建 release + 全量测试（串行）。
#
# 封装 AGENTS.md「构建与测试」的环境三件套，调用方不必各抄一遍：
#   1. source envsetup.sh（仓颉工具链）
#   2. SDKROOT=极简兼容 SDK（macOS 26/27+ 的 libSystem.tbd 只声明 arm64e，
#      自带 ld64.lld 解析不了，必须指到裁剪过的 arm64-macos SDK）
#   3. DEEPGIT_HOME=一次性沙箱（红线：不带它测试会写进用户真实数据）
#
# 用法：sh scripts/ci-check.sh
set -e
DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR"

if [ -f "$HOME/.local/share/cangjie/current/envsetup.sh" ]; then
  # shellcheck disable=SC1091
  . "$HOME/.local/share/cangjie/current/envsetup.sh"
else
  echo "✗ 找不到仓颉工具链：~/.local/share/cangjie/current/envsetup.sh" >&2
  exit 1
fi
if [ -d "$HOME/.local/share/sdks/MacOSX.minimal/latest" ]; then
  SDKROOT="$HOME/.local/share/sdks/MacOSX.minimal/latest"
  export SDKROOT
fi

# 一次性沙箱 store：每次调用一个新目录，绝不指向用户真实数据
DEEPGIT_HOME="$(mktemp -d "${TMPDIR:-/tmp}/cambium-ci.XXXXXX")"
export DEEPGIT_HOME
cleanup() { rm -rf "$DEEPGIT_HOME"; }
trap cleanup EXIT

echo "› cjpm build（release）"
cjpm build
echo "› cjpm test --parallel 1（DEEPGIT_HOME=${DEEPGIT_HOME}）"
cjpm test --parallel 1
