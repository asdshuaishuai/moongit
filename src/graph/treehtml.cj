// graph/treehtml.cj — 代码图谱导出（函数级 × 置信度，deepOrca 式三列）。
//
// 【形态】deepOrca SymbolGraphView：引用方 | 焦点 | 被调 三列卡片，
// 点击卡片重新聚焦（re-center），band 渐进披露；叠加 code-review-graph 的
// 「函数级调用图 × 评审异常」：置信度疑点按所在函数聚合，异常函数挂
// 权重徽标（特殊色只给异常——红高危/橙警示，与身份色分离）。
//
// 【代码高亮】焦点函数的源码内嵌（截 40 行），仓颉 tokenizer 四类着色
// （关键字/字符串/注释/数字），深浅主题各一组 token。
//
// 【数据】`graph tree --json` 契约 + functionGraphData（函数/调用边/实码）。
package moongit.graph

import std.collection.*
import moongit.util.*

// MARK: - 函数级图谱数据（代码图谱 × 置信度的结合点）

/// 函数级节点/调用边/异常实码。边 = 「函数体 → 被调函数」（词法近似：
/// 函数体内自由调用按名匹配全局定义）；置信度 findings 按所在函数聚合，
/// 异常函数内嵌实码片段（截 40 行，页面点击即看）。
func functionGraphData(graph: CodeGraph, findings: ConfidenceReport): JsonValue {
    let idx = graph.symbolIndex()
    let out = Json.obj()
    let fns = ArrayList<JsonValue>()
    let edgeAgg = HashMap<String, Int64>()
    let byFile = HashMap<String, ArrayList<JsonValue>>()
    for (f in findings.findings) {
        let o = Json.obj()
        Json.set(o, "line", Json.of(f.line))
        Json.set(o, "weight", Json.of(flawWeight(f.kind)))
        Json.set(o, "kind", Json.of(flawId(f.kind)))
        match (byFile.get(f.file)) {
            case Some(list) => list.add(o)
            case None => byFile[f.file] = ArrayList<JsonValue>([o])
        }
    }
    let snippets = Json.obj()
    for (fe in graph.files) {
        let content = readFileText(graph.root + "/" + fe.relPath)
        let srcLines = ArrayList<String>()
        match (content) {
            case Some(t) =>
                for (l in t.split("\n")) { srcLines.add(l) }
            case None => ()
        }
        let fileFindings = byFile.get(fe.relPath)
        let syms = fe.symbols
        var i: Int64 = 0
        while (i < Int64(syms.size)) {
            let s = syms[i]
            let bodyStart = s.line
            let bodyEnd = if (i + 1 < Int64(syms.size)) { syms[i + 1].line - 1 } else { Int64(srcLines.size) }
            let id = "f:" + fe.relPath + ":" + s.line.toString() + ":" + s.name
            let fd = ArrayList<JsonValue>()
            var maxW: Int64 = 0
            match (fileFindings) {
                case Some(list) =>
                    for (o in list) {
                        let ln = Json.intAt(o, "line", 0)
                        if (ln >= bodyStart && ln <= bodyEnd) {
                            fd.add(o)
                            let w = Json.intAt(o, "weight", 0)
                            if (w > maxW) { maxW = w }
                        }
                    }
                case None => ()
            }
            var j = bodyStart - 1
            while (j < bodyEnd && j < Int64(srcLines.size)) {
                let stripped = srcLines[j]
                if (!stripped.isEmpty()) {
                    for ((cname, _) in freeCallsIn(stripped)) {
                        if (cname == s.name) { continue }
                        match (idx.get(cname)) {
                            case Some(defs) =>
                                if (Int64(defs.size) > 0) {
                                    let (dfile, ddecl) = defs[0]
                                    let calleeId = "f:" + dfile + ":" + ddecl.line.toString() + ":" + cname
                                    if (calleeId != id) {
                                        let ek = id + "=>" + calleeId
                                        match (edgeAgg.get(ek)) {
                                            case Some(v) => edgeAgg[ek] = v + 1
                                            case None => edgeAgg[ek] = 1
                                        }
                                    }
                                }
                            case None => ()
                        }
                    }
                }
                j += 1
            }
            let o = Json.obj()
            Json.set(o, "id", Json.of(id))
            Json.set(o, "file", Json.of(fe.relPath))
            Json.set(o, "name", Json.of(s.name))
            Json.set(o, "kind", Json.of(symKindId(s.kind)))
            Json.set(o, "line", Json.of(s.line))
            Json.set(o, "findings", JArr(fd))
            Json.set(o, "weight", Json.of(maxW))
            var code = StringBuilder()
            var cl = bodyStart - 1
            while (cl < bodyEnd && cl < Int64(srcLines.size) && cl < bodyStart + 39) {
                code.append(srcLines[cl]); code.append("\n")
                cl += 1
            }
            Json.set(snippets, id, Json.of(code.toString()))
            fns.add(o)
            i += 1
        }
    }
    let sorted = ArrayList<(String, Int64)>()
    for ((ek, w) in edgeAgg) { sorted.add((ek, w)) }
    insertionSortBy(sorted, { a, b => a[0] < b[0] })
    let ea = ArrayList<JsonValue>()
    for (p in sorted) {
        let segs = p[0].split("=>")
        if (segs.size == 2) {
            let e = Json.obj()
            Json.set(e, "from", Json.of(segs[0]))
            Json.set(e, "to", Json.of(segs[1]))
            Json.set(e, "w", Json.of(p[1]))
            ea.add(e)
        }
    }
    Json.set(out, "functions", JArr(fns))
    Json.set(out, "functionEdges", JArr(ea))
    Json.set(out, "codeSnippets", snippets)
    return out
}

