// graph/treehtml.cj — 代码图谱的 Web Canvas 导出（单文件、零依赖、确定性）。
//
// 【为什么存在】架构图有 archhtml（archCanvasHtml），代码图谱此前只有
// text/json——「引擎在没有任何客户端实现的情况下也能把图谱导出来看」
// 这条承诺对代码图谱不成立。本文件补齐：`graph tree --format html`
// （默认格式，与 arch 同纪律：默认即 Web Canvas）。
//
// 【数据契约】内嵌数据就是 `graph tree --json` 的同一份 fullGraphJson
// （files[{path,lang,lines,symbols}] / referenceEdges / importEdges /
// truncated 等披露字段）——同一个命令两条出口吃同一份契约，不许漂。
//
// 【布局（确定性）】按顶层目录分列（字典序），列内文件按路径排序纵向
// 均匀排布；边 = referenceEdges 的加权贝塞尔（渐变 + 箭头 + 流光）。
// 零随机数：同仓库两次导出，渲染逐帧一致。
package moongit.graph

import std.collection.*
import moongit.util.*

/// 代码图谱交互 HTML 的入口。`depth` 语义与 `--json` 路径一致
/// （files 按深度截断，truncated/depthOmitted 如实披露）。
public func treeCanvasHtml(graph: CodeGraph, depth: Int64, en: Bool, findings: ConfidenceReport): String {
    // 数据 = tree --json 契约 + 函数级图谱（调用边 × 置信度标记 × 异常实码）
    let root = fullGraphJson(graph, depth)
    Json.set(root, "functionGraph", functionGraphData(graph, findings))
    let json = jsonSafeForEmbed(Json.pretty(root))
    let title = if (en) { "Code Graph" } else { "代码图谱" }
    let sub = if (en) { "lexical index · deterministic" } else { "词法索引 · 确定性布局" }
    let search = if (en) { "filter files…" } else { "过滤文件…" }
    let fit = if (en) { "fit" } else { "复位" }
    let theme = if (en) { "theme" } else { "主题" }
    let hint = if (en) { "click a file: symbols + refs · drag to pan · pinch to zoom" }
               else { "点击文件看符号与引用 · 拖动平移 · 滚轮缩放" }
    let sb = StringBuilder()
    sb.append("<!DOCTYPE html>\n<html lang=\"${if (en) { "en" } else { "zh-CN" }}\" data-theme=\"dark\">\n<head>\n<meta charset=\"UTF-8\">\n")
    sb.append("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n")
    sb.append("<meta name=\"generator\" content=\"moonGit graph tree (Cangjie engine, deterministic layout)\">\n")
    sb.append("<title>${title} · ${graph.files.size} files</title>\n")
    sb.append("""
<style>
:root, body.dark { --bg:#0b1120; --grid:#16233c; --text:#e2e8f0; --muted:#8b9bb4;
  --panel:#0f172acc; --border:#24334d; --accent:#38bdf8; --arrow:#5b6b85; --chip:#16233c; }
body.light { --bg:#f6f8fb; --grid:#e3e9f2; --text:#0f172a; --muted:#64748b;
  --panel:#ffffffd9; --border:#d5deeb; --accent:#0284c7; --arrow:#9aa8bd; --chip:#e9eff7; }
* { margin:0; padding:0; box-sizing:border-box; }
html, body { height:100%; overflow:hidden; }
body { background:var(--bg); color:var(--text); font:13px/1.5 -apple-system,'SF Pro Text','PingFang SC','Microsoft YaHei',sans-serif; }
#cv { position:fixed; inset:0; display:block; cursor:grab; }
#cv.drag { cursor:grabbing; }
#bar { position:fixed; top:12px; left:12px; display:flex; gap:8px; align-items:center;
  background:var(--panel); border:1px solid var(--border); border-radius:10px; padding:8px 10px;
  backdrop-filter:blur(8px); flex-wrap:wrap; max-width:calc(100vw - 24px); }
#bar .title { font-weight:700; letter-spacing:.2px; }
#bar .sub { color:var(--muted); font-size:11px; }
#bar input { background:var(--chip); border:1px solid var(--border); color:var(--text);
  border-radius:8px; padding:4px 8px; outline:none; width:170px; }
.btn { border:1px solid var(--border); background:var(--chip); color:var(--text);
  border-radius:8px; padding:4px 10px; cursor:pointer; }
.btn:hover { border-color:var(--accent); }
.chip.on { border-color:var(--accent); background:var(--accent); color:#fff; }
#hint { position:fixed; bottom:12px; left:50%; transform:translateX(-50%);
  color:var(--muted); font-size:11px; background:var(--panel); border:1px solid var(--border);
  border-radius:999px; padding:4px 14px; backdrop-filter:blur(8px); }
#panel { position:fixed; top:64px; right:12px; width:320px; max-height:calc(100vh - 90px);
  overflow:auto; background:var(--panel); border:1px solid var(--border); border-radius:12px;
  padding:14px; backdrop-filter:blur(8px); display:none; }
#panel h2 { font-size:14px; margin-bottom:2px; word-break:break-all; }
#panel .meta { color:var(--muted); font-size:12px; margin-bottom:8px; }
#panel h3 { font-size:11px; color:var(--muted); text-transform:uppercase; letter-spacing:.8px; margin:10px 0 4px; }
.sym { display:flex; gap:8px; padding:2px 4px; font-family:ui-monospace,Menlo,monospace; font-size:11px; }
.sym .k { color:var(--muted); width:46px; flex:none; }
.sym .l { color:var(--muted); margin-left:auto; }
.dep { display:flex; justify-content:space-between; gap:8px; padding:3px 6px; border-radius:6px;
  font-family:ui-monospace,Menlo,monospace; font-size:11px; cursor:pointer; }
.dep:hover { background:var(--chip); }
.dep .w { color:var(--muted); }
</style>
</head>
<body class="dark">
<canvas id="cv"></canvas>
""")
    let riskWord = if (en) { "⚠ risk functions" } else { "⚠ 异常函数" }
    let fileWord = if (en) { "files view" } else { "文件视图" }
    sb.append("<div id=\"bar\"><span class=\"title\">${title}</span><span class=\"sub\">${sub} · ${graph.files.size} files</span>")
    sb.append("<span class=\"chip on\" id=\"m-risk\">${riskWord}</span><span class=\"chip\" id=\"m-file\">${fileWord}</span>")
    sb.append("<input id=\"q\" placeholder=\"${search}\"><button class=\"btn\" id=\"fit\">${fit}</button><button class=\"btn\" id=\"th\">${theme}</button></div>\n")
    sb.append("<div id=\"hint\">${hint}</div>\n<div id=\"panel\"></div>\n<script>\nwindow.__CODEGRAPH__ = ")
    sb.append(json)
    sb.append(";\n</script>\n<script>\n")
    sb.append(codegraphDriverJs(en))
    sb.append("\n</script>\n</body>\n</html>\n")
    return sb.toString()
}

