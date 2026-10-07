// graph/archhtml.cj — 单文件 Canvas 交互架构图。
//
// 【形态】引擎把**布局与事实**算好（archJson 里的 x/y/w/h 就是引擎给出的），
// 内嵌为 window.__ARCH__，页面里的 Canvas 渲染器只负责画与交互：
// 拖拽平移 / 滚轮缩放 / 点选模块出详情 / 分层过滤 / 搜索定位 / 明暗主题。
//
// 【与 archify 的差异】不是抄：布局确定性由引擎保证（同一仓库两次导出逐字节一致）、
// 零外部依赖（无字体 CDN 无 JS 库，离线双击可开）、Canvas 而非 SVG。
//
// 【嵌入纪律】本文件的 JS 一律字符串拼接 —— 不用模板字面量（`${` 会撞仓颉插值）、
// 不用反斜杠转义；数据经 jsonSafeForEmbed 处理后内嵌。
package moongit.graph

import std.collection.*
import std.convert.*
import moongit.util.*

/// JSON 内嵌安全：把 `<` 转成 \u003c —— 防御 "</script>" 提前闭合标签。
/// （结构字符里本来就没有 '<'，命中的只会是字符串值里的泛型尖括号。）
func jsonSafeForEmbed(s: String): String {
    let bytes = s.toArray()
    let out = ArrayList<UInt8>()
    for (b in bytes) {
        if (b == 60) {   // '<'
            for (c in "\\u003c".toArray()) { out.add(c) }
        } else {
            out.add(b)
        }
    }
    return fromUtf8Lossy(out.toArray())
}

/// 架构页面 UI 文案。仓颉元组没有命名字段 —— 用 struct，字段即文档。
public struct ArchUi {
    public let title: String
    public let sub: String
    public let search: String
    public let fit: String
    public let theme: String
    public let hint: String
    public let depsOut: String
    public let depsIn: String
    public let none: String
    public let filesWord: String
    public let symWord: String
    public let lineWord: String
    public let layerWord: String
    public let closeHint: String

    public init(en: Bool) {
        if (en) {
            title = "Architecture"
            sub = "computed by moonGit engine (Cangjie) — deterministic layout, zero dependencies"
            search = "Search module…"
            fit = "Fit"
            theme = "Theme"
            hint = "Drag to pan · wheel to zoom · click a module for details"
            depsOut = "Outgoing deps"
            depsIn = "Incoming deps"
            none = "none"
            filesWord = "files"
            symWord = "symbols"
            lineWord = "lines"
            layerWord = "Layer"
            closeHint = "Esc to clear"
        } else {
            title = "技术架构"
            sub = "moonGit 引擎（仓颉）确定性计算 · 零依赖单文件"
            search = "搜索模块…"
            fit = "复位"
            theme = "主题"
            hint = "拖拽平移 · 滚轮缩放 · 点击模块看详情"
            depsOut = "出向依赖"
            depsIn = "入向依赖"
            none = "无"
            filesWord = "文件"
            symWord = "符号"
            lineWord = "行"
            layerWord = "层"
            closeHint = "Esc 取消选中"
        }
    }
}

func archUiText(en: Bool): ArchUi {
    return ArchUi(en)
}