// MARK: - HTML 交付物（deepOrca 式三列）

func langAttr(en: Bool): String {
    return if (en) { "en" } else { "zh-CN" }
}

public func treeCanvasHtml(graph: CodeGraph, depth: Int64, en: Bool, findings: ConfidenceReport): String {
    let root = fullGraphJson(graph, depth)
    Json.set(root, "functionGraph", functionGraphData(graph, findings))
    let json = jsonSafeForEmbed(Json.pretty(root))
    let title = if (en) { "Code Graph" } else { "代码图谱" }
    let sub = if (en) { "function-level · lexical · deterministic" } else { "函数级 · 词法索引 · 确定性" }
    let search = if (en) { "focus a symbol…" } else { "聚焦符号，如 parseFlags" }
    let focusWord = if (en) { "FOCUS" } else { "焦点" }
    let codeWord = if (en) { "SOURCE" } else { "源码" }
    let langTag = if (en) { "en" } else { "zh-CN" }
    let sb = StringBuilder()
    sb.append("<!DOCTYPE html>\n<html lang=\"${langTag}\">\n<head>\n<meta charset=\"UTF-8\">\n")
    sb.append("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n")
    sb.append("<meta name=\"generator\" content=\"moonGit graph tree (Cangjie engine, deterministic layout)\">\n")
    sb.append("<title>${title} · ${graph.files.size} files</title>\n")
    sb.append("""
<style>
:root, body.dark {
  /* 身份 ramp（三列身份 + 中性面）——引用方紫 · 焦点蓝 · 被调青 */
  --hue-in:#a78bfa; --hue-focus:#38bdf8; --hue-out:#2dd4bf;
  --bg:#0b1120; --bg2:#0f172a; --text:#e2e8f0; --muted:#8b9bb4;
  --border:#24334d; --card:#111c33; --code-bg:#0a101e;
  /* 特殊色（只给异常，不参与身份）——高危红 · 警示橙 */
  --bad:#f87171; --warn:#fbbf24;
}
body.light {
  --hue-in:#7c3aed; --hue-focus:#0284c7; --hue-out:#0d9488;
  --bg:#f6f8fb; --bg2:#ffffff; --text:#0f172a; --muted:#64748b;
  --border:#d5deeb; --card:#ffffff; --code-bg:#f1f5f9;
  --bad:#dc2626; --warn:#d97706;
}
* { margin:0; padding:0; box-sizing:border-box; }
body { background:var(--bg); color:var(--text); font:13px/1.5 -apple-system,'SF Pro Text','PingFang SC','Microsoft YaHei',sans-serif; }
#bar { position:sticky; top:0; z-index:10; display:flex; gap:10px; align-items:center;
  padding:10px 16px; background:var(--bg2); border-bottom:1px solid var(--border); }
#bar .title { font-weight:700; }
#bar .sub { color:var(--muted); font-size:11px; }
#bar input { flex:0 0 260px; background:var(--card); border:1px solid var(--border);
  color:var(--text); border-radius:8px; padding:5px 10px; outline:none; }
#cols { display:grid; grid-template-columns:1fr 1fr 1fr; gap:18px; padding:18px; max-width:1500px; margin:0 auto; }
#focus-wrap { max-width:1500px; margin:0 auto; padding:0 18px 18px; }
#focus-wrap .panel { background:var(--card); border:1px solid var(--border); border-radius:12px; padding:14px; }
#focus-name { font-size:17px; font-family:ui-monospace,Menlo,monospace; display:inline-block;
  border:1.5px solid var(--hue-focus); border-radius:9px; padding:3px 10px; margin-bottom:6px; }
#focus-meta { color:var(--muted); font-size:12px; margin-bottom:10px; }
#focus-findings { margin-bottom:10px; }
#focus-code { background:var(--code-bg); border:1px solid var(--border); border-radius:9px;
  padding:12px; overflow:auto; max-height:420px;
  font:12px/1.6 ui-monospace,Menlo,monospace; white-space:pre; }
.col h3 { font-size:11px; letter-spacing:1px; color:var(--muted); text-transform:uppercase;
  padding-bottom:6px; margin-bottom:8px; border-bottom:2px solid; }
.card { position:relative; background:var(--card); border:1px solid var(--border);
  border-radius:9px; padding:8px 10px; margin-bottom:8px; cursor:pointer; }
.card:hover { border-color:var(--hue-focus); }
.card .dot { display:inline-block; width:7px; height:7px; border-radius:50%; margin-right:6px; }
.card .nm { font-family:ui-monospace,Menlo,monospace; font-size:12px; }
.card .meta { display:block; color:var(--muted); font-size:10px; margin-top:2px;
  font-family:ui-monospace,Menlo,monospace; word-break:break-all; }
.card .w { position:absolute; right:8px; top:8px; color:var(--muted); font-size:10px; }
.badge { position:absolute; right:8px; bottom:8px; color:#fff; font-size:10px;
  font-weight:700; border-radius:999px; padding:1px 7px; }
.more { background:none; border:none; color:var(--muted); cursor:pointer; font-size:11px; padding:4px 0; }
.more:hover { color:var(--hue-focus); }
.none { color:var(--muted); font-size:11px; padding:4px 0; }
/* 语法高亮四类 token：关键字/字符串/注释/数字（深浅主题各一组） */
body.dark .k { color:#c084fc; } body.dark .s { color:#86efac; } body.dark .c { color:#64748b; } body.dark .n { color:#fbbf24; }
body.light .k { color:#7c3aed; } body.light .s { color:#16a34a; } body.light .c { color:#94a3b8; } body.light .n { color:#b45309; }
</style>
</head>
<body>
<header id="bar"><span class="title">${title}</span><span class="sub">${sub} · ${graph.files.size} files</span><input id="q" placeholder="${search}"></header>
<div id="focus-wrap"><div class="panel">
  <h2 id="focus-name">—</h2>
  <div id="focus-meta"></div>
  <div id="focus-findings"></div>
  <h3>${codeWord}</h3>
  <pre id="focus-code"></pre>
</div></div>
<div id="cols">
  <section class="col"><h3 id="col-in"></h3><div id="col-in-body"></div></section>
  <section class="col"><h3 id="col-focus">${focusWord}</h3><div id="col-focus-body"></div></section>
  <section class="col"><h3 id="col-out"></h3><div id="col-out-body"></div></section>
</div>
<script>
window.__CODEGRAPH__ = """)
    sb.append(json)
    sb.append(";\n</script>\n<script>\n")
    sb.append(codegraphDriverJs(en))
    sb.append("\n</script>\n</body>\n</html>\n")
    return sb.toString()
}

