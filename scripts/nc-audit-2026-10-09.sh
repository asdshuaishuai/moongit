#!/bin/sh
# scripts/nc-audit-2026-10-09.sh — 负控：audit-2026-10-09 修复所加的判据
# 必须能被**真缺陷**打红（把原缺陷改回去 → 对应测试必须红）。
#
# 纪律（AGENTS.md 不变量 66 / 112 / 120，另见 audit 文档末段记的那次教训）：
#   · 每个变体注入后**自证文件真的变了**（md5 前后比对）——「注入未生效」
#     与「判据无效」的修法完全相反；
#   · 还原挂 trap EXIT；还原后核对内容复原；
#   · 区分「判据没红」与「编译失败」—— 编译失败不是判据抓到了；
#   · **注入要命中判据真正在查的那一处**：本轮写替换时按形状匹配把
#     listBranches / listTags 一并改坏过（同一形状三处、只该改一处），
#     所以这里每个锚点都用足够长的上下文，并且一次只改一个文件。
#
# 用法： sh scripts/nc-audit-2026-10-09.sh
# 前置：需仓颉工具链（脚本会尝试自动 source envsetup；SDKROOT 可用环境变量覆盖）。

set +u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ -z "${CANGJIE_HOME:-}" ] && [ -f "$HOME/.local/share/cangjie/current/envsetup.sh" ]; then
  # shellcheck disable=SC1091
  . "$HOME/.local/share/cangjie/current/envsetup.sh"
fi
set -u
# ⚠️ 不能写 `${SDKROOT:-…}`：envsetup 会在未设时把它设成 Xcode 全量 SDK
# （macOS 26/27 的 libSystem.tbd 缺 arm64-macos 声明 ⇒ 链接报 undefined symbol: _strtod）。
export SDKROOT="${MOONGIT_SDKROOT:-$HOME/.local/share/sdks/MacOSX.minimal/latest}"
export DEEPGIT_HOME="${DEEPGIT_HOME:-/tmp/dg-nc-audit-home-$$}"

SB="$(mktemp -d "${TMPDIR:-/tmp}/moonGit-nc-audit.XXXXXX")"
FILES="src/graph/patchconf.cj src/graph/build.cj src/graph/model.cj src/util/paths.cj src/util/json.cj \
       src/util/text.cj src/kernel/lock.cj src/kernel/config.cj src/kernel/git.cj src/graph/arch.cj \
       src/graph/archscene.cj src/graph/render.cj src/graph/extract.cj src/graph/confidence_render.cj \
       src/graph/confidence_detect.cj src/graph/confidence_ast.cj src/cli/cli.cj"

restore_all() {
  for f in $FILES; do
    [ -f "$SB/backup/$f" ] && cp "$SB/backup/$f" "$f"
  done
}
cleanup() { restore_all; rm -rf "$SB"; }
trap cleanup EXIT INT TERM

for f in $FILES; do
  mkdir -p "$SB/backup/$(dirname "$f")"
  cp "$f" "$SB/backup/$f"
done

md5_of() { md5 -q "$1" 2>/dev/null || md5sum "$1" | awk '{print $1}'; }

FAILS=0

# run_case <用例名> → 0 通过 / 1 变红 / 2 未判定（编译失败或缺结果）
# ⚠️ ERROR 也算变红：注入的缺陷常常让用例**抛异常**而不是断言失败
# （例：prettyPath 的裸切片抛 Invalid utf8 byte sequence）。这两种都是「打红了」。
# 与「编译失败」区分：编译失败时整份日志里没有任何 `] CASE:` 行。
RC=0
run_case() {
  cjpm test --parallel 1 --filter "$1" > "$SB/out.log" 2>&1
  RC=$?
  sed -e 's/\x1b\[[0-9;]*m//g' "$SB/out.log" > "$SB/clean.log"
  # ⚠️ 状态位是**定宽对齐**的：`[ ERROR  ]`（两个空格）与 `[ FAILED ]`
  # （一个空格）不同宽，写死一个空格会漏掉 ERROR —— 负控就那么空转过两轮。
  if grep -qE "(FAILED|ERROR)[[:space:]]+\] CASE: $1 " "$SB/clean.log"; then
    if grep -qE "FAILED[[:space:]]+\] CASE: $1 " "$SB/clean.log"; then RED_KIND=FAILED; else RED_KIND=ERROR; fi
    return 1
  fi
  if grep -qE "PASSED[[:space:]]+\] CASE: $1 " "$SB/clean.log"; then return 0; fi
  return 2
}
RED_KIND="-"