/// 生成单文件交互架构图（Canvas 渲染）。
public func archCanvasHtml(data: ArchData, en: Bool): String {
    layoutArch(data)
    let json = jsonSafeForEmbed(Json.pretty(archJson(data, en)))
    let ui = archUiText(en)
    let sb = StringBuilder()

    sb.append("<!DOCTYPE html>\n<html lang=\"${if (en) {"en"} else {"zh-CN"}}\" data-theme=\"dark\">\n<head>\n<meta charset=\"UTF-8\">\n")
    sb.append("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n")
    sb.append("<meta name=\"generator\" content=\"moonGit graph arch (Cangjie engine, deterministic layout)\">\n")
    sb.append("<title>${ui.title} · ${data.totalFiles}f / ${data.totalSymbols}s</title>\n")
    sb.append("""
<style>
:root, body.dark { --bg:#0b1120; --grid:#16233c; --text:#e2e8f0; --muted:#7d8da1;
  --panel:#0f172acc; --border:#24334d; --accent:#34d399; --arrow:#5b6b85; --chip:#16233c; }
body.light { --bg:#f6f8fb; --grid:#e3e9f2; --text:#0f172a; --muted:#64748b;
  --panel:#ffffffd9; --border:#d5deeb; --accent:#059669; --arrow:#9aa8bd; --chip:#e9eff7; }
* { margin:0; padding:0; box-sizing:border-box; }
html, body { height:100%; overflow:hidden; }
body { background:var(--bg); color:var(--text); font:13px/1.5 -apple-system,'SF Pro Text','PingFang SC','Microsoft YaHei',sans-serif; }
#cv { position:fixed; inset:0; display:block; cursor:grab; }
#cv.drag { cursor:grabbing; }
#cv.point { cursor:pointer; }
#bar { position:fixed; top:12px; left:12px; display:flex; gap:8px; align-items:center;
  background:var(--panel); border:1px solid var(--border); border-radius:10px; padding:8px 10px;
  backdrop-filter:blur(8px); flex-wrap:wrap; max-width:calc(100vw - 24px); }
#bar .title { font-weight:700; letter-spacing:.2px; }
#bar .sub { color:var(--muted); font-size:11px; }
.chip { border:1px solid var(--border); background:var(--chip); color:var(--text);
  border-radius:999px; padding:3px 10px; cursor:pointer; user-select:none; font-size:12px; }
.chip.off { opacity:.35; text-decoration:line-through; }
#bar input { background:var(--chip); border:1px solid var(--border); color:var(--text);
  border-radius:8px; padding:4px 8px; outline:none; width:150px; }
.btn { border:1px solid var(--border); background:var(--chip); color:var(--text);
  border-radius:8px; padding:4px 10px; cursor:pointer; }
.btn:hover, .chip:hover { border-color:var(--accent); }
#hint { position:fixed; bottom:12px; left:50%; transform:translateX(-50%);
  color:var(--muted); font-size:11px; background:var(--panel); border:1px solid var(--border);
  border-radius:999px; padding:4px 14px; backdrop-filter:blur(8px); }
#panel { position:fixed; top:64px; right:12px; width:300px; max-height:calc(100vh - 90px);
  overflow:auto; background:var(--panel); border:1px solid var(--border); border-radius:12px;
  padding:14px; backdrop-filter:blur(8px); display:none; }
#panel h2 { font-size:15px; margin-bottom:2px; }
#panel .meta { color:var(--muted); font-size:12px; margin-bottom:8px; }
#panel h3 { font-size:11px; color:var(--muted); text-transform:uppercase; letter-spacing:.8px; margin:10px 0 4px; }
.dep { display:flex; justify-content:space-between; gap:8px; padding:3px 6px; border-radius:6px; cursor:pointer; }
.dep:hover { background:var(--chip); }
.dep .w { color:var(--muted); }
.langtag { display:inline-block; border:1px solid var(--border); border-radius:5px;
  padding:0 6px; margin:2px 2px 0 0; font-size:11px; color:var(--muted); }
</style>\n</head>\n<body class="dark">\n<canvas id="cv"></canvas>\n""")
    sb.append("<div id=\"bar\"><span class=\"title\">${ui.title}</span><span class=\"sub\">${ui.sub} · ${data.totalFiles} ${ui.filesWord} / ${data.totalSymbols} ${ui.symWord} / ${data.totalLines} ${ui.lineWord}</span>")
    // 分层 chips（JS 动态补齐也行，这里引擎直出：少一段运行时不确定性）
    var li: Int64 = 0
    while (li < LAYER_COUNT) {
        var count: Int64 = 0
        for (m in data.modules) { if (m.layer == li) { count += 1 } }
        if (count > 0) {
            sb.append("<span class=\"chip\" data-layer=\"${li}\">${layerName(li, en)} ${count}</span>")
        }
        li += 1
    }
    sb.append("<input id=\"q\" placeholder=\"${ui.search}\"><button class=\"btn\" id=\"fit\">${ui.fit}</button><button class=\"btn\" id=\"th\">${ui.theme}</button></div>\n")
    sb.append("<div id=\"hint\">${ui.hint}</div>\n<div id=\"panel\"></div>\n<script>\nwindow.__ARCH__ = ")
    sb.append(json)
    sb.append(";\n</script>\n<script>\n")
    sb.append(renderJs(en))
    sb.append("\n</script>\n</body>\n</html>\n")
    return sb.toString()
}

