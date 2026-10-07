#!/bin/sh
# 打包 moonGit CLI 发布产物（本地构建后手动发布用）
set -e
VERSION="${1:-0.1.0}"
PLATFORM="${2:-$(uname -m)}"
case "$PLATFORM" in
  arm64|aarch64) PLATFORM="darwin-arm64" ;;
  x86_64)        PLATFORM="linux-x64" ;;
  *)             PLATFORM="$PLATFORM" ;;
esac
BIN="target/release/bin/moongit"
[ -f "$BIN" ] || { echo "先 cjpm build"; exit 1; }
OUT="moongit-v${VERSION}-${PLATFORM}.tar.gz"
cp "$BIN" moongit-cli
chmod +x moongit-cli
tar czf "$OUT" moongit-cli
echo "✓ $OUT"