/// 驱动：布局（顶层目录分列）→ 绘制（节点/加权边/流光）→ 交互（点击面板/
/// 搜索高亮/拖动缩放/主题）。零随机：相位一律 (i+1)/(n+1)。
func codegraphDriverJs(en: Bool): String {
    let refsIn = if (en) { "referenced by" } else { "被调用" }
    let refsOut = if (en) { "calls" } else { "调用" }
    let symsWord = if (en) { "symbols" } else { "符号" }
    let noneWord = if (en) { "none" } else { "无" }
    let findingsWord = if (en) { "confidence findings" } else { "置信度疑点" }
    let codeWord = if (en) { "code" } else { "代码" }
    // 本地化文案以 JS 常量注入（驱动内直接引用）
    let constJs = "const SYMS = " + jsStr(symsWord) + ";\n"
        + "const MORE = " + jsStr(if (en) { "more…" } else { "更多…" }) + ";\n"
        + "const REFS_IN = " + jsStr(refsIn) + ";\n"
        + "const REFS_OUT = " + jsStr(refsOut) + ";\n"
        + "const NONE = " + jsStr(noneWord) + ";\n"
        + "const FINDINGS_WORD = " + jsStr(findingsWord) + ";\n"
        + "const CODE_WORD = " + jsStr(codeWord) + ";\n"
    return constJs + """
'use strict';
const D = window.__CODEGRAPH__;
const FG = D.functionGraph || { functions: [], functionEdges: [], codeSnippets: {} };
const cv = document.getElementById('cv');
let ctx = cv.getContext('2d');
let dark = true;
function C(name) { const v = getComputedStyle(document.body).getPropertyValue('--' + name).trim(); return v || '#888'; }
// —— 函数索引 ——
const FN = {}; const FLAGGED = [];
FG.functions.forEach(function (f) { FN[f.id] = f; if ((f.findings || []).length > 0) { FLAGGED.push(f); } });
FLAGGED.sort(function (a, b) { return (b.weight || 0) - (a.weight || 0); });
// —— 模式 ——
let mode = 'risk';
// —— 布局（确定性）：按文件分列，列内按 (权重降序, 名称) ——
const cols = {}; const colNames = [];
function colOf(f) {
  const dir = f.file.indexOf('/') >= 0 ? f.file.split('/')[0] : '(root)';
  if (!cols[dir]) { cols[dir] = []; colNames.push(dir); }
  return cols[dir];
}
function layoutRisk() {
  // 按文件聚簇（deepOrca 式分组收纳）：簇 = 文件盒（表头 + 异常函数堆叠），
  // 簇网格排布（每行 3 个）。f.base 此刻没赋值——列键内联计算。
  FLAGGED.forEach(function (f) {
    const base = f.file.slice(f.file.lastIndexOf('/') + 1);
    if (!cols[base]) { cols[base] = []; colNames.push(base); }
    cols[base].push(f);
  });
  colNames.sort();
  let maxRows = 1;
  colNames.forEach(function (d) { maxRows = Math.max(maxRows, cols[d].length); });
  const colW = 250, rowH = 44, padX = 60, padY = 60;
  // 簇网格：每行 3 簇；每行的 y 偏移 = 之前各行真实高度之和（行高按最高簇算）
  const perRow = 3, cw = 260, chPad = 34, rh = 36, gx = 34, gy = 40;
  const rowHs = [0];
  colNames.forEach(function (d, ci) {
    const row = Math.floor(ci / perRow);
    rowHs[row] = Math.max(rowHs[row] || 0, chPad + cols[d].length * rh + 8);
  });
  const rowsY = [padY];
  for (let r = 1; r < rowHs.length; r++) { rowsY[r] = rowsY[r - 1] + rowHs[r - 1] + gy; }
  colNames.forEach(function (d, ci) {
    const list = cols[d];
    const row = Math.floor(ci / perRow), col = ci % perRow;
    const ox = padX + col * (cw + gx), oy = rowsY[row];
    let yy = oy + chPad;
    list.forEach(function (f) {
      f.x = ox; f.y = yy; f.w = cw; f.h = 30;
      yy += rh;
    });
    headY[d] = oy; headX[d] = ox;
  });
  let wWorld = padX * 2 + perRow * (cw + gx);
  let hWorld = rowsY[rowsY.length - 1] + rowHs[rowHs.length - 1];
  return { w: wWorld, h: hWorld };
}
const headY = {}; const headX = {};
// —— 文件布局（file 模式，原文件级视图）——
const fileNodes = D.files; const byPath = {};
let fileWorld = { w: 1, h: 1 };
function layoutFile() {
  const dirs = []; const byDir = {};
  fileNodes.forEach(function (f) {
    const dir = f.path.indexOf('/') >= 0 ? f.path.split('/')[0] : '(root)';
    if (!byDir[dir]) { byDir[dir] = []; dirs.push(dir); }
    byDir[dir].push(f);
  });
  dirs.sort();
  const colW = 240, rowH = 44, padX = 60, padY = 60;
  let maxRows = 1;
  dirs.forEach(function (d) { byDir[d].sort(function (a, b) { return a.path < b.path ? -1 : 1; });
    maxRows = Math.max(maxRows, byDir[d].length); });
  dirs.forEach(function (d, ci) {
    byDir[d].forEach(function (f, fi) {
      f.x = padX + ci * colW; f.y = padY + fi * rowH; f.w = colW - 26; f.h = 32;
      f.base = f.path.slice(f.path.lastIndexOf('/') + 1);
      byPath[f.path] = f;
    });
  });
  fileWorld = { w: padX * 2 + dirs.length * colW, h: padY * 2 + maxRows * rowH };
}
layoutRisk(); layoutFile();
// —— 视口 ——
let view = { x: 0, y: 0, k: 1 };
let world = mode === 'risk' ? { w: 1, h: 1 } : fileWorld;
function worldSize() {
  if (mode === 'risk') {
    // 真实边界：取节点实际位置的最大范围（布局后调用）
    let mx = 0, my = 0;
    FLAGGED.forEach(function (f) { mx = Math.max(mx, f.x + f.w); my = Math.max(my, f.y + f.h); });
    return { w: mx + 60, h: my + 60 };
  }
  return fileWorld;
}
function fit() {
  world = worldSize();
  const k = Math.min(innerWidth / world.w, innerHeight / world.h) * 0.96;
  view.k = Math.min(Math.max(k, 0.08), 2.5);
  view.x = (innerWidth - world.w * view.k) / 2;
  view.y = (innerHeight - world.h * view.k) / 2;
}
function w2sx(x) { return x * view.k + view.x; }
function w2sy(y) { return y * view.k + view.y; }
function center(id) {
  const list = mode === 'risk' ? FLAGGED : fileNodes;
  const key = mode === 'risk' ? 'id' : 'path';
  let n = null;
  list.forEach(function (x) { if (x[key] === id) { n = x; } });
  if (n) { view.x = innerWidth / 2 - (n.x + n.w / 2) * view.k; view.y = innerHeight / 2 - (n.y + n.h / 2) * view.k; }
}
// —— 绘制 ——
let selected = null; let query = '';
function weightColor(w) { return w >= 10 ? '#f87171' : w >= 6 ? '#fbbf24' : '#94a3b8'; }
function draw(now) {
  ctx.setTransform(devicePixelRatio, 0, 0, devicePixelRatio, 0, 0);
  world = worldSize();
  ctx.fillStyle = C('bg'); ctx.fillRect(0, 0, innerWidth, innerHeight);
  if (mode === 'risk') { drawRisk(now); } else { drawFile(now); }
}
function drawRisk(now) {
  const t0 = 300;
  FG.functionEdges.forEach(function (e, i) {
    const a = FN[e.from], b = FN[e.to];
    if (!a || !b) { return; }
    if (now * 1000 < t0 + i * 8) { return; }
    const x1 = w2sx(a.x + a.w), y1 = w2sy(a.y + a.h / 2);
    const x2 = w2sx(b.x), y2 = w2sy(b.y + b.h / 2);
    const mx = (x1 + x2) / 2;
    ctx.beginPath(); ctx.moveTo(x1, y1); ctx.bezierCurveTo(mx, y1, mx, y2, x2, y2);
    ctx.strokeStyle = C('arrow'); ctx.globalAlpha = Math.min(0.2 + (e.w || 1) * 0.12, 0.8);
    ctx.lineWidth = Math.min(0.8 + (e.w || 1) * 0.4, 2.5);
    ctx.setLineDash([5, 4]); ctx.lineDashOffset = -((now * 22 + i * 5) % 9);
    ctx.stroke(); ctx.setLineDash([]); ctx.globalAlpha = 1;
  });
  const w0 = 60, colW = 250;
  FLAGGED.forEach(function (f, i) {
    const ci = colNames.indexOf(f.file.indexOf('/') >= 0 ? f.file.split('/')[0] : '(root)');
    f.colIndex = ci;
  });
  if (view.k >= 0.5) {
    colNames.forEach(function (d) {
      if (headX[d] !== undefined) {
        ctx.fillStyle = C('muted'); ctx.font = '600 ' + Math.max(10 * view.k, 8) + 'px ui-monospace,Menlo,monospace';
        ctx.textAlign = 'left'; ctx.textBaseline = 'top';
        ctx.fillText(d + ' (' + cols[d].length + ')', w2sx(headX[d]), w2sy(headY[d]));
      }
    });
  }
  FLAGGED.forEach(function (f) {
    const x = w2sx(f.x), y = w2sy(f.y), w = f.w * view.k, h = f.h * view.k;
    const dim = query !== '' && (f.name + ' ' + f.file).toLowerCase().indexOf(query) < 0;
    const w1 = f.weight || 0;
    ctx.globalAlpha = dim ? 0.18 : 1;
    ctx.fillStyle = C('panel');
    ctx.beginPath();
    const r = Math.min(6 * view.k, h / 2);
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r); ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r); ctx.arcTo(x, y, x + w, y, r); ctx.closePath();
    ctx.fill();
    ctx.strokeStyle = weightColor(w1); ctx.lineWidth = selected === f.id ? 2.2 : 1.2; ctx.stroke();
    // LOD + 裁剪：文字必须 clip 在节点框内（长函数名出框会糊满整页）；
    // 低倍率只画权重色条（文字比节点大只会糊成一团）
    ctx.save();
    ctx.beginPath(); ctx.rect(x, y, w, h); ctx.clip();
    if (view.k >= 0.45) {
      ctx.fillStyle = C('text'); ctx.font = '600 ' + Math.max(10 * view.k, 8) + 'px ui-monospace,Menlo,monospace';
      ctx.textAlign = 'left'; ctx.textBaseline = 'middle';
      ctx.fillText(f.name, x + 8, y + h / 2 - Math.max(6 * view.k, 5));
      ctx.fillStyle = C('muted'); ctx.font = Math.max(9 * view.k, 7) + 'px ui-monospace,Menlo,monospace';
      ctx.fillText(f.file.slice(f.file.lastIndexOf('/') + 1) + ':' + f.line, x + 8, y + h / 2 + Math.max(7 * view.k, 6));
    }
    // 异常标记：权重徽标（右上角，区别标记——异常函数一眼可辨）
    ctx.fillStyle = weightColor(w1);
    ctx.fillText('⚠' + (f.findings || []).length, x + w - 26 * Math.max(view.k, 0.6), y + h / 2 - Math.max(6 * view.k, 5));
    ctx.restore();
    ctx.globalAlpha = 1;
  });
}
function drawFile(now) {
  const t0 = 200;
  D.referenceEdges.forEach(function (e, i) {
    const a = byPath[e[0]], b = byPath[e[1]];
    if (!a || !b) { return; }
    if (now * 1000 < t0 + i * 10) { return; }
    const x1 = w2sx(a.x + a.w), y1 = w2sy(a.y + a.h / 2);
    const x2 = w2sx(b.x), y2 = w2sy(b.y + b.h / 2);
    const mx = (x1 + x2) / 2;
    ctx.beginPath(); ctx.moveTo(x1, y1); ctx.bezierCurveTo(mx, y1, mx, y2, x2, y2);
    ctx.strokeStyle = C('arrow'); ctx.globalAlpha = 0.55;
    ctx.lineWidth = Math.min(0.8 + (e[2] || 1) * 0.4, 2.5);
    ctx.setLineDash([6, 5]); ctx.lineDashOffset = -((now * 24 + i * 7) % 11);
    ctx.stroke(); ctx.setLineDash([]); ctx.globalAlpha = 1;
  });
  fileNodes.forEach(function (f) {
    const x = w2sx(f.x), y = w2sy(f.y), w = f.w * view.k, h = f.h * view.k;
    ctx.fillStyle = C('panel');
    ctx.beginPath();
    const r = Math.min(7 * view.k, h / 2);
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r); ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r); ctx.arcTo(x, y, x + w, y, r); ctx.closePath();
    ctx.fill(); ctx.strokeStyle = C('border'); ctx.lineWidth = 1; ctx.stroke();
    ctx.fillStyle = C('text'); ctx.font = Math.max(10 * view.k, 8) + 'px ui-monospace,Menlo,monospace';
    ctx.textAlign = 'left'; ctx.textBaseline = 'middle';
    ctx.fillText(f.base, x + 8, y + h / 2);
  });
}
// —— 面板 ——
function esc(s) { return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;'); }
function showFnPanel(id) {
  const f = FN[id]; if (!f) { return; }
  let h = '<h2>' + esc(f.name) + '</h2>';
  h += '<div class="meta">' + esc(f.file) + ':' + f.line + ' · ' + esc(f.kind) + '</div>';
  const fds = f.findings || [];
  h += '<h3>' + FINDINGS_WORD + ' (' + fds.length + ')</h3>';
  if (fds.length === 0) { h += '<div class="sym">' + NONE + '</div>'; }
  fds.forEach(function (d) {
    h += '<div class="sym"><span class="k" style="color:' + weightColor(d.weight) + '">⚠' + d.weight + '</span><span>' + esc(d.kind) + ' @ L' + d.line + '</span></div>';
  });
  h += '<h3>' + REFS_IN + ' (' + callersOf(id).length + ')</h3>';
  callersOf(id).slice(0, 20).forEach(function (cid) {
    const cf = FN[cid];
    h += '<div class="dep" data-go="' + cid + '"><span>' + (cf ? cf.name : cid) + '</span></div>';
  });
  if (callersOf(id).length === 0) { h += '<div class="sym">' + NONE + '</div>'; }
  h += '<h3>' + REFS_OUT + ' (' + calleesOf(id).length + ')</h3>';
  calleesOf(id).slice(0, 20).forEach(function (cid) {
    const cf = FN[cid];
    h += '<div class="dep" data-go="' + cid + '"><span>' + (cf ? cf.name : cid) + '</span></div>';
  });
  if (calleesOf(id).length === 0) { h += '<div class="sym">' + NONE + '</div>'; }
  const code = FG.codeSnippets[id];
  if (code) { h += '<h3>' + CODE_WORD + '</h3><pre>' + esc(code) + '</pre>'; }
  panel.innerHTML = h; panel.style.display = 'block';
  panel.querySelectorAll('.dep').forEach(function (d) {
    d.addEventListener('click', function () { center(d.dataset.go); selected = d.dataset.go; showFnPanel(d.dataset.go); });
  });
}
function callersOf(id) { return FG.functionEdges.filter(function (e) { return e.to === id; }).map(function (e) { return e.from; }); }
function calleesOf(id) { return FG.functionEdges.filter(function (e) { return e.from === id; }).map(function (e) { return e.to; }); }
function showFilePanel(path) {
  const f = byPath[path]; if (!f) { return; }
  let h = '<h2>' + esc(path) + '</h2>';
  h += '<div class="meta">' + (f.lang || '') + ' · ' + (f.lines || 0) + ' lines</div>';
  h += '<h3>' + SYMS + ' (' + ((f.symbols || []).length) + ')</h3>';
  (f.symbols || []).slice(0, 30).forEach(function (s) {
    h += '<div class="sym"><span class="k">' + (s.kind || '') + '</span><span>' + esc(s.name) + '</span><span class="l">' + (s.line || 0) + '</span></div>';
  });
  panel.innerHTML = h; panel.style.display = 'block';
}
function hidePanel() { panel.style.display = 'none'; selected = null; }
panel.addEventListener('click', function (ev) {
  const go = ev.target.closest('.dep');
  if (go && go.dataset.go) { center(go.dataset.go); if (mode === 'risk') { selected = go.dataset.go; showFnPanel(go.dataset.go); } }
});
// —— 交互 ——
let dragging = false; let last = null;
cv.addEventListener('mousedown', function (e) { dragging = true; last = { x: e.clientX, y: e.clientY }; cv.classList.add('drag'); });
window.addEventListener('mouseup', function () { dragging = false; cv.classList.remove('drag'); });
cv.addEventListener('wheel', function (e) {
  e.preventDefault();
  const factor = e.deltaY < 0 ? 1.12 : 0.89;
  const nx = (e.clientX - view.x) / view.k, ny = (e.clientY - view.y) / view.k;
  view.k = Math.min(Math.max(view.k * factor, 0.05), 3);
  view.x = e.clientX - nx * view.k; view.y = e.clientY - ny * view.k;
}, { passive: false });
window.addEventListener('mousemove', function (e) {
  if (dragging && last) { view.x += e.clientX - last.x; view.y += e.clientY - last.y; last = { x: e.clientX, y: e.clientY }; }
});
cv.addEventListener('click', function (e) {
  const wx = (e.clientX - view.x) / view.k, wy = (e.clientY - view.y) / view.k;
  let hit = null;
  if (mode === 'risk') {
    FLAGGED.forEach(function (f) { if (wx >= f.x && wx <= f.x + f.w && wy >= f.y && wy <= f.y + f.h) { hit = f.id; } });
  } else {
    fileNodes.forEach(function (f) { if (wx >= f.x && wx <= f.x + f.w && wy >= f.y && wy <= f.y + f.h) { hit = f.path; } });
  }
  if (hit) {
    selected = hit;
    if (mode === 'risk') { showFnPanel(hit); } else { showFilePanel(hit); }
  } else { hidePanel(); }
});
window.addEventListener('keydown', function (e) { if (e.key === 'Escape') { hidePanel(); } });
document.getElementById('q').addEventListener('input', function (e) { query = e.target.value.toLowerCase(); });
document.getElementById('fit').addEventListener('click', fit);
document.getElementById('th').addEventListener('click', function () { dark = !dark; document.body.className = dark ? 'dark' : 'light'; });
document.getElementById('m-risk').addEventListener('click', function () { setMode('risk'); });
document.getElementById('m-file').addEventListener('click', function () { setMode('file'); });
function setMode(m) {
  mode = m; hidePanel();
  document.getElementById('m-risk').className = 'chip' + (m === 'risk' ? ' on' : '');
  document.getElementById('m-file').className = 'chip' + (m === 'file' ? ' on' : '');
  fit();
}
window.addEventListener('resize', function () { cv.width = innerWidth * devicePixelRatio; cv.height = innerHeight * devicePixelRatio; });
cv.width = innerWidth * devicePixelRatio; cv.height = innerHeight * devicePixelRatio; fit();
// 动画循环（黑屏修复：此前 draw 从未被调用）
function loop() { draw(performance.now() / 1000); requestAnimationFrame(loop); }
loop();
// 契约注入入口
window.MoongitCodeGraph = {
  scene: D, setTheme: function (d) { dark = !!d; document.body.className = dark ? 'dark' : 'light'; },
  fit: fit,
  // 深链/agent 驱动钩子：直接聚焦某个函数（异常节点即可弹出疑点与实码面板）
  focus: function (id) { if (FN[id]) { mode = 'risk'; center(id); selected = id; showFnPanel(id); } },
  renderTo: function (c2d, w, h, now) { const saved = ctx; ctx = c2d; const vs = { x: view.x, y: view.y, k: view.k };
    view.x = 0; view.y = 0; view.k = Math.min(w / world.w, h / world.h) * 0.96;
    try { draw(now, w, h); } finally { ctx = saved; view.x = vs.x; view.y = vs.y; view.k = vs.k; } },
  draw: function (now) { draw(now); },
};
"""
}

