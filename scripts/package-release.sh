#!/bin/sh
# 打包 moonGit CLI 发布产物（本地构建后手动发布用）。
#
# ⚠️ 这个包必须离开构建机也能跑（AGENTS 不变量 7/8/9/133）：
#   · 裸二进制的 rpath 带构建机绝对路径（~/.local/share/cangjie/...），
#     离开本机 dyld 直接 Library not loaded —— 必须删绝对 rpath、只留
#     @executable_path 相对 rpath，并把仓颉 runtime dylib 一起打进包里。
#   · 改过 load command 的二进制必须重新 ad-hoc 签名（arm64 未签名会被
#     AMFI 直接 SIGKILL，exit 137 零输出）。
#   · tar 根部放 moongit 启动器注入 cjHeapSize=1gb：仓颉运行时堆上限只在
#     进程启动前生效，发布通道绕过它 = 大仓库 graph arch 的 OOM 在发布产物上复发。
#   · 平台探测必须同时看 uname -s 与 uname -m：只看 -m 会把 macOS Intel
#     误标成 linux-x64。
set -e

VERSION="${1:-0.1.0}"

# ------------------------------ 平台探测 ------------------------------
# 原来只看 uname -m：macOS Intel（x86_64）会被标成 linux-x64。
# 显式传第二参数可覆盖（CI 里传完整三元组名，如 darwin-arm64）。
if [ -n "${2:-}" ]; then
  PLATFORM="$2"
else
  OS_NAME="$(uname -s)"
  MACHINE="$(uname -m)"
  case "${OS_NAME}:${MACHINE}" in
    Darwin:arm64|Darwin:aarch64) PLATFORM="darwin-arm64" ;;
    Darwin:x86_64)               PLATFORM="darwin-x64" ;;
    Linux:x86_64)                PLATFORM="linux-x64" ;;
    Linux:aarch64|Linux:arm64)   PLATFORM="linux-arm64" ;;
    *)
      echo "[错误] 无法识别的平台：${OS_NAME} ${MACHINE}（可显式传第二参数，如 darwin-arm64）"
      exit 1
      ;;
  esac
fi

IS_DARWIN=false
[ "$(uname -s)" = "Darwin" ] && IS_DARWIN=true

BIN="target/release/bin/main"
[ -f "$BIN" ] || { echo "先 cjpm build"; exit 1; }
OUT="moongit-v${VERSION}-${PLATFORM}.tar.gz"

# ------------------------------ 仓颉 runtime 定位 ------------------------------
# runtime dylib 的来源。CJ_HOME 推导顺序：环境变量 → cjc 所在 SDK → 默认安装路径。
if [ -n "${CANGJIE_HOME:-}" ]; then
  CJ_HOME="$CANGJIE_HOME"
elif command -v cjc >/dev/null 2>&1; then
  CJ_HOME="$(cd "$(dirname "$(command -v cjc)")/.." && pwd)"
elif [ -d "$HOME/.local/share/cangjie/current" ]; then
  CJ_HOME="$HOME/.local/share/cangjie/current"
else
  echo "[错误] 找不到仓颉 SDK（runtime 库来源）；请设置 CANGJIE_HOME 或先 source envsetup.sh"
  exit 1
fi

STAGE="$(mktemp -d /tmp/moongit-pkg.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/bin" "$STAGE/runtime/lib"

cp "$BIN" "$STAGE/bin/moongit-cli"
chmod 755 "$STAGE/bin/moongit-cli"
CLI="$STAGE/bin/moongit-cli"

