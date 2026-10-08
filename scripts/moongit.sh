#!/bin/sh
# moonGit 快速启动：构建（如需）并运行常用命令
set -e

DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="$DIR"

if ! command -v cjc >/dev/null 2>&1; then
  CJ_HOME="${CANGJIE_HOME:-$HOME/.local/share/cangjie/current}"
  [ -f "$CJ_HOME/envsetup.sh" ] && . "$CJ_HOME/envsetup.sh" >/dev/null 2>&1
fi
if [ -z "${SDKROOT:-}" ] && [ -d "$HOME/.local/share/sdks/MacOSX.minimal/latest" ]; then
  export SDKROOT="$HOME/.local/share/sdks/MacOSX.minimal/latest"
fi

BIN="$ENGINE/target/release/bin/main"
if [ ! -x "$BIN" ]; then
  echo "› 首次运行，构建引擎…"
  (cd "$ENGINE" && cjpm build 2>&1 | tail -2)
fi

# 仓颉运行时的**堆上限**由 `cjHeapSize` 决定（必须带单位，如 `1gb`；取值范围 [4MB, 系统内存]）。
# 默认值偏小：大仓库的 `graph arch --format json|html|scene` 会 `OutOfMemoryError`
# （实测 deepGit / deepOrca / ddolphin 在默认堆下崩，`cjHeapSize=1gb` 下恒通过）。
# 该变量只在**进程启动前**生效 —— 程序自己改不了，所以只能在启动器这一层设。
# 用户/调用方已显式设置时不覆盖。
[ -z "${cjHeapSize:-}" ] && export cjHeapSize=1gb

exec "$BIN" "$@"