// MARK: - 函数级图谱数据（代码图谱 × 置信度的结合点）
//
// 【形态参考】deepOrca SymbolGraphView 的「焦点三列」+ code-review-graph 的
// 「函数级调用图 × 评审异常叠加」。函数级 = 节点是函数/类型符号，边是
// 「函数体 → 被调函数」的调用关系（词法近似：函数体内的自由调用按名匹配）。
// 置信度 findings 按所在函数聚合，异常函数带实码片段内嵌（点击即看）。
func functionGraphData(graph: CodeGraph, findings: ConfidenceReport): JsonValue {
    let idx = graph.symbolIndex()
    let out = Json.obj()
    let fns = ArrayList<JsonValue>()
    let edgeAgg = HashMap<String, Int64>()
    // findings 按文件聚合
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
            // 该函数的疑点（行落在函数体内）
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
            // 函数体自由调用 → 函数级调用边（按名匹配全局定义）
            var j = bodyStart - 1
            while (j < bodyEnd && j < Int64(srcLines.size)) {
                let stripped = srcLines[j]
                if (!stripped.isEmpty()) {
                    for ((cname, _) in freeCallsIn(stripped)) {
                        if (cname == s.name) { continue }
                        match (idx.get(cname)) {
                            case Some(defs) =>
                                if (Int64(defs.size) > 0) {
                                    // 元组没有 .0 索引——解构（仓颉陷阱）
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
            // 节点：异常节点带 findings 明细与实码
            let o = Json.obj()
            Json.set(o, "id", Json.of(id))
            Json.set(o, "file", Json.of(fe.relPath))
            Json.set(o, "name", Json.of(s.name))
            Json.set(o, "kind", Json.of(symKindId(s.kind)))
            Json.set(o, "line", Json.of(s.line))
            if (Int64(fd.size) > 0) {
                Json.set(o, "findings", JArr(fd))
                Json.set(o, "weight", Json.of(maxW))
                var code = StringBuilder()
                var cl = bodyStart - 1
                while (cl < bodyEnd && cl < Int64(srcLines.size) && cl < bodyStart + 39) {
                    code.append(srcLines[cl]); code.append("\n")
                    cl += 1
                }
                Json.set(snippets, id, Json.of(code.toString()))
            }
            fns.add(o)
            i += 1
        }
    }
    // 边数组：HashMap 迭代无序 —— 按 key 排序（逐字节一致契约）
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