# check <标签> <用例名> <被改文件> <md5-前>
check() {
  local label="$1" name="$2" file="$3" before="$4"
  local after; after="$(md5_of "$file")"
  if [ "$before" = "$after" ]; then
    printf '❌ %s：注入未生效（%s 内容未变）—— 负控失配，非判据问题\n' "$label" "$file"
    FAILS=$((FAILS + 1)); return
  fi
  run_case "$name"
  local r=$?
  if [ "$r" = "1" ]; then
    printf '✅ %s：注入原缺陷 → %s 变红（%s，且注入确实生效）\n' "$label" "$name" "$RED_KIND"
  elif [ "$r" = "0" ]; then
    printf '❌ %s：注入原缺陷 → %s 仍绿 ⇒ 该判据是摆设\n' "$label" "$name"
    FAILS=$((FAILS + 1))
  else
    printf '❌ %s：%s 未判定（编译失败或未跑到该用例）—— 红的原因不是判据\n' "$label" "$name"
    printf '   —— 诊断：rc=%s，关键行 ——\n' "$RC"
    grep -m3 -E "error:|Error:|^\[.*FAILED" "$SB/clean.log" | sed 's/^/      /'
    FAILS=$((FAILS + 1))
  fi
  restore_all
  # 还原也要自证：否则后面每个「绿」都不可信
  if [ "$before" != "$(md5_of "$file")" ]; then
    printf '❌ %s：还原失败（%s 与备份不一致）—— 继续跑只会污染结论\n' "$label" "$file"
    FAILS=$((FAILS + 1))
    cp "$SB/backup/$file" "$file"
  fi
}

echo "== 负控：audit-2026-10-09 修复判据 =="

# ── NC1 · H1：entities.add 挪回前窥 while 体内（重复 entity）──
b="$(md5_of src/graph/patchconf.cj)"
python3 - <<'PY'
p = "src/graph/patchconf.cj"
s = open(p, encoding="utf-8").read()
old = '''                    let conf = if (relCount == 0) { 0.9 } else { relScore / Float64(relCount) }
                    entities.add(PatchEntity("${name}@${pf.newPath}:${pl.newNo}", name,
                        symKindId(kind), conf, rels, pf.newPath, pl.newNo))'''
new = '''                    let conf = if (relCount == 0) { 0.9 } else { relScore / Float64(relCount) }
                    if (look == 1) {
                        entities.add(PatchEntity("${name}@${pf.newPath}:${pl.newNo}", name,
                            symKindId(kind), conf, rels, pf.newPath, pl.newNo))
                    }'''
assert old in s, "NC1 锚点失配"
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
check "NC1 H1 实体每行重复生成" testPatchEntityIsOnePerDeclaration src/graph/patchconf.cj "$b"

# ── NC2 · H2：use-before-def 改回「只看到目前为止的声明」──
b="$(md5_of src/graph/patchconf.cj)"
python3 - <<'PY'
p = "src/graph/patchconf.cj"
s = open(p, encoding="utf-8").read()
old = '''                            match (allPatchDecls.get(tok)) {'''
new = '''                            match (patchDecls.get(tok)) {'''
assert old in s, "NC2 锚点失配"
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
check "NC2 H2 use-before-def 永假" testPatchUseBeforeDefFires src/graph/patchconf.cj "$b"

# ── NC3 · H3：refEdges 物化处不排序（出口字节序跟 HashMap 走）──
# ⚠️ 这条只能用**源码守卫**判：本工具链的 HashMap 迭代序在单进程内恰好有序，
# 于是「删掉排序」后行为断言 testRefEdgesMaterializeInTotalOrder 仍然绿
# （负控第一版就是这么空转的）。判据要卡在「物化处有排序」这个事实上。
b="$(md5_of src/graph/build.cj)"
python3 - <<'PY'
p = "src/graph/build.cj"
s = open(p, encoding="utf-8").read()
old = '''    insertionSortBy(refEdges, { a, b =>
        if (a[0] != b[0]) { return a[0] < b[0] }
        if (a[1] != b[1]) { return a[1] < b[1] }
        return a[2] < b[2]
    })'''