/// 驱动：deepOrca 式三列（引用方 | 焦点 | 被调），DOM 卡片 + band 渐进披露，
/// 点击卡片重新聚焦；焦点面板带置信度疑点与语法高亮源码。零随机。
func codegraphDriverJs(en: Bool): String {
    let refsIn = if (en) { "REFERENCED BY" } else { "引用方" }
    let refsOut = if (en) { "CALLEES / IMPACT" } else { "被调 / 影响" }
    let symsWord = if (en) { "symbols" } else { "符号" }
    let noneWord = if (en) { "no references" } else { "无引用" }
    let findingsWord = if (en) { "CONFIDENCE FINDINGS" } else { "置信度疑点" }
    let codeWord = if (en) { "SOURCE" } else { "源码" }
    let cleanWord = if (en) { "no findings — clean" } else { "无疑点——干净" }
    let anomalyWord = if (en) { "处异常" } else { "处异常" }
    let moreWord = if (en) { "more…" } else { "展开更多…" }
    // 本地化文案以 JS 常量注入
    let constJs = "const SYMS = " + jsStr(symsWord) + ";\n"
        + "const REFS_IN = " + jsStr(refsIn) + ";\n"
        + "const REFS_OUT = " + jsStr(refsOut) + ";\n"
        + "const NONE = " + jsStr(noneWord) + ";\n"
        + "const FINDINGS_WORD = " + jsStr(findingsWord) + ";\n"
        + "const CODE_WORD = " + jsStr(codeWord) + ";\n"
        + "const CLEAN = " + jsStr(cleanWord) + ";\n"
        + "const ANOMALY = " + jsStr(anomalyWord) + ";\n"
        + "const MORE = " + jsStr(moreWord) + ";\n"
    // 三列身份色（引用方紫 · 焦点蓝 · 被调青）与特殊色（异常红 / 警示橙）分离
    let hueJs = "const HUE = { sin:'#a78bfa', focus:'#38bdf8', out:'#2dd4bf', bad:'#f87171', warn:'#fbbf24' };\n"
    return constJs + hueJs + """
'use strict';
const D = window.__CODEGRAPH__;
const FG = D.functionGraph || { functions: [], functionEdges: [], codeSnippets: {} };
// —— 索引 ——
const FN = {};
FG.functions.forEach(function (f) { FN[f.id] = f; });
const IN_EDGE = {}; const OUT_EDGE = {};
FG.functionEdges.forEach(function (e) {
  (OUT_EDGE[e.from] = OUT_EDGE[e.from] || []).push([e.to, e.w]);
  (IN_EDGE[e.to] = IN_EDGE[e.to] || []).push([e.from, e.w]);
});
// —— 仓颉语法高亮（关键字/字符串/注释/数字，深浅主题用 CSS token）——
const KW = new Set(('package import class struct enum interface extend func let var const match case '
  + 'return try catch throw true false this super init override where in as is spawn '
  + 'public private internal protected static abstract open').split(' '));
function hl(code) {
  let out = '';
  let i = 0; const n = code.length;
  while (i < n) {
    const ch = code[i];
    if (ch === '/' && code[i + 1] === '/') {
      let j = code.indexOf(String.fromCharCode(10), i); if (j < 0) { j = n; }
      out += '<span class="c">' + esc(code.slice(i, j)) + '</span>'; i = j; continue;
    }
    if (ch === '"' || ch === "'") {
      let j = i + 1;
      while (j < n && code[j] !== ch) { if (code[j] === String.fromCharCode(92)) { j += 1; } j += 1; }
      out += '<span class="s">' + esc(code.slice(i, Math.min(j + 1, n))) + '</span>'; i = j + 1; continue;
    }
    if (/[0-9]/.test(ch)) {
      let j = i;
      while (j < n && /[0-9a-fA-FxX_.]/.test(code[j])) { j += 1; }
      out += '<span class="n">' + esc(code.slice(i, j)) + '</span>'; i = j; continue;
    }
    if (/[A-Za-z_]/.test(ch)) {
      let j = i;
      while (j < n && /[A-Za-z0-9_]/.test(code[j])) { j += 1; }
      const w = code.slice(i, j);
      out += KW.has(w) ? '<span class="k">' + esc(w) + '</span>' : esc(w);
      i = j; continue;
    }
    out += esc(ch); i += 1;
  }
  return out;
}
function esc(s) { return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;'); }
// —— 焦点状态 ——
let focus = FG.functions.length > 0 ? FG.functions[0].id : '';
function setFocus(id) { if (FN[id]) { focus = id; render(); } }
// —— 渲染：三列 + 焦点面板（band 渐进披露）——
const BAND = 16; let bandIn = BAND; let bandOut = BAND;
function render() {
  const f = FN[focus];
  const ins = (IN_EDGE[focus] || []).slice().sort(function (a, b) { return b[1] - a[1]; });
  const outs = (OUT_EDGE[focus] || []).slice().sort(function (a, b) { return b[1] - a[1]; });
  setCol('col-in', HUE.sin, REFS_IN, ins.length);
  const li = document.getElementById('col-in-body');
  li.innerHTML = '';
  ins.slice(0, bandIn).forEach(function (e) { li.appendChild(chip(e[0], e[1], HUE.sin)); });
  if (ins.length > bandIn) { li.appendChild(moreBtn(ins.length - bandIn, function () { bandIn += 24; render(); })); }
  if (ins.length === 0) { li.innerHTML = '<div class="none">' + NONE + '</div>'; }
  // 焦点卡：元数据 + 置信度徽标（特殊色只给异常）+ 疑点 + 高亮源码
  const fd = f.findings || [];
  let fw = 0; fd.forEach(function (d) { fw = Math.max(fw, d.weight); });
  document.getElementById('focus-name').textContent = f.name;
  document.getElementById('focus-name').style.borderColor =
    fw >= 10 ? HUE.bad : fw >= 6 ? HUE.warn : HUE.focus;
  document.getElementById('focus-meta').textContent = f.file + ':' + f.line + ' · ' + f.kind +
    (fd.length > 0 ? ' · ⚠' + fd.length + ' ' + ANOMALY : ' · ' + CLEAN);
  const fl = document.getElementById('focus-findings');
  fl.innerHTML = '';
  fd.forEach(function (d) {
    const row = document.createElement('div'); row.className = 'finding';
    const wc = fw >= 10 ? 'bad' : fw >= 6 ? 'warn' : 'muted';
    row.innerHTML = '<span class="' + wc + '">⚠' + d.weight + '</span><span class="k">' + esc(d.kind) + ' @ L' + d.line + '</span>';
    fl.appendChild(row);
  });
  if (fd.length === 0) { fl.innerHTML = '<div class="none">' + CLEAN + '</div>'; }
  const codeEl = document.getElementById('focus-code');
  codeEl.innerHTML = hl(FG.codeSnippets[f.id] || '');
  // 右列
  setCol('col-out', HUE.out, REFS_OUT, outs.length);
  const lo = document.getElementById('col-out-body');
  lo.innerHTML = '';
  outs.slice(0, bandOut).forEach(function (e) { lo.appendChild(chip(e[0], e[1], HUE.out)); });
  if (outs.length > bandOut) { lo.appendChild(moreBtn(outs.length - bandOut, function () { bandOut += 24; render(); })); }
  if (outs.length === 0) { lo.innerHTML = '<div class="none">' + NONE + '</div>'; }
}
function chip(id, w, hue) {
  const f = FN[id];
  const el = document.createElement('div'); el.className = 'card';
  const n = f && f.findings ? f.findings.length : 0;
  const fw = f && f.weight ? f.weight : 0;
  const bc = fw >= 10 ? 'bad' : fw >= 6 ? 'warn' : '';
  el.innerHTML = '<span class="dot" style="background:' + hue + '"></span><span class="nm">' + esc(f ? f.name : id) +
    '</span><span class="meta">' + (f ? f.file + ':' + f.line : '') + '</span>' +
    (n > 0 ? '<span class="badge ' + bc + '">⚠' + n + '</span>' : '') +
    '<span class="w">×' + w + '</span>';
  el.addEventListener('click', function () { setFocus(id); window.scrollTo({ top: 0, behavior: 'smooth' }); });
  return el;
}
function moreBtn(n, fn) {
  const b = document.createElement('button'); b.className = 'more';
  b.textContent = n + ' ' + MORE; b.addEventListener('click', fn); return b;
}
function setCol(id, hue, title, n) {
  const el = document.getElementById(id);
  el.textContent = title + ' (' + n + ')';
  el.style.borderBottomColor = hue;
}
"""
}