# ------------------------------ macOS：rpath 治理 + runtime 捆绑 ------------------------------
if [ "$IS_DARWIN" = true ] && [ "${PLATFORM#darwin}" != "$PLATFORM" ]; then
  # 依赖清单以 otool -L 实测为准，不写死名字：将来多一个 @rpath 依赖自动跟上。
  MISSING=""
  for dep in $(otool -L "$CLI" | tail -n +2 | awk '{ print $1 }'); do
    case "$dep" in
      /usr/lib/*|/System/*) continue ;;
      @rpath/*) lib="${dep#@rpath/}" ;;
      *)
        echo "[错误] 出现非 @rpath 的非系统依赖：$dep"
        echo "       需要先 install_name_tool -change 改成 @rpath 引用再打包（本脚本暂不处理该形态）"
        exit 1
        ;;
    esac
    SRC_LIB="$(find "$CJ_HOME/runtime/lib" -name "$lib" -type f 2>/dev/null | head -1)"
    if [ -z "$SRC_LIB" ]; then
      MISSING="${MISSING} ${lib}"
      continue
    fi
    cp "$SRC_LIB" "$STAGE/runtime/lib/$lib"
  done
  if [ -n "$MISSING" ]; then
    echo "[错误] 在 ${CJ_HOME}/runtime/lib 下找不到这些依赖：${MISSING}"
    exit 1
  fi

  # rpath 治理（不变量 7）：剥签名 → 逐条删绝对 rpath（收字符串不收序号，
  # 传序号会报错但退出码仍是 0）→ 确保相对 rpath → 重新 ad-hoc 签名。
  codesign --remove-signature "$CLI" 2>/dev/null || true
  for p in $(otool -l "$CLI" | awk '/LC_RPATH/{f=1} f && /path / {print $2; f=0}'); do
    case "$p" in
      @executable_path/*|@loader_path/*) ;;  # 相对 rpath 保留
      *) install_name_tool -delete_rpath "$p" "$CLI" ;;
    esac
  done
  # dylib 放在 runtime/lib/ 下；dyld 不递归 rpath 目录，两条相对 rpath 都要有。
  ensure_rpath() {
    if otool -l "$CLI" | grep -qF "path $1 "; then return 0; fi
    install_name_tool -add_rpath "$1" "$CLI"
  }
  ensure_rpath "@executable_path/../runtime"
  ensure_rpath "@executable_path/../runtime/lib"
  codesign --force --sign - "$CLI"

  # 打包前自检：不许残留任何绝对 rpath（不变量 9 的前置）。
  BAD_RPATH="$(otool -l "$CLI" | awk '/LC_RPATH/{f=1} f && /path / {print $2; f=0}' | grep -v '^@' || true)"
  if [ -n "$BAD_RPATH" ]; then
    echo "[错误] 仍有绝对 rpath：${BAD_RPATH}"
    exit 1
  fi
else
  # Linux：ELF 没有 codesign/otool；依赖清单用 ldd 实测，运行期靠启动器的 LD_LIBRARY_PATH。
  # ⚠️ ldd 缺失必须显式失败（含从 macOS 显式交叉打 linux 包的场景 —— 那里本来就没有 ldd）：
  # 原来静默跳过整段拷贝，产出一个不含仓颉 runtime 的包且仍打印「✓」——
  # 与 macOS 侧「找不到依赖就 exit 1」不对称，坏包要到用户机器上才炸（不变量 7/9 同族）。
  if ! command -v ldd >/dev/null 2>&1; then
    echo "[错误] linux 平台打包需要 ldd 探测运行时依赖（未找到 ldd）；请在 linux 上打包或先安装 binutils"
    exit 1
  fi
  for dep in $(ldd "$CLI" | awk '$3 ~ /^\// { print $3 }'); do
    case "$dep" in
      */libcangjie-*|*/libboundscheck*) cp "$dep" "$STAGE/runtime/lib/" ;;
    esac
  done
fi

# ------------------------------ 根部启动器（cjHeapSize，对齐 moongit.sh / install.sh） ------------------------------
cat > "$STAGE/moongit" <<'WRAP'
#!/bin/sh
# moonGit 发布包启动器：给仓颉运行时一个够用的堆（只在未设置时设，尊重调用方的选择）。
# 仓颉运行时的堆上限由 cjHeapSize 决定（必须带单位，如 1gb），且只在进程启动前生效 ——
# 程序自己改不了，只能在启动器这一层设。默认堆偏小：大仓库的
# graph arch --format json|html|scene 会 OutOfMemoryError（cjHeapSize=1gb 下恒通过）。
if [ -z "${cjHeapSize:-}" ]; then export cjHeapSize=1gb; fi
SELF="$0"
case "$SELF" in */*) ;; *) SELF="$(command -v "$SELF" 2>/dev/null || echo "$SELF")" ;; esac
ROOT="$(dirname "$SELF")"
# Linux 下 runtime 靠 LD_LIBRARY_PATH 解析（dylib 的相对 rpath 是 macOS 机制）
case "$(uname -s)" in
  Linux) export LD_LIBRARY_PATH="${ROOT}/runtime/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" ;;
esac
exec "${ROOT}/bin/moongit-cli" "$@"
WRAP
chmod 755 "$STAGE/moongit"

tar czf "$OUT" -C "$STAGE" moongit bin runtime
echo "✓ $OUT"
echo "  布局：moongit（启动器，注入 cjHeapSize=1gb）/ bin/moongit-cli / runtime/lib/"
echo "  自验（离开构建机也能跑的判据）："
echo "    tar xzf ${OUT} -C /tmp/pkgtest && env -i /tmp/pkgtest/moongit --help"
