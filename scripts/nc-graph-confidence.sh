#!/bin/sh
# scripts/nc-graph-confidence.sh — 负控：CodeGraph / 置信度判据必须能被**真缺陷**打红。
#
# 纪律（AGENTS.md 不变量 66 / 112 / 120）：
#   · 每个变体注入后**自证文件真的变了**（md5 前后比对）——否则报「注入未生效」，
#     而不是「判据无效」；这两种原因的修法完全相反；
#   · 还原挂 trap EXIT，任何中途退出都还原；还原后核对内容复原；
#   · 区分「判据没红」与「编译失败」—— 编译失败不是判据抓到了。
#
# 用法： sh scripts/nc-graph-confidence.sh
# 前置：需仓颉工具链（脚本会尝试自动 source envsetup；SDKROOT 可用环境变量覆盖）。

set +u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# envsetup 自身引用了可能未定义的变量（DYLD_LIBRARY_PATH）⇒ 这段必须在 set -u 之前
if [ -z "${CANGJIE_HOME:-}" ] && [ -f "$HOME/.local/share/cangjie/current/envsetup.sh" ]; then
  # shellcheck disable=SC1091
  . "$HOME/.local/share/cangjie/current/envsetup.sh"
fi
set -u
# ⚠️ **不能**写 `${SDKROOT:-…}`：envsetup.sh 会在 SDKROOT 未设时把它设成 Xcode 全量 SDK
# （macOS 26/27 的 libSystem.tbd 缺 arm64-macos 声明 ⇒ ld64.lld 报 undefined symbol: _strtod）。
# 必须在 source 之后**无条件**改用极简兼容 SDK。
export SDKROOT="${MOONGIT_SDKROOT:-$HOME/.local/share/sdks/MacOSX.minimal/latest}"
export DEEPGIT_HOME="${DEEPGIT_HOME:-/tmp/dg-nc-graph-home-$$}"

SB="$(mktemp -d "${TMPDIR:-/tmp}/moonGit-nc-graph.XXXXXX")"
FILES="src/graph/confidence.cj src/graph/confidence_detect.cj src/graph/extract.cj src/graph/archhtml.cj src/graph/archscene.cj"

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

# run_case <用例名> → 0 通过 / 1 失败 / 2 未判定（编译失败或缺结果）
RC=0
run_case() {
  cjpm test --parallel 1 --filter "$1" > "$SB/out.log" 2>&1
  RC=$?
  sed -e 's/\x1b\[[0-9;]*m//g' "$SB/out.log" > "$SB/clean.log"
  if grep -qE "FAILED \] CASE: $1 " "$SB/clean.log"; then return 1; fi
  if grep -qE "PASSED \] CASE: $1 " "$SB/clean.log"; then return 0; fi
  return 2
}

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
    printf '✅ %s：注入真缺陷 → %s 变红（且注入确实生效）\n' "$label" "$name"
  elif [ "$r" = "0" ]; then
    printf '❌ %s：注入真缺陷 → %s 仍绿 ⇒ 该判据是摆设\n' "$label" "$name"
    FAILS=$((FAILS + 1))
  else
    printf '❌ %s：%s 未判定（编译失败或未跑到该用例）—— 红的原因不是判据\n' "$label" "$name"
    printf '   —— 诊断：rc=%s，关键行 ——\n' "$RC"
    grep -m3 -E "error:|Error:|^\[.*FAILED" "$SB/clean.log" | sed 's/^/      /'
    FAILS=$((FAILS + 1))
  fi
  restore_all
}

echo "== 负控：graph 置信度 / 图谱判据 =="

# ── NC1 · import 解析退回「取首段」（原缺陷）──
b="$(md5_of src/graph/extract.cj)"
python3 - <<'PY'
p = "src/graph/extract.cj"
s = open(p, encoding="utf-8").read()
old = '''        let toks = tokenize(t)
        var cand = ""
        var i: Int64 = 1
        while (i < Int64(toks.size)) {
            let tk = toks[i]
            if (tk == "as") { break }   // Swift 别名 `import X as Y` → 取 X
            cand = tk
            i += 1
        }
        if (!cand.isEmpty() && cand != "_" && cand != "}") { return cand }
        return ""'''
new = '''        let toks = tokenize(t)
        var cand = ""
        if (Int64(toks.size) >= 2) { cand = toks[1] }
        if (!cand.isEmpty() && cand != "_" && cand != "}") { return cand }
        return ""'''
assert old in s, "NC1 锚点失配"
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
check "NC1 import 取首段" testImportSegmentResolution src/graph/extract.cj "$b"

# ── NC2 · TODO 判定退回「出现过这个词」──
b="$(md5_of src/graph/confidence_detect.cj)"
python3 - <<'PY'
p = "src/graph/confidence_detect.cj"
s = open(p, encoding="utf-8").read()
start = s.index("func containsTodo(line: String): Bool {")
end = s.index("\n}\n", start) + len("\n}\n")
new = ('func containsTodo(line: String): Bool {\n'
       '    return line.contains("TODO") || line.contains("FIXME")'
       ' || line.contains("HACK") || line.contains("XXX")\n}\n')
assert s[start:end] != new, "NC2 未改变内容"
open(p, "w", encoding="utf-8").write(s[:start] + new + s[end:])
PY
check "NC2 TODO 退回子串匹配" testTodoMarkerShape src/graph/confidence_detect.cj "$b"

