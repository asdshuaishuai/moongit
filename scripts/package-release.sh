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
  # Linux：ELF 没有 codesign/otool。
  # ⚠⚠ **不能靠 ldd 找仓颉库** —— ldd 解析依赖靠的是**运行时的库搜索路径**
  #   （LD_LIBRARY_PATH / ld.so.conf）：在刚 source 过 envsetup.sh 的 shell 里能找到，
  #   在「CI 的另一个 step（没 source）」里就**全部 not found**
  #   ⇒ 旧实现静默产出**不含仓颉 runtime 的坏包**（实测 v0.2.0：CI 产物的
  #   runtime/lib 是空的，装到用户机器上 exec 报 "not found"，
  #   而流水线全绿、release 照发、客户端照下载 —— 坏包一路到用户手里才炸）。
  # ⇒ 两处改法：
  #   ① 依赖清单用 **readelf -d 的 DT_NEEDED**（读二进制本身，**不依赖运行时环境**）；
  #   ② 库来源用 **SDK 目录**（权威），找不到就 exit 1（不再静默跳过）。
  #   ⚠ macOS 分支不受影响（它用 otool -L + find $CJ_HOME/runtime/lib）——
  #     同一份脚本里两个平台两套依赖探测，正是「同名多处互相顶替」的温床。
  if ! command -v readelf >/dev/null 2>&1; then
    echo "[错误] linux 平台打包需要 readelf 探测依赖（未找到）；请安装 binutils"
    exit 1
  fi
  RUNTIME_ROOT="$CJ_HOME/runtime/lib"
  if [ ! -d "$RUNTIME_ROOT" ]; then
    echo "[错误] 找不到仓颉 runtime 目录：${RUNTIME_ROOT}"
    exit 1
  fi
  # DT_NEEDED：直接从二进制里读，不看运行时的库搜索路径。
  NEEDED="$(readelf -d "$CLI" | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p')"
  BUNDLED=""
  MISSING=""
  for lib in $NEEDED; do
    # 只有仓颉自己的 runtime 库需要进包；系统库（libc/libm/libsqlite3.so.0…）
    # 由发行版提供 —— 强行塞一份进包反而可能与用户系统里的版本打架。
    case "$lib" in
      libcangjie-*|libboundscheck*) ;;
      *) continue ;;
    esac
    SRC_LIB="$(find "$RUNTIME_ROOT" -name "$lib" -type f 2>/dev/null | head -1)"
    if [ -z "$SRC_LIB" ]; then
      MISSING="${MISSING} ${lib}"
      continue
    fi
    cp "$SRC_LIB" "$STAGE/runtime/lib/$lib"
    BUNDLED="${BUNDLED} ${lib}"
  done
  if [ -n "$MISSING" ]; then
    echo "[错误] 在 ${RUNTIME_ROOT} 下找不到这些仓颉 runtime 库：${MISSING}"
    exit 1
  fi
  if [ -z "$BUNDLED" ]; then
    echo "[错误] 一个仓颉 runtime 库都没打进包（产物必然跑不起来）"
    exit 1
  fi
  echo "  捆绑的 runtime：${BUNDLED}"
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

# ------------------------------ 打包后自验（**真的跑**，不是打印口令） ------------------------------
# ⚠⚠ 原来这里只**打印**自验口令、从不执行 ⇒ 坏包照样「✓」出厂（实测 v0.2.0：
#   CI 产物缺仓颉 runtime，脚本仍打印「✓」，流水线全绿，坏包一路发布到用户手里）。
# ⇒ 现在自己解包 + 在**空环境**里跑起来；跑不起来就 exit 1（让流水线红，别发出去）。
VERIFY_DIR="$(mktemp -d /tmp/moongit-verify.XXXXXX)"
tar xzf "$OUT" -C "$VERIFY_DIR"
# ⚠ env -i：清空环境变量 ⇒ 暴露「靠构建机绝对路径/环境变量才跑得起来」的包。
if ! env -i "$VERIFY_DIR/moongit" --help >/dev/null 2>&1; then
  echo "[错误] 产物自验失败：解包后在**空环境**里跑不起来"
  echo "       判据：env -i ${VERIFY_DIR}/moongit --help"
  echo "       包内容："
  tar tzf "$OUT" | sed 's/^/         /'
  exit 1
fi
rm -rf "$VERIFY_DIR"
echo "  ✓ 自验通过：解包后能在空环境里跑起来（runtime 齐全）"
