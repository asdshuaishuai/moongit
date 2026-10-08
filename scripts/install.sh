#!/bin/sh
# moonGit 安装脚本：构建引擎 + 装到 PATH + 可选构建 macOS 菜单栏应用
set -e

DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="$DIR"
# 命令名 2026-10-03 起是 moongit。MOONGIT_PREFIX 是新的，
# DEEPGIT_PREFIX 保留为兼容入口（老 shell 配置里可能还写着它）。
PREFIX="${MOONGIT_PREFIX:-${DEEPGIT_PREFIX:-$HOME/.local/bin}}"

echo "moonGit 安装"
echo "  仓库：$DIR"
echo "  安装到：$PREFIX"
echo

# ------------------------------- 工具链检查 -------------------------------
if ! command -v cjc >/dev/null 2>&1; then
  CJ_HOME="${CANGJIE_HOME:-$HOME/.local/share/cangjie/current}"
  if [ -f "$CJ_HOME/envsetup.sh" ]; then
    # shellcheck disable=SC1090
    . "$CJ_HOME/envsetup.sh" >/dev/null 2>&1
  fi
fi

if ! command -v cjc >/dev/null 2>&1; then
  cat <<'EOF'
[错误] 未找到仓颉编译器 cjc。

请先安装仓颉 SDK（LTS 1.0.5，macOS arm64）：
  1. 打开 https://cangjie-lang.cn/download/1.0.5
  2. 下载 cangjie-sdk-mac-aarch64-1.0.5.tar.gz
  3. 解压后执行：
       mkdir -p ~/.local/share/cangjie
       mv cangjie ~/.local/share/cangjie/1.0.5
       ln -sfn ~/.local/share/cangjie/1.0.5 ~/.local/share/cangjie/current
       echo 'source ~/.local/share/cangjie/current/envsetup.sh' >> ~/.zshrc
  4. 重开终端或 source ~/.zshrc，再运行本脚本

提示：macOS 26+ 系统 SDK 不兼容仓颉自带链接器（ld64.lld 15.0.4）。
      本脚本会自动下载 macOS 15.5 SDK 并裁剪为 ~2MB 极简版。
      如需手动安装源 SDK：https://github.com/joseluisq/macosx-sdks/releases
EOF
  exit 1
fi

CJ_HOME="${CANGJIE_HOME:-$(dirname "$(dirname "$(command -v cjc)")")}"

# 检索顺序：环境变量 → 极简 SDK → 老版 15.x
COMPAT_SDK=""
for CAND in "${DEEPGIT_SDKROOT:-}" "$HOME/.local/share/sdks/MacOSX.minimal/latest" "$HOME/.local/share/sdks/MacOSX15.5.sdk"; do
  if [ -n "$CAND" ] && [ -d "$CAND" ]; then COMPAT_SDK="$CAND"; break; fi
done
if [ -n "$COMPAT_SDK" ]; then
  export SDKROOT="$COMPAT_SDK"
  echo "  使用兼容 SDK：$COMPAT_SDK"
else
  echo "  未找到兼容 SDK，自动下载并裁剪…"
  mkdir -p "$HOME/.local/share/sdks/_cache"
  curl -sL --max-time 600 -o /tmp/deepgit-macos15.5.sdk.tar.xz     "https://github.com/joseluisq/macosx-sdks/releases/download/15.5/MacOSX15.5.sdk.tar.xz"
  if [ ! -s /tmp/deepgit-macos15.5.sdk.tar.xz ]; then
    echo "  [错误] 下载 macOS 15.5 SDK 失败，请检查网络后重试"
    exit 1
  fi
  mkdir -p "$HOME/.local/share/sdks/_cache/macos15.5"
  tar xJf /tmp/deepgit-macos15.5.sdk.tar.xz -C "$HOME/.local/share/sdks/_cache/macos15.5"
  sh "$DIR/scripts/build-minimal-sdk.sh" "$HOME/.local/share/sdks/_cache/macos15.5/MacOSX15.5.sdk"
  rm -rf "$HOME/.local/share/sdks/_cache" /tmp/deepgit-macos15.5.sdk.tar.xz
  export SDKROOT="$HOME/.local/share/sdks/MacOSX.minimal/latest"
fi