# ── NC3 · 排序退回「并列判等」（不确定）──
b="$(md5_of src/graph/confidence.cj)"
python3 - <<'PY'
p = "src/graph/confidence.cj"
s = open(p, encoding="utf-8").read()
old = '''    let ia = flawId(a.kind)
    let ib = flawId(b.kind)
    if (ia != ib) { return ia < ib }
    return a.symbol < b.symbol'''
new = '''    return false'''
assert old in s, "NC3 锚点失配"
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
check "NC3 排序并列判等" testFindingsOrderIsTotalAndDeterministic src/graph/confidence.cj "$b"

# ── NC4 · 孤儿检测忽略「使用证据」──
b="$(md5_of src/graph/confidence_detect.cj)"
python3 - <<'PY'
p = "src/graph/confidence_detect.cj"
s = open(p, encoding="utf-8").read()
old = "            if (graph.referencedNames.contains(s.name)) { continue }"
new = "            if (s.name.size < 0) { continue }"
assert old in s, "NC4 锚点失配"
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
check "NC4 孤儿不用使用证据" testOrphanIsSymbolLevel src/graph/confidence_detect.cj "$b"

# ── NC5 · 词法路径不再产出深嵌套 / 魔法数 ──
b="$(md5_of src/graph/confidence_detect.cj)"
python3 - <<'PY'
p = "src/graph/confidence_detect.cj"
s = open(p, encoding="utf-8").read()
a1 = "if (maxRel > CONF_DEEP_NESTING) {"
b1 = "if (maxRel > 999999) {"
a2 = "if (bodyMagic >= 3) {"
b2 = "if (bodyMagic >= 999999) {"
assert a1 in s and a2 in s, "NC5 锚点失配"
s = s.replace(a1, b1, 1).replace(a2, b2, 1)
open(p, "w", encoding="utf-8").write(s)
PY
check "NC5 词法路径不报深嵌套/魔法数" testLexicalDeepNestingAndMagic src/graph/confidence_detect.cj "$b"

# ── NC6 · 分数退回「与规模相关」的旧公式（100 − 惩罚/√文件数）──
b="$(md5_of src/graph/confidence.cj)"
python3 - <<'PY'
p = "src/graph/confidence.cj"
s = open(p, encoding="utf-8").read()
old = '''    let density = Float64(penalty) / Float64(n)
    let s = CONF_SCORE_SCALE
    var score = Int64(100.0 * s / (s + density))'''
new = '''    var g = Float64(n) / 2.0
    if (g < 1.0) { g = 1.0 }
    var it = 0
    while (it < 8) { g = (g + Float64(n) / g) / 2.0; it += 1 }
    var score = 100 - Int64(Float64(penalty) / g)'''
assert old in s, "NC6 锚点失配"
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
check "NC6 分数退回规模相关公式" testScoreIsSizeInvariantAndMonotone src/graph/confidence.cj "$b"

# ── NC7 · 架构图面板退回「无条件用 m.files + 幻影字面量 '》'.length」──
b="$(md5_of src/graph/archhtml.cj)"
python3 - <<'PY'
p = "src/graph/archhtml.cj"
s = open(p, encoding="utf-8").read()
old = r'''    sb.append("    else { h += '<div class=\"meta\">' + escapeHtml(m.lang) + '</div>'; }\n")
    sb.append("    var stats = isArch() ? (m.files + ' ' + FILES + ' · ' + m.symbols + ' ' + SYMS + ' · ' + m.lines + ' ' + LINES) : (m.symbols + ' ' + SYMS + ' · ' + m.lines + ' ' + LINES);\n")
    sb.append("    h += '<div>' + stats + '</div>';\n")'''
new = r'''    sb.append("    else { h += '<div class=\"meta\">' + escapeHtml(m.lang) + (m.external ? '' : ' · L' + '》'.length + '</div>'); }\n")
    sb.append("    h += '<div>' + m.files + ' ' + FILES + ' · ' + m.symbols + ' ' + SYMS + ' · ' + m.lines + ' ' + LINES + '</div>';\n")'''
assert old in s, "NC7 锚点失配"
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
check "NC7 架构图面板退回缺陷写法" testBuildGraphAndImpact src/graph/archhtml.cj "$b"

# ── NC8 · 场景文件级面板退回「恒发空 out/in」──
b="$(md5_of src/graph/archscene.cj)"
python3 - <<'PY'
p = "src/graph/archscene.cj"
s = open(p, encoding="utf-8").read()
old = '''            let outs = ArrayList<JsonValue>()
            let ins = ArrayList<JsonValue>()
            for ((ea, eb, ew) in dg.edges) {
                if (ea == n.id) {
                    let d = Json.obj()
                    Json.set(d, "id", Json.of(eb))
                    Json.set(d, "w", Json.of(ew))
                    outs.add(d)
                }
                if (eb == n.id) {
                    let d = Json.obj()
                    Json.set(d, "id", Json.of(ea))
                    Json.set(d, "w", Json.of(ew))
                    ins.add(d)
                }
            }
            Json.set(po, "out", JArr(outs))
            Json.set(po, "in", JArr(ins))'''
new = '''            Json.set(po, "out", JArr(ArrayList<JsonValue>()))
            Json.set(po, "in", JArr(ArrayList<JsonValue>()))'''
assert old in s, "NC8 锚点失配"
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
check "NC8 场景文件级面板恒空 out/in" testBuildGraphAndImpact src/graph/archscene.cj "$b"

echo "== 负控结束；失败项：$FAILS =="
[ "$FAILS" = "0" ]