new = '''    let _keepOrder = Int64(refEdges.size)'''
assert old in s, "NC3 锚点失配"
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
check "NC3 H3 引用边物化处无全序" __lintRefEdgesMaterializationHasATotalOrder src/graph/build.cj "$b"

# ── NC4 · H4：prettyPath 退回裸字节切片（中文路径必崩）──
b="$(md5_of src/util/paths.cj)"
python3 - <<'PY'
p = "src/util/paths.cj"
s = open(p, encoding="utf-8").read()
old = '''        let start = if (want < 0) { 0 } else { nextCharBoundary(p, want) }
        return "…" + p[start..]'''
new = '''        let start = if (want < 0) { 0 } else { want }
        return "…" + p[start..]'''
assert old in s, "NC4 锚点失配"
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
check "NC4 H4 中文路径裸切片" testPrettyPathNeverSplitsMultibyteChars src/util/paths.cj "$b"

# ── NC5 · M23：HolderUnknown 不再有恢复通道（锁永不接管）──
b="$(md5_of src/kernel/lock.cj)"
python3 - <<'PY'
p = "src/kernel/lock.cj"
s = open(p, encoding="utf-8").read()
old = '''    if (ageMs >= 0 && ageMs >= staleMs) {
        return AcquireDecision.TakeOver
    }
    return AcquireDecision.Wait
}'''
new = '''    if (false) {
        return AcquireDecision.TakeOver
    }
    return AcquireDecision.Wait
}'''
assert old in s, "NC5 锚点失配"
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
check "NC5 M23 无人认领的锁永不恢复" testUnclaimableLockIsRecoveredAfterStaleWindow src/kernel/lock.cj "$b"

# ── NC6 · M6：unused import 退回「对账单个文件」──
b="$(md5_of src/graph/build.cj)"
python3 - <<'PY'
p = "src/graph/build.cj"
s = open(p, encoding="utf-8").read()
old = '''            match (refCount.get(f.relPath)) {
                case Some(inner) =>
                    for ((to, _) in inner) {
                        if (to != f.relPath && moduleOfPath(to) == mod) { used = true }
                    }
                case None => ()
            }'''
new = '''            // 逐 import 扫边，取“解析出的那一个文件”（原缺陷：包级 import 对账单文件）
            for ((from, to) in importEdges) {
                if (from == f.relPath && to != f.relPath && moduleOfPath(to) == mod) {
                    match (refCount.get(f.relPath)) {
                        case Some(inner) =>
                            match (inner.get(to)) {
                                case Some(_) => used = true
                                case None => ()
                            }
                        case None => ()
                    }
                    break
                }
            }'''
assert old in s, "NC6 锚点失配"
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
check "NC6 M6 unused import 误报" testUnusedImportIsModuleLevel src/graph/build.cj "$b"

# ── NC7 · M12：层 4 参与违规判定──
b="$(md5_of src/graph/arch.cj)"
python3 - <<'PY'
p = "src/graph/arch.cj"
s = open(p, encoding="utf-8").read()
old = '''    if (la >= 4 || lb >= 4) {
        return false
    }
    return la < lb'''
new = '''    return la < lb'''
assert old in s, "NC7 锚点失配"
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
check "NC7 M12 未分层模块算违规" testLayerViolationIgnoresUnclassifiedModules src/graph/arch.cj "$b"

# ── NC8 · M16：depth 解析完就丢──
b="$(md5_of src/graph/render.cj)"
python3 - <<'PY'
p = "src/graph/render.cj"
s = open(p, encoding="utf-8").read()
old = '''        if (maxDepth > 0 && dirDepthOf(f.relPath) > maxDepth) {'''
new = '''        if (false && maxDepth > 0 && dirDepthOf(f.relPath) > maxDepth) {'''
assert old in s, "NC8 锚点失配"
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
check "NC8 M16 depth 是死参数" testFullGraphJsonHonoursDepthAndDisclosesCut src/graph/render.cj "$b"