/// Canvas 渲染器源码。纪律：无模板字面量、无 `${`、无反斜杠转义 ——
/// 全部字符串拼接，这样 Cangjie 的插值与转义不会和 JS 抢字符。
func renderJs(en: Bool): String {
    let t = archUiText(en)
    let sb = StringBuilder()

    // 每行一个 JS 语句块；纪律：无模板字面量、无 ${、无反斜杠转义
    sb.append("(function () {\n")
    sb.append("  var DATA = window.__ARCH__;\n")
    sb.append("  var cv = document.getElementById('cv');\n")
    sb.append("  var ctx = cv.getContext('2d');\n")
    sb.append("  var panel = document.getElementById('panel');\n")
    sb.append("  var dark = !window.matchMedia || !window.matchMedia('(prefers-color-scheme: light)').matches;\n")
    sb.append("  document.body.className = dark ? 'dark' : 'light';\n")
    sb.append("  var view = { x: 0, y: 0, k: 1 };\n")
    sb.append("  var sel = null; var hover = null; var layersOn = {};\n")
    sb.append("  var byId = {};\n")
    sb.append("  DATA.modules.forEach(function (m) { byId[m.id] = m; layersOn[m.layer] = true; m._a = 0; m._s = 1; });\n")
    sb.append("  var PAL = {\n")
    sb.append("    dark: { bg0:'#0d1526', bg1:'#080d1a', grid:'#1a2740', text:'#e8eef8', muted:'#8b9bb4', border:'#263650', arrow:'#64748b', accent:'#34d399',\n")
    sb.append("      cols:['#38bdf8','#a78bfa','#34d399','#fbbf24','#8ea3bd'], fills:['rgba(56,189,248,0.10)','rgba(167,139,250,0.10)','rgba(52,211,153,0.10)','rgba(251,191,36,0.08)','rgba(142,163,189,0.08)'] },\n")
    sb.append("    light: { bg0:'#f7f9fd', bg1:'#eef2f8', grid:'#e2e8f2', text:'#0f172a', muted:'#64748b', border:'#d8e1ec', arrow:'#9aa8bd', accent:'#059669',\n")
    sb.append("      cols:['#0284c7','#7c3aed','#059669','#d97706','#64748b'], fills:['rgba(2,132,199,0.07)','rgba(124,58,237,0.07)','rgba(5,150,105,0.07)','rgba(217,119,6,0.07)','rgba(100,116,139,0.07)'] }\n")
    sb.append("  };\n")
    sb.append("  function P() { return dark ? PAL.dark : PAL.light; }\n")
    sb.append("  function ease(t) { if (t < 0) return 0; if (t > 1) return 1; return 1 - Math.pow(1 - t, 3); }\n")
    sb.append("  var START = performance.now();\n")
    sb.append("  var ORDER = {}; DATA.modules.forEach(function (m) { if (ORDER[m.layer] === undefined) ORDER[m.layer] = 0; ORDER[m.layer] += 1; m._ord = ORDER[m.layer]; });\n")
    // 粒子：权重越高越多，沿贝塞尔流动
    sb.append("  var PARTS = [];\n")
    sb.append("  DATA.edges.forEach(function (e) { var n = Math.min(1 + Math.round(e.weight / 5), 6); for (var i = 0; i < n; i++) { PARTS.push({ e: e, o: Math.random(), sp: 0.00012 + Math.random() * 0.00009 }); } });\n")
    sb.append("  function bez(a, b, t) {\n")
    sb.append("    var x1 = a.x + a.w; var y1 = a.y + a.h / 2; var x2 = b.x; var y2 = b.y + b.h / 2; var mx = (x1 + x2) / 2;\n")
    sb.append("    var u = 1 - t;\n")
    sb.append("    return { x: u*u*u*x1 + 3*u*u*t*mx + 3*u*t*t*mx + t*t*t*x2, y: u*u*u*y1 + 3*u*u*t*y1 + 3*u*t*t*y2 + t*t*t*y2 };\n")
    sb.append("  }\n")
    sb.append("  function resize() { var d = window.devicePixelRatio || 1; cv.width = innerWidth * d; cv.height = innerHeight * d; cv.style.width = innerWidth + 'px'; cv.style.height = innerHeight + 'px'; ctx.setTransform(d, 0, 0, d, 0, 0); }\n")
    sb.append("  function w2sx(x) { return x * view.k + view.x; }\n")
    sb.append("  function w2sy(y) { return y * view.k + view.y; }\n")
    sb.append("  function bounds() { var b = { x0: 1e9, y0: 1e9, x1: -1e9, y1: -1e9 }; DATA.modules.forEach(function (m) { if (m.x < b.x0) b.x0 = m.x; if (m.y < b.y0) b.y0 = m.y; if (m.x + m.w > b.x1) b.x1 = m.x + m.w; if (m.y + m.h > b.y1) b.y1 = m.y + m.h; }); b.x0 -= 60; b.y0 -= 90; b.x1 += 60; b.y1 += 60; return b; }\n")
    sb.append("  function fit() { var b = bounds(); var kx = innerWidth / (b.x1 - b.x0); var ky = innerHeight / (b.y1 - b.y0); var target = Math.min(kx, ky, 1.35); if (target < 0.18) target = 0.18; view.k = target; view.x = (innerWidth - (b.x0 + b.x1) * view.k) / 2; view.y = (innerHeight - (b.y0 + b.y1) * view.k) / 2; }\n")
    sb.append("  function roundRect(x, y, w, h, r) { ctx.beginPath(); ctx.moveTo(x + r, y); ctx.arcTo(x + w, y, x + w, y + h, r); ctx.arcTo(x + w, y + h, x, y + h, r); ctx.arcTo(x, y + h, x, y, r); ctx.arcTo(x, y, x + w, y, r); ctx.closePath(); }\n")
    // ── 主绘制（每帧）──
    sb.append("  function draw(now) {\n")
    sb.append("    var p = P();\n")
    sb.append("    var g = ctx.createLinearGradient(0, 0, 0, innerHeight); g.addColorStop(0, p.bg0); g.addColorStop(1, p.bg1); ctx.fillStyle = g; ctx.fillRect(0, 0, innerWidth, innerHeight);\n")
    sb.append("    var step = 84 * view.k;\n")
    sb.append("    if (step > 15) { ctx.strokeStyle = p.grid; ctx.globalAlpha = 0.55; ctx.lineWidth = 1; ctx.beginPath();\n")
    sb.append("      var gx = view.x % step; while (gx < 0) gx += step; for (var x = gx; x < innerWidth; x += step) { ctx.moveTo(x, 0); ctx.lineTo(x, innerHeight); }\n")
    sb.append("      var gy = view.y % step; while (gy < 0) gy += step; for (var y = gy; y < innerHeight; y += step) { ctx.moveTo(0, y); ctx.lineTo(innerWidth, y); }\n")
    sb.append("      ctx.stroke(); ctx.globalAlpha = 1; }\n")
    // 层框（错峰浮现）
    sb.append("    DATA.layers.forEach(function (L) {\n")
    sb.append("      if (!layersOn[L.index]) return;\n")
    sb.append("      var x0 = 1e9, y0 = 1e9, x1 = -1e9, y1 = -1e9; var any = false;\n")
    sb.append("      DATA.modules.forEach(function (m) { if (m.layer !== L.index) return; any = true; if (m.x < x0) x0 = m.x; if (m.y < y0) y0 = m.y; if (m.x + m.w > x1) x1 = m.x + m.w; if (m.y + m.h > y1) y1 = m.y + m.h; });\n")
    sb.append("      if (!any) return;\n")
    sb.append("      var ap = ease((now - START - 100 - L.index * 120) / 450); if (ap <= 0) return;\n")
    sb.append("      ctx.globalAlpha = ap * 0.9; ctx.setLineDash([7, 6]); ctx.strokeStyle = p.border; ctx.lineWidth = 1;\n")
    sb.append("      roundRect(w2sx(x0 - 18), w2sy(y0 - 46), (x1 - x0 + 36) * view.k, (y1 - y0 + 64) * view.k, 14); ctx.stroke(); ctx.setLineDash([]);\n")
    sb.append("      ctx.globalAlpha = ap; ctx.fillStyle = p.cols[L.index]; ctx.font = '700 12px -apple-system, sans-serif'; ctx.textAlign = 'left';\n")
    sb.append("      ctx.fillText(L.name + '  L' + L.index, w2sx(x0 - 10), w2sy(y0 - 46) + 16); ctx.globalAlpha = 1; });\n")
    // 边（渐变 + 生长动画 + 悬停强调）
    sb.append("    DATA.edges.forEach(function (e) {\n")
    sb.append("      var a = byId[e.from]; var b = byId[e.to]; if (!a || !b) return; if (!layersOn[a.layer] || !layersOn[b.layer]) return;\n")
    sb.append("      var ap = ease((now - START - 420 - (a.layer + b.layer) * 60) / 520); if (ap <= 0) return;\n")
    sb.append("      var hot = sel && (sel === a.id || sel === b.id); var dim = (sel || hover) && !hot && !(hover === a.id || hover === b.id) && sel !== a.id && sel !== b.id;\n")
    sb.append("      var x1 = w2sx(a.x + a.w); var y1 = w2sy(a.y + a.h / 2); var x2 = w2sx(b.x); var y2 = w2sy(b.y + b.h / 2); var mx = (x1 + x2) / 2;\n")
    sb.append("      var grad = ctx.createLinearGradient(x1, y1, x2, y2); grad.addColorStop(0, p.cols[a.layer]); grad.addColorStop(1, p.cols[b.layer]);\n")
    sb.append("      ctx.strokeStyle = grad; ctx.globalAlpha = dim ? 0.05 : (hot ? 0.9 : Math.min(0.14 + e.weight * 0.05, 0.5)) * ap;\n")
    sb.append("      ctx.lineWidth = hot ? 2.4 : Math.min(1 + e.weight * 0.12, 2.8);\n")
    sb.append("      var approx = (Math.abs(x2 - x1) + Math.abs(y2 - y1)) * 1.25 * ap;\n")
    sb.append("      ctx.setLineDash([approx]); ctx.lineDashOffset = approx * (1 - ap);\n")
    sb.append("      ctx.beginPath(); ctx.moveTo(x1, y1); ctx.bezierCurveTo(mx, y1, mx, y2, x2, y2); ctx.stroke(); ctx.setLineDash([]);\n")
    sb.append("      var ang = Math.atan2(y2 - (y1 + y2) / 2, x2 - mx);\n")
    sb.append("      ctx.globalAlpha = (dim ? 0.05 : (hot ? 0.95 : 0.6)) * ap; ctx.fillStyle = p.arrow;\n")
    sb.append("      ctx.beginPath(); ctx.moveTo(x2, y2); ctx.lineTo(x2 - 9 * Math.cos(ang - 0.42), y2 - 9 * Math.sin(ang - 0.42)); ctx.lineTo(x2 - 9 * Math.cos(ang + 0.42), y2 - 9 * Math.sin(ang + 0.42)); ctx.closePath(); ctx.fill(); ctx.globalAlpha = 1; });\n")
    // 流动粒子（数据流向的动态感）
    sb.append("    PARTS.forEach(function (pt) {\n")
    sb.append("      var a = byId[pt.e.from]; var b = byId[pt.e.to]; if (!a || !b) return; if (!layersOn[a.layer] || !layersOn[b.layer]) return;\n")
    sb.append("      if (sel && sel !== a.id && sel !== b.id) return;\n")
    sb.append("      var pos = bez(a, b, (now * pt.sp + pt.o) % 1);\n")
    sb.append("      var c = P().cols[b.layer];\n")
    sb.append("      ctx.globalAlpha = 0.85; ctx.fillStyle = c; ctx.shadowColor = c; ctx.shadowBlur = 7;\n")
    sb.append("      ctx.beginPath(); ctx.arc(w2sx(pos.x), w2sy(pos.y), 2.1, 0, 6.2832); ctx.fill(); ctx.shadowBlur = 0; ctx.globalAlpha = 1; });\n")
    // 节点（错峰入场 + 上浮 + 悬停缩放）
    sb.append("    DATA.modules.forEach(function (m) {\n")
    sb.append("      if (!layersOn[m.layer]) return;\n")
    sb.append("      var target = ease((now - START - m.layer * 150 - m._ord * 55) / 480);\n")
    sb.append("      m._a = m._a + (target - m._a) * 0.35; if (m._a < 0.001) m._a = target;\n")
    sb.append("      var isSel = sel === m.id; var isHot = hover === m.id; var dim = (sel || hover) && !isSel && !isHot;\n")
    sb.append("      var wantS = isHot ? 1.045 : (isSel ? 1.03 : 1.0); m._s = m._s + (wantS - m._s) * 0.25;\n")
    sb.append("      var c = P().cols[m.layer];\n")
    sb.append("      var cx = m.x + m.w / 2; var cy = m.y + m.h / 2; var w = m.w * m._s * view.k; var h = m.h * m._s * view.k;\n")
    sb.append("      var x = w2sx(cx) - w / 2; var y = w2sy(cy + (1 - m._a) * 16) - h / 2;\n")
    sb.append("      ctx.globalAlpha = m._a * (dim ? 0.28 : 1);\n")
    sb.append("      if (isSel || isHot) { ctx.shadowColor = c; ctx.shadowBlur = isSel ? 22 : 14; }\n")
    sb.append("      roundRect(x, y, w, h, 11);\n")
    sb.append("      ctx.fillStyle = dark ? 'rgba(13,21,38,0.92)' : 'rgba(255,255,255,0.94)'; ctx.fill();\n")
    sb.append("      ctx.lineWidth = isSel ? 2.4 : 1.2; ctx.strokeStyle = c; ctx.stroke(); ctx.shadowBlur = 0;\n")
    sb.append("      ctx.fillStyle = c; ctx.globalAlpha = m._a * (dim ? 0.28 : 0.95); ctx.fillRect(x, y + 9, 3.2, h - 18);\n")
    sb.append("      ctx.globalAlpha = m._a * (dim ? 0.28 : 1);\n")
    sb.append("      ctx.fillStyle = p.text; ctx.font = (isSel || isHot ? '700 ' : '600 ') + Math.max(11, Math.min(14, 14 * view.k)) + 'px -apple-system, sans-serif'; ctx.textAlign = 'left';\n")
    sb.append("      ctx.fillText(m.id, x + 13, y + 23, w - 22);\n")
    sb.append("      ctx.fillStyle = p.muted; ctx.font = '11px -apple-system, sans-serif';\n")
    sb.append("      ctx.fillText(m.files + ' ' + FILES + ' · ' + m.symbols + ' ' + SYMS + ' · ' + m.lines + ' ' + LINES, x + 13, y + h - 12, w - 22);\n")
    sb.append("      ctx.globalAlpha = 1; });\n")
    sb.append("  }\n")
    // ── 动画循环 ──
    sb.append("  function loop() { draw(performance.now()); requestAnimationFrame(loop); }\n")
    // 交互
    sb.append("  function hitTest(px, py) { for (var i = DATA.modules.length - 1; i >= 0; i--) { var m = DATA.modules[i]; if (!layersOn[m.layer]) continue; var x = w2sx(m.x); var y = w2sy(m.y); if (px >= x && px <= x + m.w * view.k && py >= y && py <= y + m.h * view.k) return m; } return null; }\n")
    sb.append("  function center(m) { view.x = innerWidth / 2 - (m.x + m.w / 2) * view.k; view.y = innerHeight / 2 - (m.y + m.h / 2) * view.k; }\n")
    sb.append("  function escapeHtml(s) { return String(s).split('<').join('&lt;').split('>').join('&gt;'); }\n")
    sb.append("  function showPanel(m) {\n")
    sb.append("    var outs = []; var ins = [];\n")
    sb.append("    DATA.edges.forEach(function (e) { if (e.from === m.id) outs.push(e); if (e.to === m.id) ins.push(e); });\n")
    sb.append("    var h = '<h2>' + escapeHtml(m.id) + '</h2>';\n")
    sb.append("    var ln = DATA.layers[m.layer] ? DATA.layers[m.layer].name : m.layer;\n")
    sb.append("    h += '<div class=\"meta\">' + LAYERW + ' L' + m.layer + ' · ' + ln + '</div>';\n")
    sb.append("    h += '<div>' + m.files + ' ' + FILES + ' · ' + m.symbols + ' ' + SYMS + ' · ' + m.lines + ' ' + LINES + '</div>';\n")
    sb.append("    h += '<div>'; m.langs.forEach(function (l) { h += '<span class=\"langtag\">' + escapeHtml(l) + '</span>'; }); h += '</div>';\n")
    sb.append("    h += '<h3>' + OUT + '</h3>';\n")
    sb.append("    if (outs.length === 0) h += '<div class=\"meta\">' + NONE + '</div>';\n")
    sb.append("    outs.sort(function (a, b) { return b.weight - a.weight; }).forEach(function (e) { h += '<div class=\"dep\" data-id=\"' + escapeHtml(e.to) + '\"><span>' + escapeHtml(e.to) + '</span><span class=\"w\">' + e.weight + '</span></div>'; });\n")
    sb.append("    h += '<h3>' + IN + '</h3>';\n")
    sb.append("    if (ins.length === 0) h += '<div class=\"meta\">' + NONE + '</div>';\n")
    sb.append("    ins.sort(function (a, b) { return b.weight - a.weight; }).forEach(function (e) { h += '<div class=\"dep\" data-id=\"' + escapeHtml(e.from) + '\"><span>' + escapeHtml(e.from) + '</span><span class=\"w\">' + e.weight + '</span></div>'; });\n")
    sb.append("    h += '<div class=\"meta\" style=\"margin-top:10px\">' + ESC + '</div>';\n")
    sb.append("    panel.innerHTML = h; panel.style.display = 'block';\n")
    sb.append("    panel.querySelectorAll('.dep').forEach(function (el) { el.addEventListener('click', function () { var m2 = byId[el.getAttribute('data-id')]; if (m2) { sel = m2.id; showPanel(m2); center(m2); } }); });\n")
    sb.append("  }\n")
    sb.append("  function hidePanel() { sel = null; panel.style.display = 'none'; }\n")
    sb.append("  var drag = null;\n")
    sb.append("  cv.addEventListener('mousedown', function (e) { drag = { x: e.clientX, y: e.clientY, tx: view.x, ty: view.y, moved: false }; cv.className = 'drag'; });\n")
    sb.append("  window.addEventListener('mousemove', function (e) {\n")
    sb.append("    if (drag) { var dx = e.clientX - drag.x; var dy = e.clientY - drag.y; if (Math.abs(dx) + Math.abs(dy) > 4) drag.moved = true; view.x = drag.tx + dx; view.y = drag.ty + dy; return; }\n")
    sb.append("    var m = hitTest(e.clientX, e.clientY); hover = m ? m.id : null; cv.className = m ? 'point' : '';\n")
    sb.append("  });\n")
    sb.append("  window.addEventListener('mouseup', function (e) { if (!drag) return; var wasClick = !drag.moved; cv.className = hover ? 'point' : ''; drag = null; if (wasClick) { var m = hitTest(e.clientX, e.clientY); if (m) { sel = m.id; showPanel(m); } else { hidePanel(); } } });\n")
    sb.append("  cv.addEventListener('wheel', function (e) { e.preventDefault(); var f = e.deltaY < 0 ? 1.12 : 1 / 1.12; var nk = Math.max(0.12, Math.min(3.5, view.k * f)); var r = nk / view.k; view.x = e.clientX - (e.clientX - view.x) * r; view.y = e.clientY - (e.clientY - view.y) * r; view.k = nk; }, { passive: false });\n")
    sb.append("  window.addEventListener('keydown', function (e) { if (e.key === 'Escape') hidePanel(); });\n")
    sb.append("  window.addEventListener('resize', resize);\n")
    sb.append("  document.querySelectorAll('.chip').forEach(function (el) { el.addEventListener('click', function () { var L = parseInt(el.getAttribute('data-layer'), 10); layersOn[L] = !layersOn[L]; el.className = layersOn[L] ? 'chip' : 'chip off'; }); });\n")
    sb.append("  document.getElementById('fit').addEventListener('click', function () { sel = null; hover = null; panel.style.display = 'none'; fit(); });\n")
    sb.append("  document.getElementById('th').addEventListener('click', function () { dark = !dark; document.body.className = dark ? 'dark' : 'light'; });\n")
    sb.append("  document.getElementById('q').addEventListener('keydown', function (e) { if (e.key !== 'Enter') return; var q = e.target.value.toLowerCase(); if (!q) return; var hit = null; DATA.modules.forEach(function (m) { if (!hit && m.id.toLowerCase().indexOf(q) >= 0) hit = m; }); if (hit) { sel = hit.id; showPanel(hit); center(hit); } });\n")
    sb.append("  var FILES = " + jsStr(t.filesWord) + ", SYMS = " + jsStr(t.symWord) + ", LINES = " + jsStr(t.lineWord) + ";\n")
    sb.append("  var OUT = " + jsStr(t.depsOut) + ", IN = " + jsStr(t.depsIn) + ", NONE = " + jsStr(t.none) + ";\n")
    sb.append("  var LAYERW = " + jsStr(t.layerWord) + ", ESC = " + jsStr(t.closeHint) + ";\n")
    sb.append("  var en = " + (if (en) { "true" } else { "false" }) + ";\n")
    sb.append("  resize(); fit(); loop();\n")
    sb.append("})();\n")
    return sb.toString()
}

/// JS 字符串字面量安全包装。
/// ⚠️ 上一版的乱码根源：逐字节 `fromUtf8Lossy([b])` —— 中文一个字 3 字节，
/// 拆开每字节单独解码全变成 U+FFFD（�）。正确做法：把「需要转义的两个 ASCII」
/// 之外的字节**原样收集**，最后一次性 fromUtf8Lossy —— 多字节序列完整解码。
func jsStr(s: String): String {
    let bytes = s.toArray()
    let out = ArrayList<UInt8>()
    out.add(34)   // '"'
    for (b in bytes) {
        if (b == 34 || b == 92) {
            out.add(92)   // '\\'
        }
        out.add(b)
    }
    out.add(34)
    return fromUtf8Lossy(out.toArray())
}
