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
public func treeCanvasHtml(graph: CodeGraph, depth: Int64, en: Bool): String {
    let json = jsonSafeForEmbed(Json.pretty(fullGraphJson(graph, depth)))
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
    sb.append("<div id=\"bar\"><span class=\"title\">${title}</span><span class=\"sub\">${sub} · ${graph.files.size} files</span>")
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
    let refsWord = if (en) { "referenced by" } else { "被引用" }
    let refsOutWord = if (en) { "references" } else { "引用" }
    let symsWord = if (en) { "symbols" } else { "符号" }
    let noneWord = if (en) { "none" } else { "无" }
    let moreWord = if (en) { "more…" } else { "更多…" }
    return "const SYMS = " + jsStr(symsWord) + ";\n"
        + "const MORE = " + jsStr(moreWord) + ";\n"
        + "const REFS_IN = " + jsStr(refsWord) + ";\n"
        + "const REFS_OUT = " + jsStr(refsOutWord) + ";\n"
        + "const NONE = " + jsStr(noneWord) + ";\n"
        + """
'use strict';
const D = window.__CODEGRAPH__;
const cv = document.getElementById('cv');
let ctx = cv.getContext('2d');
const panel = document.getElementById('panel');
// —— 主题 ——
let dark = true;
function C(name) { return getComputedStyle(document.body).getPropertyValue(name).trim() || '#888'; }
// —— 确定性布局：顶层目录分列，列内按路径排序 ——
const dirs = []; const byDir = {};
D.files.forEach(function (f) {
  const dir = f.path.indexOf('/') >= 0 ? f.path.split('/')[0] : '(root)';
  if (!byDir[dir]) { byDir[dir] = []; dirs.push(dir); }
  byDir[dir].push(f);
});
dirs.sort();
const colW = 240, rowH = 44, padX = 60, padY = 60;
let maxRows = 1;
dirs.forEach(function (d) { byDir[d].sort(function (a, b) { return a.path < b.path ? -1 : 1; });
  maxRows = Math.max(maxRows, byDir[d].length); });
const WORLD_W = padX * 2 + dirs.length * colW;
const WORLD_H = padY * 2 + maxRows * rowH;
dirs.forEach(function (d, ci) {
  byDir[d].forEach(function (f, fi) {
    f.x = padX + ci * colW; f.y = padY + fi * rowH; f.w = colW - 26; f.h = 32;
    f.base = f.path.indexOf('/') >= 0 ? f.path.slice(f.path.lastIndexOf('/') + 1) : f.path;
  });
});
const byPath = {}; D.files.forEach(function (f) { byPath[f.path] = f; });
// —— 视口 ——
let view = { x: 0, y: 0, k: 1 };
function fit() {
  const k = Math.min(innerWidth / WORLD_W, innerHeight / WORLD_H) * 0.96;
  view.k = Math.min(Math.max(k, 0.08), 2.5);
  view.x = (innerWidth - WORLD_W * view.k) / 2;
  view.y = (innerHeight - WORLD_H * view.k) / 2;
}
function w2sx(x) { return x * view.k + view.x; }
function w2sy(y) { return y * view.k + view.y; }
// —— 绘制 ——
let selected = null; let query = '';
function nodeDim(f) { return query !== '' && f.path.toLowerCase().indexOf(query) < 0; }
function draw(now, W, H) {
  W = W || innerWidth; H = H || innerHeight;
  ctx.setTransform(devicePixelRatio, 0, 0, devicePixelRatio, 0, 0);
  ctx.fillStyle = C('bg'); ctx.fillRect(0, 0, W, H);
  const pad = 26;
  const bw = (WORLD_W - pad * 2) * view.k, bh = (WORLD_H - pad * 2) * view.k;
  ctx.fillStyle = C('grid'); ctx.globalAlpha = 0.35;
  ctx.fillRect(w2sx(pad), w2sy(pad), bw, bh); ctx.globalAlpha = 1;
  // 边（生长完成后常显；流光 dashPhase 随时间推进）
  const t0 = 300;
  D.referenceEdges.forEach(function (e, i) {
    const a = byPath[e[0]], b = byPath[e[1]];
    if (!a || !b) { return; }
    if (now * 1000 < t0 + i * 12) { return; }
    const x1 = w2sx(a.x + a.w), y1 = w2sy(a.y + a.h / 2);
    const x2 = w2sx(b.x), y2 = w2sy(b.y + b.h / 2);
    const mx = (x1 + x2) / 2;
    const w = e[2] || 1;
    ctx.beginPath(); ctx.moveTo(x1, y1);
    ctx.bezierCurveTo(mx, y1, mx, y2, x2, y2);
    ctx.strokeStyle = C('arrow'); ctx.globalAlpha = Math.min(0.25 + w * 0.15, 0.85);
    ctx.lineWidth = Math.min(0.8 + w * 0.5, 3);
    ctx.setLineDash([6, 5]); ctx.lineDashOffset = -((now * 24 + i * 7) % 11);
    ctx.stroke(); ctx.setLineDash([]); ctx.globalAlpha = 1;
  });
  // 节点
  D.files.forEach(function (f) {
    const x = w2sx(f.x), y = w2sy(f.y), w = f.w * view.k, h = f.h * view.k;
    const dim = nodeDim(f); const sel = selected === f.path;
    ctx.globalAlpha = dim ? 0.25 : 1;
    ctx.fillStyle = sel ? C('accent') : C('panel');
    ctx.beginPath();
    const r = Math.min(7 * view.k, h / 2);
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r); ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r); ctx.arcTo(x, y, x + w, y, r); ctx.closePath();
    ctx.fill();
    ctx.strokeStyle = C(sel ? 'accent' : 'border'); ctx.lineWidth = sel ? 1.6 : 1; ctx.stroke();
    ctx.fillStyle = C('text'); ctx.font = (view.k > 1.1 ? '600 ' : '') + Math.max(10 * view.k, 8) + 'px ui-monospace,Menlo,monospace';
    ctx.textAlign = 'left'; ctx.textBaseline = 'middle';
    ctx.fillText(f.base, x + 8, y + h / 2 - 4);
    ctx.fillStyle = C('muted'); ctx.font = Math.max(9 * view.k, 7) + 'px ui-monospace,Menlo,monospace';
    ctx.fillText((f.lang || '') + ' · ' + (f.symbols ? f.symbols.length : 0) + ' ' + SYMS, x + 8, y + h / 2 + Math.max(7 * view.k, 6));
    ctx.globalAlpha = 1;
  });
}
// —— 三次贝塞尔取点（流光粒子预留）——
function bez(a, c1, c2, b, t) {
  const u = 1 - t;
  return { x: u*u*u*a.x + 3*u*u*t*c1.x + 3*u*t*t*c2.x + t*t*t*b.x,
           y: u*u*u*a.y + 3*u*u*t*c1.y + 3*u*t*t*c2.y + t*t*t*b.y };
}
// —— 面板 ——
function showPanel(path) {
  const f = byPath[path]; if (!f) { return; }
  const outs = []; const ins = [];
  D.referenceEdges.forEach(function (e) {
    if (e[0] === path) { outs.push([e[1], e[2]]); }
    if (e[1] === path) { ins.push([e[0], e[2]]); }
  });
  const lim = 24;
  let h = '<h2>' + path + '</h2>';
  h += '<div class="meta">' + (f.lang || '') + ' · ' + (f.lines || 0) + ' lines · ' +
       (f.symbols ? f.symbols.length : 0) + ' ' + SYMS + '</div>';
  h += '<h3>' + SYMS + '</h3>';
  const syms = f.symbols || [];
  syms.slice(0, lim).forEach(function (s) {
    h += '<div class="sym"><span class="k">' + (s.kind || '') + '</span><span>' + s.name +
         '</span><span class="l">' + (s.line || 0) + '</span></div>';
  });
  if (syms.length > lim) { h += '<div class="sym">' + (syms.length - lim) + ' ' + MORE + '</div>'; }
  h += '<h3>' + REFS_IN + ' (' + ins.length + ')</h3>';
  ins.slice(0, lim).forEach(function (e) { h += '<div class="dep" data-go="' + e[0] + '"><span>' + e[0] + '</span><span class="w">×' + e[1] + '</span></div>'; });
  if (ins.length === 0) { h += '<div class="sym">' + NONE + '</div>'; }
  h += '<h3>' + REFS_OUT + ' (' + outs.length + ')</h3>';
  outs.slice(0, lim).forEach(function (e) { h += '<div class="dep" data-go="' + e[0] + '"><span>' + e[0] + '</span><span class="w">×' + e[1] + '</span></div>'; });
  if (outs.length === 0) { h += '<div class="sym">' + NONE + '</div>'; }
  panel.innerHTML = h; panel.style.display = 'block';
}
function hidePanel() { panel.style.display = 'none'; selected = null; }
panel.addEventListener('click', function (ev) {
  const go = ev.target.closest('.dep');
  if (go && go.dataset.go) { selected = go.dataset.go; showPanel(go.dataset.go); }
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
  D.files.forEach(function (f) {
    if (wx >= f.x && wx <= f.x + f.w && wy >= f.y && wy <= f.y + f.h) { hit = f.path; }
  });
  if (hit) { selected = hit; showPanel(hit); } else { hidePanel(); }
});
window.addEventListener('keydown', function (e) { if (e.key === 'Escape') { hidePanel(); } });
document.getElementById('q').addEventListener('input', function (e) { query = e.target.value.toLowerCase(); });
document.getElementById('fit').addEventListener('click', fit);
document.getElementById('th').addEventListener('click', function () {
  dark = !dark; document.body.className = dark ? 'dark' : 'light';
});
window.addEventListener('resize', function () { cv.width = innerWidth * devicePixelRatio; cv.height = innerHeight * devicePixelRatio; });
cv.width = innerWidth * devicePixelRatio; cv.height = innerHeight * devicePixelRatio; fit();
// 契约注入入口：任何 Canvas2D 兼容 context 都能驱动本渲染器
window.MoongitCodeGraph = {
  scene: D, setTheme: function (d) { dark = !!d; document.body.className = dark ? 'dark' : 'light'; },
  fit: fit,
  renderTo: function (c2d, w, h, now) { drawOn(c2d, w, h, now); },
  draw: function (now) { draw(now); },
};
function drawOn(c2d, w, h, now) {
  // renderTo 的独立路径：同一套绘制逻辑，换到注入的 context 与给定尺寸
  const saved = { x: view.x, y: view.y, k: view.k, c: ctx };
  view.x = 0; view.y = 0; view.k = Math.min(w / WORLD_W, h / WORLD_H) * 0.96;
  ctx = c2d;
  try { draw(now, w, h); } finally { ctx = saved.c; view.x = saved.x; view.y = saved.y; view.k = saved.k; }
}
"""
}