# ------------------------------- 构建引擎 -------------------------------
echo "› 构建 deepGit 引擎…"
cd "$ENGINE"
if ! SDKROOT="${SDKROOT:-}" cjpm build > /tmp/deepgit-build.log 2>&1; then
  echo "[错误] 引擎构建失败，完整日志：/tmp/deepgit-build.log"
  sed 's/\x1b\[[0-9;]*m//g' /tmp/deepgit-build.log | grep -E "^(error|\[error)" -A4 | head -30
  exit 1
fi
echo "  构建成功（日志：/tmp/deepgit-build.log）"

BIN=""
for CANDIDATE in \
  "$ENGINE/target/release/bin/main" \
  "$ENGINE/target/release/bin/moongit" \
  "$ENGINE/target/debug/bin/main" \
  "$ENGINE/target/debug/bin/moongit"; do
  if [ -x "$CANDIDATE" ]; then BIN="$CANDIDATE"; break; fi
done

if [ -z "$BIN" ]; then
  echo "[错误] 构建未产出可执行文件"
  exit 1
fi

# ------------------------------- 安装 CLI -------------------------------
mkdir -p "$PREFIX"
# ⚠️ 装的是**包装脚本**，不是裸二进制。原因：仓颉运行时的堆上限由环境变量 `cjHeapSize`
# 决定（**必须带单位**，如 `1gb`；范围 [4MB, 系统内存]），而它只在**进程启动前**生效 ——
# 程序自己改不了，只能在启动器这一层设。默认堆偏小：大仓库的 `graph arch --format
# json|html|scene` 会 `OutOfMemoryError`（实测 deepGit / deepOrca / ddolphin 默认堆下崩、
# `cjHeapSize=1gb` 下恒通过）。客户端按 `~/.local/bin/moongit` 发现引擎，也会走到这里。
cp "$BIN" "$PREFIX/.moongit-bin"
chmod 755 "$PREFIX/.moongit-bin"
cat > "$PREFIX/moongit" <<'WRAP'
#!/bin/sh
# moonGit 启动器：给仓颉运行时一个够用的堆（只在未设置时设，尊重调用方的选择）。
if [ -z "${cjHeapSize:-}" ]; then export cjHeapSize=1gb; fi
SELF="$0"
case "$SELF" in */*) ;; *) SELF="$(command -v "$SELF" 2>/dev/null || echo "$SELF")" ;; esac
exec "$(dirname "$SELF")/.moongit-bin" "$@"
WRAP
chmod 755 "$PREFIX/moongit"
echo "✓ 已安装：$PREFIX/moongit（启动器；真实二进制：$PREFIX/.moongit-bin）"

# 兼容软链：老脚本、老习惯里敲的还是 `deepgit`。
#
# ⚠️ 引擎的**数据目录仍然是 ~/.deepgit**、文档托管区域标记仍然是
#    `<!-- deepgit:begin -->` —— 这两样是用户既有数据与既有文档里的内容，
#    跟着仓改名会把它们变成孤儿（引擎认不出已托管的区域，于是另开新区）。
#    所以本次只改「命令名」这一层，落在磁盘上的东西一律不动。
#
# 软链而不是拷贝：拷贝会出现两份各自独立、版本不一致的二进制，
# 而 `moongit upgrade` 只更新本体，旧名字那份会永远停在旧版本。
ln -sf moongit "$PREFIX/deepgit"
echo "✓ 兼容软链：$PREFIX/deepgit -> moongit"

if ! echo ":$PATH:" | grep -q ":$PREFIX:"; then
  echo
  echo "提示：$PREFIX 不在 PATH 中。加入 shell 配置："
  echo "  echo 'export PATH=\"$PREFIX:\$PATH\"' >> ~/.zshrc"
fi

# ------------------------------- 验证 -------------------------------
echo
echo "› 自检："
"$PREFIX/moongit" doctor 2>&1 | head -12

# macOS 客户端（deepDolphin.app）单独构建：
#   sh deepDolphin/macos/build.sh   （在 deepDolphin 仓库中）

echo
echo "下一步："
echo "  1. 注册项目群：moongit scan ~/dev --depth 4"
echo "  2. 查看进度：  moongit status"
echo "  3. 浅更新：    moongit update"
echo "  4. 装提交钩子：moongit hook install <项目>"
echo "  5. 配 AI（可选）：export DEEPGIT_AI_API_KEY=... && moongit config set ai.preset deepseek"
echo
echo "  旧命令名 deepgit 仍可用（软链到 moongit）；"
echo "  数据目录 ~/.deepgit 与文档托管区域标记均未改动。"