# ── NC9 · M9：块注释不再进状态机──
b="$(md5_of src/graph/extract.cj)"
python3 - <<'PY'
p = "src/graph/extract.cj"
s = open(p, encoding="utf-8").read()
old = '''            if (b == 47 && i + 1 < n && line[i + 1] == 42) {
                match (findSubstr(line[i + 2..], "*/")) {
                    case Some(rel) => i = i + 2 + rel + 2; continue
                    case None => state = 3; break
                }
            }'''
new = '''            if (false && b == 47 && i + 1 < n && line[i + 1] == 42) {
                match (findSubstr(line[i + 2..], "*/")) {
                    case Some(rel) => i = i + 2 + rel + 2; continue
                    case None => state = 3; break
                }
            }'''
assert old in s, "NC9 锚点失配"
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
check "NC9 M9 块注释不剥离" testInlineHashDashAndBlockCommentsAreStripped src/graph/extract.cj "$b"

# ── NC10 · M8：C 形态兜底重新对所有语言生效──
b="$(md5_of src/graph/extract.cj)"
python3 - <<'PY'
p = "src/graph/extract.cj"
s = open(p, encoding="utf-8").read()
old = '''    if (lang != "c") {
        return None
    }'''
new = '''    if (false) {
        return None
    }'''
assert old in s, "NC10 锚点失配"
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
check "NC10 M8 假函数符号" testCStyleFuncNameIsRestrictedToC src/graph/extract.cj "$b"

# ── NC11 · M4：两个含义又共用一个 files 键──
b="$(md5_of src/graph/confidence_render.cj)"
python3 - <<'PY'
p = "src/graph/confidence_render.cj"
s = open(p, encoding="utf-8").read()
old = '''    Json.set(o, "penaltyByFile", JArr(fl))'''
new = '''    Json.set(o, "files", JArr(fl))'''
assert old in s, "NC11 锚点失配"
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
check "NC11 M4 罚分表被静默覆盖" testConfidenceJsonKeySetIsStable src/graph/confidence_render.cj "$b"

# ── NC12 · M13：themes 里去掉 panel（token 表缺键）──
b="$(md5_of src/graph/archscene.cj)"
python3 - <<'PY'
p = "src/graph/archscene.cj"
s = open(p, encoding="utf-8").read()
n = s.count('Json.set(dark, "panel", Json.of("#131e35"))')
assert n == 1, "NC12 锚点失匹配数=%d" % n
s = s.replace('Json.set(dark, "panel", Json.of("#131e35"))',
              'let _noPanel = 1', 1)
open(p, "w", encoding="utf-8").write(s)
PY
check "NC12 M13 token 表缺 panel" testSceneExportIsDeterministic src/graph/archscene.cj "$b"

# ── NC13 · L14：normalizePath 又丢前导 ..──
b="$(md5_of src/util/paths.cj)"
python3 - <<'PY'
p = "src/util/paths.cj"
s = open(p, encoding="utf-8").read()
old = '''        if (part == "..") {
            if (stack.isEmpty()) {
                leadingUps += 1
                continue
            }
            stack.remove(at: stack.size - 1)
            continue
        }'''
new = '''        if (part == "..") {
            if (!stack.isEmpty()) {
                stack.remove(at: stack.size - 1)
            }
            continue
        }'''
assert old in s, "NC13 锚点失配"
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
check "NC13 L14 前导 .. 被抹掉" testNormalizePathKeepsLeadingDotDots src/util/paths.cj "$b"

# ── NC14 · M3：C 前置声明又被报成空类型──
b="$(md5_of src/graph/confidence_detect.cj)"
python3 - <<'PY'
p = "src/graph/confidence_detect.cj"
s = open(p, encoding="utf-8").read()
old = '''        if (isForwardDeclaration(n.text)) {
            continue
        }'''
new = '''        if (false) {
            continue
        }'''
assert old in s, "NC14 锚点失配"
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
check "NC14 M3 前置声明误报" testForwardDeclarationIsNotReportedAsEmptyType src/graph/confidence_detect.cj "$b"

