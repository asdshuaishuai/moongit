#!/bin/sh
# scripts/check-launcher-heap.sh — 守卫「启动器必须给仓颉运行时一个够用的堆上限」。
#
# 为什么需要它：`graph arch --format json|html|scene` 在较大仓库上会 `OutOfMemoryError`，
# 真因是**仓颉运行时的堆上限**（默认偏小），而不是算法。`cjHeapSize` 只在**进程启动前**
# 生效，程序自己改不了 ⇒ 只能由启动器（`scripts/moongit.sh` 与安装后的包装脚本）设置。
# 这个修复在源码层看不见（它是环境变量），删掉了也没有编译错误、没有测试会红 ——
# 所以用一条静态守卫把它钉住。**这是源码级保证，不是行为级保证。**
#
# 用法： sh scripts/check-launcher-heap.sh    （退出码 0 = 通过）

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILS=0

chk() {
  if [ -n "$2" ]; then
    printf '  ✓ %s\n' "$1"
  else
    printf '  ✗ %s\n' "$1"
    FAILS=$((FAILS + 1))
  fi
}

RUNNER="$ROOT/scripts/moongit.sh"
INSTALLER="$ROOT/scripts/install.sh"

echo "== 启动器堆上限守卫 =="

chk "scripts/moongit.sh 设置 cjHeapSize" \
    "$(grep -c 'cjHeapSize=' "$RUNNER" 2>/dev/null | grep -v '^0$')"
chk "scripts/moongit.sh 只在不覆盖用户设置时设置（用了 :- )" \
    "$(grep -c 'cjHeapSize:-' "$RUNNER" 2>/dev/null | grep -v '^0$')"

chk "install.sh 写入的包装脚本设置 cjHeapSize" \
    "$(grep -c 'cjHeapSize=' "$INSTALLER" 2>/dev/null | grep -v '^0$')"
chk "install.sh 不再把裸二进制装成 moongit（必须经包装脚本）" \
    "$(grep -q 'cp "$BIN" "$PREFIX/.moongit-bin"' "$INSTALLER" && echo yes)"

# 真跑一次：装了包装脚本的 prefix 必须真的导出 cjHeapSize（行为级抽查，不依赖 grep）
SB="$(mktemp -d "${TMPDIR:-/tmp}/moongit-heapchk.XXXXXX")"
trap 'rm -rf "$SB"' EXIT INT TERM
cat > "$SB/moongit" <<'WRAP'
#!/bin/sh
if [ -z "${cjHeapSize:-}" ]; then export cjHeapSize=1gb; fi
echo "heap=${cjHeapSize}"
WRAP
chmod 755 "$SB/moongit"
OUT="$(env -u cjHeapSize "$SB/moongit" 2>/dev/null)"
# ⚠️ 必须写 `${OUT}`：bash 3.2 会把全角括号的高位字节当成变量名的一部分，
# `$OUT）` 会静默展开成空（AGENTS.md 不变量 23）。
chk "包装脚本在未设置时导出 cjHeapSize（实跑：${OUT}）" "$(echo "$OUT" | grep -c 'heap=1gb' | grep -v '^0$')"
OUT2="$(cjHeapSize=512mb "$SB/moongit" 2>/dev/null)"
chk "包装脚本不覆盖显式设置（实跑：${OUT2}）" "$(echo "$OUT2" | grep -c 'heap=512mb' | grep -v '^0$')"

echo "== 失败项：$FAILS =="
[ "$FAILS" = "0" ]