# ── NC15 · L11：stash 又按 \n 切行（多条目只解析第一条）──
b="$(md5_of src/kernel/git.cj)"
python3 - <<'PY'
p = "src/kernel/git.cj"
s = open(p, encoding="utf-8").read()
old = '''    let toks = r.stdout.split(NUL)
    var ti: Int64 = 0
    while (ti + 2 < Int64(toks.size)) {
        let idx = toks[ti]
        let subject = toks[ti + 1]
        let date = toks[ti + 2]
        ti += 3'''
new = '''    let toks = r.stdout.split(NUL)
    var ti: Int64 = 0
    while (ti + 2 < Int64(toks.size) && ti == 0) {
        let idx = toks[ti]
        let subject = toks[ti + 1]
        let date = toks[ti + 2]
        ti += 3'''
assert old in s, "NC15 锚点失配"
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
check "NC15 L11 只解析第一条 stash" testListStashesParsesEveryEntry src/kernel/git.cj "$b"

# ── NC16 · L13：runeFromUtf8At 又收 overlong──
b="$(md5_of src/util/json.cj)"
python3 - <<'PY'
p = "src/util/json.cj"
s = open(p, encoding="utf-8").read()
old = '''    if (c0 >= 0xc2u8 && c0 < 0xe0u8) {'''
new = '''    if (c0 >= 0xc0u8 && c0 < 0xe0u8) {'''
assert old in s, "NC16 锚点失配"
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
check "NC16 L13 overlong 被洗白" testRuneFromUtf8AtRejectsOverlongAndSurrogates src/util/json.cj "$b"

# ── NC17 · M15：渲染纯函数改回只认进程级语言（传了 lang 不生效）──
b="$(md5_of src/cli/cli.cj)"
python3 - <<'PY'
p = "src/cli/cli.cj"
s = open(p, encoding="utf-8").read()
old = '''func tl(lang: String, en: String, zh: String): String {
    return if (isEnglish(lang)) { en } else { zh }
}'''
new = '''func tl(lang: String, en: String, zh: String): String {
    return pickText(en, zh)
}'''
assert old in s, "NC17 锚点失配"
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
check "NC17 M15 lang 入参不生效" testChromeRenderersHonourEnglish src/cli/cli.cj "$b"

# ── NC18 · L9：env 覆盖不经 languageError──
b="$(md5_of src/kernel/config.cj)"
python3 - <<'PY'
p = "src/kernel/config.cj"
s = open(p, encoding="utf-8").read()
old = '''                let want = v.trimAscii()
                if (!SUPPORTED_LANGUAGES.contains(want)) {'''
new = '''                let want = v.trimAscii()
                if (false && !SUPPORTED_LANGUAGES.contains(want)) {'''
assert old in s, "NC18 锚点失配"
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
check "NC18 L9 任意语言值被静默接受" testEnvLanguageOverrideRejectsUnsupported src/kernel/config.cj "$b"

# ── NC19 · M2：批失败不降级（全部失败仍报 astUsed）──
# ⚠️ 这条**只能源码级**：路径需要「ast-grep 能跑且每个批次都失败」，
# 而沙箱里要么没装 ast-grep、要么全是仓颉文件（无 tree-sitter 语法）⇒ 批次数为 0，
# 分支根本进不去。所以判据是 __lintAstBatchFailureDegradesInsteadOfClaimingSuccess
# （源码级保证，已在测试注释里如实标注边界）。
b="$(md5_of src/graph/confidence_ast.cj)"
python3 - <<'PY'
p = "src/graph/confidence_ast.cj"
s = open(p, encoding="utf-8").read()
old = '''    if (totalBatches > 0 && failedBatches == totalBatches) {'''
new = '''    if (false) {'''
assert old in s, "NC19 锚点失配"
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
check "NC19 M2 批失败不降级" __lintAstBatchFailureDegradesInsteadOfClaimingSuccess src/graph/confidence_ast.cj "$b"

echo "== 负控结果：失败项 ${FAILS} =="
[ "$FAILS" -eq 0 ] || exit 1
exit 0
