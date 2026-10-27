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
/// 场景出口（archscene.cj）与驱动 JS（renderJs）共用这一份——文案字面量
/// 只许写在这一个 init 里，两处各抄一份必然漂移（半中半英就是这么来的）。
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
    public let moduleWord: String
    public let root: String
    // ── 深度技术呈现新增（卡片徽标 / 顶栏体检 / 图例）──
    public let modulesWord: String    // 层标签计数单位：「1 模块」/「1 modules」
    public let inShort: String        // 卡片入出徽标的「入」
    public let outShort: String       // 卡片入出徽标的「出」
    public let instWord: String       // 不稳定度
    public let healthWord: String     // 顶栏体检区标题
    public let fanInWord: String      // 顶栏扇入
    public let fanOutWord: String     // 顶栏扇出
    public let violWord: String       // 违规（体检区清单标题）
    public let noViolWord: String     // 无违规（绿字空态）
    public let cycleWord: String      // 环
    public let noCycleWord: String    // 无环（绿字空态）
    public let legendText: String     // 图例一行
    public let otherLayerNote: String // 存在未分层模块时图例追加的一句
    // ── 职责视图（技术深度）──
    public let roleViewWord: String   // 视图切换 chip：职责视图
    public let layerViewWord: String  // 视图切换 chip：分层总览
    public let roleViolWord: String   // 体检区：职责违规
    public let entryWord: String      // 面板：入口
    public let compositionWord: String// 面板：职责构成

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
            moduleWord = "external module"
            root = "Architecture"
            modulesWord = "modules"
            inShort = "in"
            outShort = "out"
            instWord = "Instability"
            healthWord = "Health"
            fanInWord = "Fan-in"
            fanOutWord = "Fan-out"
            violWord = "Violations"
            noViolWord = "no violations"
            cycleWord = "Cycles"
            noCycleWord = "no cycles"
            legendText = "top = interface layers, bottom = foundation; arrow down = healthy dependency; red upward = violation; orange = cycle; instability = out/(in+out)"
            otherLayerNote = "unlayered modules sit on top (excluded from violation checks)"
            roleViewWord = "Role view"
            layerViewWord = "Layered"
            roleViolWord = "Role violations"
            entryWord = "Entry"
            compositionWord = "Composition"
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
            moduleWord = "外部模块"
            root = "架构总览"
            modulesWord = "模块"
            inShort = "入"
            outShort = "出"
            instWord = "不稳定度"
            healthWord = "架构体检"
            fanInWord = "扇入"
            fanOutWord = "扇出"
            violWord = "违规"
            noViolWord = "无违规"
            cycleWord = "环"
            noCycleWord = "无环"
            legendText = "上=接口层，下=基础层；箭头向下=健康依赖；红色上行=违规；橙=环；不稳定度=出/(入+出)"
            otherLayerNote = "未分层模块在最上（不参与违规判定）"
            roleViewWord = "职责视图"
            layerViewWord = "分层总览"
            roleViolWord = "职责违规"
            entryWord = "入口"
            compositionWord = "职责构成"
        }
    }
}

func archUiText(en: Bool): ArchUi {
    return ArchUi(en)
}

/// PAL 的 langs 子对象（JS 字面量片段）：从 langThemeColors 派生 ——
/// 语言色值表只有 archscene.cj 一份构造点，本文件不再手抄色值。
/// 键名不带引号（驱动 JS 的既有纪律）；形态为 `语言名:'色值'` 逗号序列。
func langPaletteJs(dark: Bool): String {
    let sb = StringBuilder()
    var first = true
    for ((lang, color) in langThemeColors(dark)) {
        if (!first) { sb.append(", ") }
        sb.append("${lang}:'${color}'")
        first = false
    }
    return sb.toString()
}

/// 生成单文件交互架构图（Canvas 渲染）。
///
/// 【两段拆分】布局与事实（layoutArch + archJson）与模板渲染（renderArchHtml）
/// 是两个独立阶段：`arch gen` 把 archJson 全量 + 元数据持久化成 arch.json，
/// `render arch` 用**持久化的 JSON** 直接渲染——绘图不重算图谱。
/// 本函数保持旧签名 = 两段的组合（临时 JSON、零持久化副作用），
/// 旧 `graph arch --format html` 行为不变：只打印不落盘。
public func archCanvasHtml(data: ArchData, en: Bool): String {
    layoutArch(data)
    return renderArchHtml(Json.pretty(archJson(data, en)), en)
}

/// 模板渲染段：archJson 字符串 → 单文件 HTML。
/// **纯函数**：同输入 ⇒ 逐字节一致（布局坐标已在 archJson 的 modules x/y/w/h
/// 与 lanes 里，页面驱动只负责画——本函数不碰 ArchData，不重算任何事实）。
///
/// 传入的 JSON 带 updateCount/generatedAt 两键时（`arch gen` 的持久化产物
/// arch.json），在 DOCTYPE 后内嵌复用判定标记——与 index 渲染的
/// renderIndexEmbeddedUpdateCount / renderIndexEmbeddedGeneratedAt 是同一格式
/// 的一对，读取器必须能回答「有没有标记」；`graph arch` 的临时 JSON 没有
/// 这两键，标记缺席（兼容面产物形状不变）。
public func renderArchHtml(archJsonStr: String, en: Bool): String {
    // 模板需要 totalFiles / totalSymbols / totalLines / 各层模块数 / 治理计数，
    // 全部从传入的 JSON 现读（同一份 JSON 既内嵌又被模板引用——单一来源）。
    // 解析失败是引擎缺陷（archJson 刚构造出来），硬失败不渲染残页。
    let root = match (Json.parse(archJsonStr)) {
        case Some(j) => j
        case None => throw DgError("ARCH_JSON_CORRUPT",
            "arch.json is not valid JSON (engine bug) / archJson 内容不是合法 JSON——引擎缺陷")
    }
    let totalFiles = Json.intAt(root, "totalFiles", 0)
    let totalSymbols = Json.intAt(root, "totalSymbols", 0)
    let totalLines = Json.intAt(root, "totalLines", 0)
    let warns = Json.getOr(root, "warnings")
    let violationCount = Json.intAt(warns, "violations", 0)
    let cycleEdgeCount = Json.intAt(warns, "cycleEdges", 0)
    let ui = archUiText(en)
    // 持久化产物的自报家门（复用判定比对的就是这一行）
    var metaComment = ""
    if (Json.has(root, "updateCount")) {
        metaComment = "<!-- moongit arch render · updateCount=" +
            Int64(Json.intAt(root, "updateCount", 0)).toString() +
            " · generatedAt=" + Json.strAt(root, "generatedAt", "") + " -->\n"
    }
    let json = jsonSafeForEmbed(archJsonStr)
    let sb = StringBuilder()

    sb.append("<!DOCTYPE html>\n${metaComment}<html lang=\"${if (en) { "en" } else { "zh-CN" }}\" data-theme=\"dark\">\n<head>\n<meta charset=\"UTF-8\">\n")
    sb.append("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n")
    sb.append("<meta name=\"generator\" content=\"moonGit graph arch (Cangjie engine, deterministic layout)\">\n")
    sb.append("<title>${ui.title} · ${totalFiles}f / ${totalSymbols}s</title>\n")
    sb.append("""
<style>
:root, body.dark { --bg:#0b1120; --grid:#16233c; --text:#e2e8f0; --muted:#8b9bb4;
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
.chip.vchip.on { border-color:var(--accent); color:var(--accent); font-weight:600; }
#bar input { background:var(--chip); border:1px solid var(--border); color:var(--text);
  border-radius:8px; padding:4px 8px; outline:none; width:150px; }
.btn { border:1px solid var(--border); background:var(--chip); color:var(--text);
  border-radius:8px; padding:4px 10px; cursor:pointer; }
.btn:hover, .chip:hover { border-color:var(--accent); }
.warn { color:#f87171; font-weight:700; font-size:12px; }
/* 截断警示条（与 .warn 同色系；JS 读 DATA.truncated 命中时插入） */
#truncbar { position:fixed; top:12px; right:12px; color:#f87171; font-weight:700; font-size:12px;
  background:var(--panel); border:1px solid var(--border); border-radius:10px; padding:8px 12px;
  backdrop-filter:blur(8px); white-space:nowrap; z-index:30; }
#hint { position:fixed; bottom:12px; left:50%; transform:translateX(-50%);
  color:var(--muted); font-size:11px; background:var(--panel); border:1px solid var(--border);
  border-radius:999px; padding:4px 14px; backdrop-filter:blur(8px); }
#crumbs { position:fixed; top:60px; left:12px; display:none; gap:6px; align-items:center;
  background:var(--panel); border:1px solid var(--border); border-radius:10px; padding:5px 12px;
  backdrop-filter:blur(8px); font-size:12px; }
#crumbs a { color:var(--accent); cursor:pointer; text-decoration:none; }
#crumbs .sep { color:var(--muted); }
#crumbs .cur { font-weight:700; }
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
/* 架构体检区（#bar 内整行，flex-wrap 落到第二行） */
#health { display:flex; flex-wrap:wrap; gap:4px 16px; align-items:baseline; width:100%;
  border-top:1px solid var(--border); margin-top:3px; padding-top:6px; }
#bar .hgroup { display:inline-flex; gap:5px; align-items:baseline; white-space:nowrap; }
#bar .hlabel { color:var(--muted); font-size:11px; }
#bar .hval { font-size:11px; }
#bar .hbad { color:#f87171; font-size:11px; font-weight:600; }
#bar .hok { color:var(--accent); font-size:11px; }
/* 图例（画布左下一行，常驻） */
#legend { position:fixed; bottom:12px; left:12px; color:var(--muted); font-size:11px;
  background:var(--panel); border:1px solid var(--border); border-radius:999px;
  padding:4px 12px; backdrop-filter:blur(8px); max-width:calc(100vw - 240px); }
</style>
</head>
<body class="dark">
<canvas id="cv"></canvas>
""")
    sb.append("<div id=\"bar\"><span class=\"title\">${ui.title}</span><span class=\"sub\">${ui.sub} · ${totalFiles} ${ui.filesWord} / ${totalSymbols} ${ui.symWord} / ${totalLines} ${ui.lineWord}</span>")
    // 层 chips：从 JSON 的 layers 数组现读（archJson 的 layers 与 lanes 同源——
    // 模板不再向 ArchData 要第二份计数）
    for (l in Json.arrAt(root, "layers")) {
        let count = Json.intAt(l, "modules", 0)
        if (count > 0) {
            sb.append("<span class=\"chip\" data-layer=\"${Json.intAt(l, "index", 0)}\">${Json.strAt(l, "name", "")} ${count}</span>")
        }
    }
    // ⚠️ 仓颉没有 `?:` 三元 —— 文案统一取 ArchUi（单一来源；体检区、图例、
    // 驱动 JS 的违规/环字样都从这里出，不再各自 if(en) 手抄一份）
    var warnHtml = ""
    if (violationCount > 0 || cycleEdgeCount > 0) {
        warnHtml = "<span class=\"warn\">⚠ ${ui.violWord} ${violationCount} · ${ui.cycleWord} ${cycleEdgeCount}</span>"
    }
    // 视图切换：分层总览（模块/层泳道）与职责视图（角色泳道）共用一块画布。
    // chips 样式复用 .chip；.on 态由驱动维护（点击换视图重绘）。
    sb.append("<span class=\"chip vchip on\" data-view=\"arch\">${ui.layerViewWord}</span><span class=\"chip vchip\" data-view=\"role\">${ui.roleViewWord}</span>")
    sb.append("<input id=\"q\" placeholder=\"${ui.search}\"><span class=\"warn\">" + warnHtml + "</span><button class=\"btn\" id=\"fit\">${ui.fit}</button><button class=\"btn\" id=\"th\">${ui.theme}</button></div>\n")
    sb.append("<div id=\"crumbs\"></div>\n")
    sb.append("<div id=\"hint\">${ui.hint}</div>\n<div id=\"panel\"></div>\n<script>\nwindow.__ARCH__ = ")
    sb.append(json)
    sb.append(";\n</script>\n<script>\n")
    sb.append(renderJs(en))
    sb.append("\n</script>\n</body>\n</html>\n")
    return sb.toString()
}

func renderJs(en: Bool): String {
    let t = archUiText(en)
    let sb = StringBuilder()

    // 每行一个 JS 语句块；纪律：无模板字面量、无 ${、无反斜杠转义
    sb.append("(function () {\n")
    sb.append("  var DATA = window.__ARCH__;\n")
    sb.append("  var cv = document.getElementById('cv');\n")
    sb.append("  var ctx = cv.getContext('2d');\n")
    sb.append("  var panel = document.getElementById('panel');\n")
    sb.append("  var crumbs = document.getElementById('crumbs');\n")
    sb.append("  var dark = !window.matchMedia || !window.matchMedia('(prefers-color-scheme: light)').matches;\n")
    sb.append("  document.body.className = dark ? 'dark' : 'light';\n")
    // 边治理信号规范化：JSON 键是 violation/cycle，绘制读 viol/cyc——
    // 原先没有这一步：违规边从未红过（键名漂移，潜伏至今）。两份边集一起归一。
    sb.append("  (DATA.edges || []).forEach(function (e) { e.viol = !!e.violation; e.cyc = !!e.cycle; });\n")
    sb.append("  (DATA.roleEdges || []).forEach(function (e) { e.viol = !!e.violation; e.cyc = !!e.cycle; });\n")
    // 角色视图：id → 名称映射 + 7 色板（dark/light 双份；与模块 cols 错开——
    // 角色是另一套坐标系，同色会让人以为是同一种东西）
    sb.append("  var RNAMES = {}; var RORD = [];\n")
    sb.append("  (DATA.roles || []).forEach(function (r) { RNAMES[String(r.role)] = r.name; RORD.push(r.role); });\n")
    sb.append("  var ROLEPAL = {\n")
    sb.append("    dark: ['#f472b6', '#38bdf8', '#34d399', '#fbbf24', '#a78bfa', '#94a3b8', '#64748b'],\n")
    sb.append("    light: ['#db2777', '#0284c7', '#059669', '#d97706', '#7c3aed', '#64748b', '#94a3b8']\n")
    sb.append("  };\n")
    sb.append("  function roleColor(role) { var c = ROLEPAL[dark ? 'dark' : 'light']; return c[role % c.length]; }\n")
    sb.append("  var view = { x: 0, y: 0, k: 1 };\n")
    sb.append("  var level = { mode: 'arch', id: '' };\n")
    sb.append("  var sel = null; var hover = null; var layersOn = {};\n")
    sb.append("  var byId = {};\n")
    // ⚠️ `_ord` 必须在这里补：draw() 读它做错峰入场（`(m._ord || 1)`），
    // 而 archJson 的节点形状里**没有 ord 字段**（那是 scene 出口才有的）——
    // 不补的话恒取 1，错峰静默退化成「所有节点同一延迟」（同不变量 129）。
    sb.append("  DATA.modules.forEach(function (m, i) { byId[m.id] = m; layersOn[m.layer] = true; m._a = 0; m._s = 1; m._ord = i + 1; });\n")
    sb.append("  Object.keys(DATA.drilldown).forEach(function (k) { DATA.drilldown[k].nodes.forEach(function (n, i) { n._a = 0; n._s = 1; n._ord = i + 1; }); });\n")
    // 角色节点同样要初始化动画态：undefined 参与插值会变 NaN，
    // globalAlpha 变 NaN 的节点整帧不画（首测职责卡全部消失就是这个）。
    sb.append("  (DATA.roles || []).forEach(function (r, i) { r._a = 0; r._s = 1; r._ord = i + 1; });\n")
    sb.append("  var PAL = {\n")
    sb.append("    dark: { bg0:'#0d1526', bg1:'#080d1a', grid:'#1a2740', text:'#e8eef8', muted:'#8b9bb4', border:'#263650', arrow:'#64748b', accent:'#34d399',\n")
    sb.append("      cols:['#38bdf8','#a78bfa','#34d399','#fbbf24','#8ea3bd'], fills:['rgba(56,189,248,0.10)','rgba(167,139,250,0.10)','rgba(52,211,153,0.10)','rgba(251,191,36,0.08)','rgba(142,163,189,0.08)'],\n")
    sb.append("      langs:{ " + langPaletteJs(true) + " } },\n")
    sb.append("    light: { bg0:'#f7f9fd', bg1:'#eef2f8', grid:'#e2e8f2', text:'#0f172a', muted:'#64748b', border:'#d8e1ec', arrow:'#9aa8bd', accent:'#059669',\n")
    sb.append("      cols:['#0284c7','#7c3aed','#059669','#d97706','#64748b'], fills:['rgba(2,132,199,0.07)','rgba(124,58,237,0.07)','rgba(5,150,105,0.07)','rgba(217,119,6,0.07)','rgba(100,116,139,0.07)'],\n")
    sb.append("      langs:{ " + langPaletteJs(false) + " } }\n")
    sb.append("  };\n")
    sb.append("  function P() { return dark ? PAL.dark : PAL.light; }\n")
    sb.append("  function langColor(l) { var L = P().langs; return L[l] || L.module; }\n")
    sb.append("  function ease(t) { if (t < 0) return 0; if (t > 1) return 1; return 1 - Math.pow(1 - t, 3); }\n")
    sb.append("  var START = performance.now(); var LEVEL_T = START;\n")
    sb.append("  function cur() { if (level.mode === 'mod') { var d = DATA.drilldown[level.id]; if (d) return { nodes: d.nodes, edges: d.edges }; } if (level.mode === 'role') { return { nodes: DATA.roles || [], edges: DATA.roleEdges || [] }; } return { nodes: DATA.modules, edges: DATA.edges }; }\n")
    sb.append("  function isArch() { return level.mode === 'arch'; }\n")
    sb.append("  function isRole() { return level.mode === 'role'; }\n")
    // 粒子
    sb.append("  var PARTS = [];\n")
    // ⚠️ L7：粒子相位/速度原来用 Math.random() —— 而 arch.cj 的声明是
    // 「同一仓库两次渲染逐像素一致」。场景 JSON 出口确实是零随机的（相位
    // (i+1)/(n+1)），只有这个 Web 驱动在随机：同一份数据两次打开画面不同。
    // 确定性写法的代价是粒子看起来更「齐」，而一致性是可断言的契约。
    // 密度公式与场景出口统一为 weight/5 封顶 6（原先两边一个 /4 封顶 7、
    // 一个 /5 封顶 6，同一个量两个算法）。⚠️ 必须 floor 不能 round：
    // 场景侧是仓颉整数除法（截断），round 在 weight≡3,4 (mod 5) 时会多出
    // 一颗粒子——同一个量两个答案（复审 L7 残留）。
    sb.append("  function buildParts() { PARTS = []; cur().edges.forEach(function (e) { var n = Math.min(1 + Math.floor(e.weight / 5), 6); for (var i = 0; i < n; i++) { var o = (i + 1) / (n + 1); PARTS.push({ e: e, o: o, sp: 0.00012 }); } }); }\n")
    sb.append("  function bez(a, b, t) {\n")
    sb.append("    var x1, y1, x2, y2, m;\n")
    sb.append("    if (isRole()) { x1 = a.x + a.w / 2; y1 = a.y + a.h; x2 = b.x + b.w / 2; y2 = b.y; m = (y1 + y2) / 2;\n")
    sb.append("      var u4 = 1 - t;\n")
    sb.append("      return { x: u4*u4*u4*x1 + 3*u4*u4*t*x1 + 3*u4*t*t*x2 + t*t*t*x2, y: u4*u4*u4*y1 + 3*u4*u4*t*m + 3*u4*t*t*m + t*t*t*y2 }; }\n")
    sb.append("    x1 = a.x + a.w; y1 = a.y + a.h / 2; x2 = b.x; y2 = b.y + b.h / 2; m = (x1 + x2) / 2;\n")
    sb.append("    var u = 1 - t;\n")
    sb.append("    return { x: u*u*u*x1 + 3*u*u*t*m + 3*u*t*t*m + t*t*t*x2, y: u*u*u*y1 + 3*u*u*t*y1 + 3*u*t*t*y2 + t*t*t*y2 };\n")
    sb.append("  }\n")
    sb.append("  function resize() { var d = window.devicePixelRatio || 1; cv.width = innerWidth * d; cv.height = innerHeight * d; cv.style.width = innerWidth + 'px'; cv.style.height = innerHeight + 'px'; ctx.setTransform(d, 0, 0, d, 0, 0); }\n")
    sb.append("  function w2sx(x) { return x * view.k + view.x; }\n")
    sb.append("  function w2sy(y) { return y * view.k + view.y; }\n")
    sb.append("  function bounds() { var d = cur(); var b = { x0: 1e9, y0: 1e9, x1: -1e9, y1: -1e9 }; d.nodes.forEach(function (m) { if (m.x < b.x0) b.x0 = m.x; if (m.y < b.y0) b.y0 = m.y; if (m.x + m.w > b.x1) b.x1 = m.x + m.w; if (m.y + m.h > b.y1) b.y1 = m.y + m.h; }); if (isArch() && DATA.lanes) { DATA.lanes.forEach(function (L) { if (L.x < b.x0) b.x0 = L.x; if (L.y < b.y0) b.y0 = L.y; if (L.x + L.w > b.x1) b.x1 = L.x + L.w; if (L.y + L.h > b.y1) b.y1 = L.y + L.h; }); } if (isRole() && DATA.roleLanes) { DATA.roleLanes.forEach(function (L) { if (L.x < b.x0) b.x0 = L.x; if (L.y < b.y0) b.y0 = L.y; if (L.x + L.w > b.x1) b.x1 = L.x + L.w; if (L.y + L.h > b.y1) b.y1 = L.y + L.h; }); } b.x0 -= 60; b.y0 -= 90; b.x1 += 60; b.y1 += 60; return b; }\n")
    sb.append("  function fit() { var b = bounds(); var kx = innerWidth / (b.x1 - b.x0); var ky = innerHeight / (b.y1 - b.y0); var target = Math.min(kx, ky, 1.35); if (target < 0.18) target = 0.18; view.k = target; view.x = (innerWidth - (b.x0 + b.x1) * view.k) / 2; view.y = (innerHeight - (b.y0 + b.y1) * view.k) / 2; }\n")
    sb.append("  function roundRect(x, y, w, h, r) { ctx.beginPath(); ctx.moveTo(x + r, y); ctx.arcTo(x + w, y, x + w, y + h, r); ctx.arcTo(x + w, y + h, x, y + h, r); ctx.arcTo(x, y + h, x, y, r); ctx.arcTo(x, y, x + w, y, r); ctx.closePath(); }\n")
    sb.append("  function nodeColor(m) { if (isRole()) return roleColor(m.role); return isArch() ? P().cols[m.layer] : (m.external ? P().langs.module : langColor(m.lang)); }\n")
    // 面包屑
    sb.append("  function renderCrumbs() {\n")
    sb.append("    if (isArch() || isRole()) { crumbs.style.display = 'none'; crumbs.innerHTML = ''; return; }\n")
    sb.append("    crumbs.style.display = 'flex';\n")
    sb.append("    crumbs.innerHTML = '<a id=\"cr0\">' + ROOTW + '</a><span class=\"sep\"> / </span><span class=\"cur\">' + escapeHtml(level.id) + '</span>';\n")
    sb.append("    document.getElementById('cr0').addEventListener('click', function () { setLevel('arch', ''); });\n")
    sb.append("  }\n")
    sb.append("  function setLevel(mode, id) {\n")
    sb.append("    level = { mode: mode, id: id }; sel = null; hover = null; panel.style.display = 'none'; LEVEL_T = performance.now(); buildParts(); renderCrumbs(); fit();\n")
    sb.append("    try {\n")
    sb.append("      var h = mode === 'mod' ? '#module=' + encodeURIComponent(id) : (mode === 'role' ? '#view=role' : '#');\n")
    sb.append("      history.replaceState(null, '', location.pathname + location.search + h);\n")
    sb.append("    } catch (_) {}\n")
    sb.append("  }\n")
    // ── 主绘制 ──
    sb.append("  function draw(now) {\n")
    sb.append("    var p = P();\n")
    sb.append("    var g = ctx.createLinearGradient(0, 0, 0, innerHeight); g.addColorStop(0, p.bg0); g.addColorStop(1, p.bg1); ctx.fillStyle = g; ctx.fillRect(0, 0, innerWidth, innerHeight);\n")
    sb.append("    var step = 84 * view.k;\n")
    sb.append("    if (step > 15) { ctx.strokeStyle = p.grid; ctx.globalAlpha = 0.55; ctx.lineWidth = 1; ctx.beginPath();\n")
    sb.append("      var gx = view.x % step; while (gx < 0) gx += step; for (var x = gx; x < innerWidth; x += step) { ctx.moveTo(x, 0); ctx.lineTo(x, innerHeight); }\n")
    sb.append("      var gy = view.y % step; while (gy < 0) gy += step; for (var y = gy; y < innerHeight; y += step) { ctx.moveTo(0, y); ctx.lineTo(innerWidth, y); }\n")
    sb.append("      ctx.stroke(); ctx.globalAlpha = 1; }\n")
    sb.append("    var d = cur();\n")
    // 分层泳道（仅架构级）：实色淡底（按层配色低透明度）+ 左端层标签。
    // 几何来自 DATA.lanes（引擎算好的泳道矩形，archLaneRects 唯一来源）——
    // 不从模块坐标反推，反推就是驱动里的第二份布局。
    sb.append("    if (isArch()) { DATA.lanes.forEach(function (L) {\n")
    sb.append("      if (!layersOn[L.layer]) return;\n")
    sb.append("      var ap = ease((now - LEVEL_T - 80 - L.layer * 110) / 450); if (ap <= 0) return;\n")
    sb.append("      var lx = w2sx(L.x), ly = w2sy(L.y), lw = L.w * view.k, lh = L.h * view.k;\n")
    sb.append("      ctx.globalAlpha = ap * 0.9; ctx.fillStyle = p.fills[L.layer];\n")
    sb.append("      roundRect(lx, ly, lw, lh, 14); ctx.fill();\n")
    sb.append("      ctx.strokeStyle = p.border; ctx.lineWidth = 1; ctx.stroke();\n")
    sb.append("      ctx.globalAlpha = ap; ctx.fillStyle = p.cols[L.layer];\n")
    sb.append("      ctx.font = '700 12px -apple-system, sans-serif'; ctx.textAlign = 'left';\n")
    sb.append("      ctx.fillText('L' + L.layer + ' ' + L.name, lx + 14, ly + lh / 2 - 6);\n")
    sb.append("      ctx.fillStyle = p.muted; ctx.font = '11px -apple-system, sans-serif';\n")
    sb.append("      ctx.fillText(L.modules + ' ' + MODW, lx + 14, ly + lh / 2 + 12);\n")
    sb.append("      ctx.globalAlpha = 1; }); }\n")
    // 职责泳道（仅职责视图）：同几何、角色配色。左端标签 = 角色名 + 文件数。
    sb.append("    if (isRole()) { DATA.roleLanes.forEach(function (L) {\n")
    sb.append("      var ap = ease((now - LEVEL_T - 80 - L.role * 110) / 450); if (ap <= 0) return;\n")
    sb.append("      var lx = w2sx(L.x), ly = w2sy(L.y), lw = L.w * view.k, lh = L.h * view.k;\n")
    sb.append("      var rc = roleColor(L.role);\n")
    sb.append("      ctx.globalAlpha = ap * 0.9; ctx.fillStyle = rc; ctx.globalAlpha = ap * 0.07;\n")
    sb.append("      roundRect(lx, ly, lw, lh, 14); ctx.fillStyle = rc; ctx.globalAlpha = ap * 0.07; ctx.fill();\n")
    sb.append("      ctx.globalAlpha = ap * 0.9; ctx.strokeStyle = p.border; ctx.lineWidth = 1; ctx.stroke();\n")
    sb.append("      ctx.globalAlpha = ap; ctx.fillStyle = rc;\n")
    sb.append("      ctx.font = '700 12px -apple-system, sans-serif'; ctx.textAlign = 'left';\n")
    sb.append("      ctx.fillText(escapeHtml(L.name), lx + 14, ly + lh / 2 - 6);\n")
    sb.append("      ctx.fillStyle = p.muted; ctx.font = '11px -apple-system, sans-serif';\n")
    sb.append("      ctx.fillText(L.groups + ' ' + MODW, lx + 14, ly + lh / 2 + 12);\n")
    sb.append("      ctx.globalAlpha = 1; }); }\n")
    // 边
    sb.append("    d.edges.forEach(function (e) {\n")
    sb.append("      var a = byId[e.from] || findNode(e.from); var b = byId[e.to] || findNode(e.to); if (!a || !b) return;\n")
    sb.append("      if (isArch() && (!layersOn[a.layer] || !layersOn[b.layer])) return;\n")
    sb.append("      var ap = ease((now - LEVEL_T - 300 - ((a.layer || 0) + (b.layer || 0)) * 50) / 480); if (ap <= 0) return;\n")
    // hover/选中高亮邻接边，其余压暗——邻接判据 sel 与 hover 同权
    sb.append("      var adj = (sel === a.id || sel === b.id || hover === a.id || hover === b.id);\n")
    sb.append("      var hot = (sel || hover) && adj; var dim = (sel || hover) && !adj;\n")
    sb.append("      var x1, y1, x2, y2;\n")
    sb.append("      if (isRole()) {\n")
    sb.append("        // 同列布局下所有边共享一条垂直走廊——锚点按端点对散布在卡宽 60% 内\n")
    sb.append("        // （确定性哈希，零随机），多条依赖才分得开。\n")
    sb.append("        var sp1 = (((parseInt(e.from, 10) || 0) * 7 + (parseInt(e.to, 10) || 0) * 13) % 100) / 100 - 0.5;\n")
    sb.append("        var sp2 = (((parseInt(e.from, 10) || 0) * 13 + (parseInt(e.to, 10) || 0) * 7) % 100) / 100 - 0.5;\n")
    sb.append("        x1 = w2sx(a.x + a.w / 2 + sp1 * a.w * 0.6); y1 = w2sy(a.y + a.h);\n")
    sb.append("        x2 = w2sx(b.x + b.w / 2 + sp2 * b.w * 0.6); y2 = w2sy(b.y); }\n")
    sb.append("      else { x1 = w2sx(a.x + a.w); y1 = w2sy(a.y + a.h / 2); x2 = w2sx(b.x); y2 = w2sy(b.y + b.h / 2); }\n")
    sb.append("      var mx = (x1 + x2) / 2; var my2 = (y1 + y2) / 2;\n")
    sb.append("      var grad = ctx.createLinearGradient(x1, y1, x2, y2); grad.addColorStop(0, nodeColor(a)); grad.addColorStop(1, nodeColor(b));\n")
    sb.append("      ctx.strokeStyle = grad; ctx.globalAlpha = dim ? 0.05 : (hot ? 0.9 : Math.min(0.13 + e.weight * 0.05, 0.5)) * ap;\n")
    // 宽度 ∝ weight：min(3.5, 1 + weight*0.15)——与场景出口 archEdgeStroke 同式
    sb.append("      var lw = Math.min(3.5, 1 + e.weight * 0.15);\n")
    sb.append("      ctx.lineWidth = hot ? Math.max(lw, 2.6) : lw;\n")
    sb.append("      if (e.viol) { ctx.strokeStyle = '#f87171'; ctx.setLineDash([7, 5]); ctx.lineWidth = Math.max(lw, 2.2); }\n")
    sb.append("      else if (e.cyc) { ctx.strokeStyle = '#fb923c'; ctx.lineWidth = Math.max(lw, 2.0); }\n")
    // 违规边保持红虚线（入场生长动画只给实线边——原实现生长 dash 会把
    // [7,5] 覆盖掉，动画结束后违规边悄悄变成实线，红色虚线名存实亡）
    sb.append("      if (e.viol) { ctx.lineDashOffset = 0; }\n")
    sb.append("      else { var approx = (Math.abs(x2 - x1) + Math.abs(y2 - y1)) * 1.25 * ap; ctx.setLineDash([Math.max(approx, 1)]); ctx.lineDashOffset = Math.max(approx, 1) * (1 - ap); }\n")
    sb.append("      if (isRole()) { ctx.beginPath(); ctx.moveTo(x1, y1); ctx.bezierCurveTo(x1, my2, x2, my2, x2, y2); }\n")
    sb.append("      else { ctx.beginPath(); ctx.moveTo(x1, y1); ctx.bezierCurveTo(mx, y1, mx, y2, x2, y2); }\n")
    sb.append("      ctx.stroke(); ctx.setLineDash([]);\n")
    sb.append("      var ang = isRole() ? Math.atan2(y2 - my2, 0.001) : Math.atan2(y2 - my2, x2 - mx);\n")
    sb.append("      ctx.globalAlpha = (dim ? 0.05 : (hot ? 0.95 : 0.6)) * ap; ctx.fillStyle = p.arrow;\n")
    sb.append("      ctx.beginPath(); ctx.moveTo(x2, y2); ctx.lineTo(x2 - 9 * Math.cos(ang - 0.42), y2 - 9 * Math.sin(ang - 0.42)); ctx.lineTo(x2 - 9 * Math.cos(ang + 0.42), y2 - 9 * Math.sin(ang + 0.42)); ctx.closePath(); ctx.fill();\n")
    // 边中点标签：weight ≥ 30 常驻「×N」小字，hover/选中时全部边都显示；
    // 违规边中点上方常驻「违规」红字小标
    sb.append("      if (!dim) { ctx.font = '9px -apple-system, sans-serif'; ctx.textAlign = 'center';\n")
    sb.append("        ctx.globalAlpha = (hot ? 0.95 : 0.78) * ap;\n")
    sb.append("        if (e.viol) { ctx.fillStyle = '#f87171'; ctx.fillText(VIOLW, mx, my2 - 6); }\n")
    sb.append("        if (e.weight >= 30 || hot) { ctx.fillStyle = p.muted; ctx.fillText('×' + e.weight, mx, my2 + 13); }\n")
    sb.append("        ctx.textAlign = 'left'; }\n")
    sb.append("      ctx.globalAlpha = 1; });\n")
    // 粒子
    sb.append("    PARTS.forEach(function (pt) {\n")
    sb.append("      var a = findNode(pt.e.from); var b = findNode(pt.e.to); if (!a || !b) return;\n")
    sb.append("      if (isArch() && (!layersOn[a.layer] || !layersOn[b.layer])) return;\n")
    sb.append("      if (sel && sel !== a.id && sel !== b.id) return;\n")
    sb.append("      var pos = bez(a, b, (now * pt.sp + pt.o) % 1);\n")
    sb.append("      var c = nodeColor(b);\n")
    sb.append("      if (pt.e.viol) { c = '#f87171'; } else if (pt.e.cyc) { c = '#fb923c'; }\n")
    sb.append("      ctx.globalAlpha = 0.85; ctx.fillStyle = c; ctx.shadowColor = c; ctx.shadowBlur = 7;\n")
    sb.append("      ctx.beginPath(); ctx.arc(w2sx(pos.x), w2sy(pos.y), 2.1, 0, 6.2832); ctx.fill(); ctx.shadowBlur = 0; ctx.globalAlpha = 1; });\n")
    // 节点
    sb.append("    d.nodes.forEach(function (m) {\n")
    sb.append("      if (isArch() && !layersOn[m.layer]) return;\n")
    sb.append("      var target = ease((now - LEVEL_T - (isArch() ? m.layer * 150 + (m._ord || 1) * 55 : (m._ord || 1) * 26)) / 460);\n")
    sb.append("      m._a = m._a + (target - m._a) * 0.35; if (m._a < 0.001) m._a = target;\n")
    sb.append("      var isSel = sel === m.id; var isHot = hover === m.id; var dim = (sel || hover) && !isSel && !isHot;\n")
    sb.append("      var wantS = isHot ? 1.045 : (isSel ? 1.03 : 1.0); m._s = m._s + (wantS - m._s) * 0.25;\n")
    sb.append("      var c = nodeColor(m);\n")
    sb.append("      var cx = m.x + m.w / 2; var cy = m.y + m.h / 2; var w = m.w * m._s * view.k; var h = m.h * m._s * view.k;\n")
    sb.append("      var x = w2sx(cx) - w / 2; var y = w2sy(cy + (1 - m._a) * 16) - h / 2;\n")
    sb.append("      ctx.globalAlpha = m._a * (dim ? 0.28 : 1);\n")
    sb.append("      if (isSel || isHot) { ctx.shadowColor = c; ctx.shadowBlur = isSel ? 22 : 14; }\n")
    sb.append("      roundRect(x, y, w, h, 11);\n")
    sb.append("      ctx.fillStyle = dark ? 'rgba(13,21,38,0.92)' : 'rgba(255,255,255,0.94)'; ctx.fill();\n")
    sb.append("      if (m.external) { ctx.setLineDash([5, 4]); }\n")
    sb.append("      ctx.lineWidth = isSel ? 2.4 : 1.2; ctx.strokeStyle = c; ctx.stroke(); ctx.setLineDash([]); ctx.shadowBlur = 0;\n")
    sb.append("      ctx.fillStyle = c; ctx.globalAlpha = m._a * (dim ? 0.28 : 0.95); ctx.fillRect(x, y + 9, 3.2, h - 18);\n")
    sb.append("      ctx.globalAlpha = m._a * (dim ? 0.28 : 1);\n")
    sb.append("      ctx.fillStyle = p.text; ctx.font = (isSel || isHot ? '700 ' : '600 ') + Math.max(11, Math.min(14, 14 * view.k)) + 'px -apple-system, sans-serif'; ctx.textAlign = 'left';\n")
    // 架构级卡片三行：模块名 / F文件·S符号·L行 / 入出徽标+不稳定度条；
    // 下钻级标签追加「·行数」（点进子图一眼看到每个文件的体量）
    sb.append("      var label = isRole() ? (RNAMES[String(m.role)] || m.role) : (isArch() ? m.id : (m.external ? '@ ' + m.label : m.label + ' · ' + m.lines));\n")
    sb.append("      ctx.fillText(label, x + 12, y + 22, w - 22);\n")
    sb.append("      ctx.fillStyle = p.muted; ctx.font = '10px -apple-system, sans-serif';\n")
    sb.append("      var sub;\n")
    sb.append("      if (isArch() || isRole()) sub = m.files + ' ' + FILES + ' · ' + m.symbols + ' ' + SYMS + ' · ' + m.lines + ' ' + LINES;\n")
    sb.append("      else if (m.external) sub = MODULEW;\n")
    sb.append("      else sub = m.lang + ' · ' + m.symbols + ' ' + SYMS + ' · ' + m.lines + ' ' + LINES;\n")
    sb.append("      ctx.fillText(sub, x + 12, y + ((isArch() || isRole()) ? 39 : h - 12), w - 22);\n")
    // 入 N / 出 M 徽标 + 不稳定度小条（60px，按 instability% 填充；三档色：
    // >66 红 / 33..66 黄 / <33 绿——与场景出口的 token 阈值同式，只此一处语义）
    sb.append("      if (isArch() || isRole()) {\n")
    sb.append("        ctx.fillText(INW + ' ' + (m.fanIn || 0) + ' / ' + OUTW + ' ' + (m.fanOut || 0), x + 12, y + 59);\n")
    sb.append("        var inst = m.instability || 0;\n")
    sb.append("        var bw = 60; var bx = x + 96; var by = y + 52;\n")
    sb.append("        var savedA = ctx.globalAlpha;\n")
    sb.append("        ctx.globalAlpha = savedA * 0.35; ctx.fillStyle = p.arrow; ctx.fillRect(bx, by, bw, 5);\n")
    sb.append("        ctx.globalAlpha = savedA;\n")
    sb.append("        var ic = inst > 66 ? '#f87171' : (inst >= 33 ? '#fbbf24' : '#34d399');\n")
    sb.append("        ctx.fillStyle = ic; ctx.fillRect(bx, by, bw * inst / 100, 5);\n")
    sb.append("        ctx.font = '9px -apple-system, sans-serif'; ctx.fillText(inst + '%', bx + bw + 6, by + 7);\n")
    sb.append("      }\n")
    // 职责构成条（架构级模块卡独有）：roleMix 7 桶按占比水平铺一条 4px
    // 迷你堆叠条——模块卡从「有多少文件」升级为「是一些什么文件」。
    sb.append("      if (isArch() && m.roleMix) { var mt = 0; var mi;\n")
    sb.append("        for (mi = 0; mi < m.roleMix.length; mi++) mt += m.roleMix[mi];\n")
    sb.append("        if (mt > 0) { var mo = 0; var mw = w - 24;\n")
    sb.append("          for (mi = 0; mi < m.roleMix.length; mi++) { var mf = m.roleMix[mi] / mt; if (mf <= 0) continue;\n")
    sb.append("            ctx.fillStyle = roleColor(mi); ctx.globalAlpha = m._a * (dim ? 0.28 : 0.8);\n")
    sb.append("            ctx.fillRect(x + 12 + mo * mw, y + h - 14, Math.max(1, mf * mw - 1), 4); mo += mf; }\n")
    sb.append("          ctx.globalAlpha = m._a * (dim ? 0.28 : 1); } }\n")
    // 语言色点（文件级）
    sb.append("      if (!isArch() && !m.external) { ctx.fillStyle = langColor(m.lang); ctx.beginPath(); ctx.arc(x + w - 14, y + 15, 3.4, 0, 6.2832); ctx.fill(); }\n")
    // 可下钻提示（架构级：有下钻子图的模块右上角小箭头）
    sb.append("      if (isArch() && DATA.drilldown[m.id]) { ctx.fillStyle = p.muted; ctx.font = '10px -apple-system, sans-serif'; ctx.textAlign = 'right'; ctx.fillText('+', x + w - 10, y + 18); ctx.textAlign = 'left'; }\n")
    sb.append("      ctx.globalAlpha = 1; });\n")
    // ── 小地图 ──
    // 模块数 ≤ 8 时整个架构一屏即读，色块小地图只有迷惑性（无数标签的彩色条）——
    // 大仓库（>8 模块）平移/缩放定位才需要它
    sb.append("    var MW = 176, MH = 118, MP = 10;\n")
    sb.append("    var showMini = DATA.modules.length > 8;\n")
    sb.append("    var mx0 = innerWidth - MW - 14, my0 = innerHeight - MH - 14;\n")
    sb.append("    if (showMini) {\n")
    sb.append("    ctx.globalAlpha = 0.85; ctx.fillStyle = dark ? 'rgba(10,16,30,0.85)' : 'rgba(255,255,255,0.9)';\n")
    sb.append("    roundRect(mx0, my0, MW, MH, 10); ctx.fill(); ctx.strokeStyle = p.border; ctx.lineWidth = 1; ctx.stroke(); ctx.globalAlpha = 1;\n")
    sb.append("    var b = bounds(); var pad = 8;\n")
    sb.append("    var sc = Math.min((MW - pad * 2) / (b.x1 - b.x0), (MH - pad * 2) / (b.y1 - b.y0));\n")
    sb.append("    function mmx(x) { return mx0 + pad + (x - b.x0) * sc; }\n")
    sb.append("    function mmy(y) { return my0 + pad + (y - b.y0) * sc; }\n")
    sb.append("    d.nodes.forEach(function (m) { ctx.fillStyle = nodeColor(m); ctx.globalAlpha = 0.8; ctx.fillRect(mmx(m.x), mmy(m.y), Math.max(3, m.w * sc), Math.max(2, m.h * sc)); });\n")
    sb.append("    ctx.globalAlpha = 1; ctx.strokeStyle = p.accent; ctx.lineWidth = 1.2;\n")
    sb.append("    var vx0 = (0 - view.x) / view.k; var vy0 = (0 - view.y) / view.k;\n")
    sb.append("    var vx1 = (innerWidth - view.x) / view.k; var vy1 = (innerHeight - view.y) / view.k;\n")
    sb.append("    ctx.strokeRect(mmx(Math.max(vx0, b.x0)), mmy(Math.max(vy0, b.y0)), (Math.min(vx1, b.x1) - Math.max(vx0, b.x0)) * sc, (Math.min(vy1, b.y1) - Math.max(vy0, b.y0)) * sc);\n")
    sb.append("    }\n")
    sb.append("    cv._mm = { x0: mx0, y0: my0, w: MW, h: MH, b: b, sc: sc, pad: pad };\n")
    sb.append("  }\n")
    sb.append("  function findNode(id) { var d = cur(); for (var i = 0; i < d.nodes.length; i++) { if (d.nodes[i].id === id) return d.nodes[i]; } return byId[id] || null; }\n")
    sb.append("  function loop() { draw(performance.now()); requestAnimationFrame(loop); }\n")
    // 交互
    sb.append("  function hitTest(px, py) { var d = cur(); for (var i = d.nodes.length - 1; i >= 0; i--) { var m = d.nodes[i]; if (isArch() && !layersOn[m.layer]) continue; var x = w2sx(m.x); var y = w2sy(m.y); if (px >= x && px <= x + m.w * view.k && py >= y && py <= y + m.h * view.k) return m; } return null; }\n")
    sb.append("  function center(m) { view.x = innerWidth / 2 - (m.x + m.w / 2) * view.k; view.y = innerHeight / 2 - (m.y + m.h / 2) * view.k; }\n")
    // ⚠️ L6：原来只转 `<` `>` —— 而详情面板把名字塞进 data-id="..." 属性，
    // 一个含双引号的目录名就能闭合属性并注入（需恶意命名的仓库目录，故低危，
    // 但修起来是零成本的）。属性上下文必须连引号一起转。
    // 引号字符在 JS 侧用 String.fromCharCode 取，避免在仓颉字符串里写 "
    sb.append("  function escapeHtml(s) { var Q = String.fromCharCode(34); var A = String.fromCharCode(39);" +
        " return String(s).split('&').join('&amp;').split('<').join('&lt;')" +
        ".split('>').join('&gt;').split(Q).join('&quot;').split(A).join('&#39;'); }\n")

    sb.append("  function showPanel(m) {\n")
    sb.append("    if (!isArch() && m.external) return;\n")
    sb.append("    var outs = []; var ins = [];\n")
    sb.append("    cur().edges.forEach(function (e) { if (e.from === m.id) outs.push(e); if (e.to === m.id) ins.push(e); });\n")
    sb.append("    var h = '<h2>' + escapeHtml(isRole() ? (RNAMES[String(m.role)] || m.role) : (m.label || m.id)) + '</h2>';\n")
    sb.append("    if (isRole()) { h += '<div class=\"meta\">' + escapeHtml(m.files) + ' ' + FILES + '</div>'; }\n")
    sb.append("    else if (isArch()) { var ln = DATA.layers[m.layer] ? DATA.layers[m.layer].name : m.layer; h += '<div class=\"meta\">' + LAYERW + ' L' + m.layer + ' · ' + ln + '</div>'; }\n")
    // ⚠️ 两处实跑修：
    //   ① 文件级子视图的节点是 **DrillNode（没有 `files` 字段）**，面板统计沿用
    //      ArchModule 的字段会显示 "undefined 文件" ⇒ 统计必须按视图分支；
    //   ② 原 meta 行拼了 `'》'.length` —— 那是恒等于 1 的**幻影字面量**（面板显示 "· L1"）。
    sb.append("    else { h += '<div class=\"meta\">' + escapeHtml(m.lang) + '</div>'; }\n")
    sb.append("    var stats = isArch() ? (m.files + ' ' + FILES + ' · ' + m.symbols + ' ' + SYMS + ' · ' + m.lines + ' ' + LINES) : (m.symbols + ' ' + SYMS + ' · ' + m.lines + ' ' + LINES);\n")
    sb.append("    h += '<div>' + stats + '</div>';\n")
    // 治理信号一行（架构级）：入/出与不稳定度——数据在 archJson 里恒发，
    // 面板不显示就等于没说（不变量 17：披露必须有人渲染）
    sb.append("    if (isArch() || isRole()) { h += '<div>' + INW + ' ' + (m.fanIn || 0) + ' / ' + OUTW + ' ' + (m.fanOut || 0) + ' · ' + INSTW + ' ' + (m.instability || 0) + '%</div>'; }\n")
    // 职责面板：代表文件（按行数取前 8）——归错泳道在这里看得见，改起来有据可依
    sb.append("    if (isRole() && m.topFiles && m.topFiles.length) { h += '<h3>' + FILES + '</h3>'; m.topFiles.forEach(function (f) { h += '<div class=\"meta\">' + escapeHtml(f.split('/').pop()) + '</div>'; }); }\n")
    // 模块面板：入口文件（roleMix 之外的第二份技术事实——程序从哪里启动）
    sb.append("    if (isArch() && m.entryFiles && m.entryFiles.length) { h += '<h3>' + ENTRYW + '</h3>'; m.entryFiles.forEach(function (f) { h += '<div class=\"meta\">' + escapeHtml(f) + '</div>'; }); }\n")
    sb.append("    if (m.langs) { h += '<div>'; m.langs.forEach(function (l) { h += '<span class=\"langtag\">' + escapeHtml(l) + '</span>'; }); h += '</div>'; }\n")
    sb.append("    h += '<h3>' + OUT + '</h3>';\n")
    sb.append("    if (outs.length === 0) h += '<div class=\"meta\">' + NONE + '</div>';\n")
    sb.append("    function depName(id) { return isRole() ? (RNAMES[id] || id) : id; }\n")
    sb.append("    outs.sort(function (a, b) { return b.weight - a.weight; }).forEach(function (e) { h += '<div class=\"dep\" data-id=\"' + escapeHtml(e.to) + '\"><span>' + escapeHtml(depName(e.to)) + '</span><span class=\"w\">' + e.weight + '</span></div>'; });\n")
    sb.append("    h += '<h3>' + IN + '</h3>';\n")
    sb.append("    if (ins.length === 0) h += '<div class=\"meta\">' + NONE + '</div>';\n")
    sb.append("    ins.sort(function (a, b) { return b.weight - a.weight; }).forEach(function (e) { h += '<div class=\"dep\" data-id=\"' + escapeHtml(e.from) + '\"><span>' + escapeHtml(depName(e.from)) + '</span><span class=\"w\">' + e.weight + '</span></div>'; });\n")
    sb.append("    h += '<div class=\"meta\" style=\"margin-top:10px\">' + ESC + '</div>';\n")
    sb.append("    panel.innerHTML = h; panel.style.display = 'block';\n")
    sb.append("    panel.querySelectorAll('.dep').forEach(function (el) { el.addEventListener('click', function () { var id = el.getAttribute('data-id'); var m2 = findNode(id); if (m2) { sel = m2.id; showPanel(m2); center(m2); } else if (id.indexOf('@module:') === 0) { setLevel('mod', id.slice(8)); } }); });\n")
    sb.append("  }\n")
    sb.append("  function hidePanel() { sel = null; panel.style.display = 'none'; }\n")
    sb.append("  var drag = null; var mmDrag = false;\n")
    sb.append("  cv.addEventListener('mousedown', function (e) {\n")
    sb.append("    var mm = cv._mm; if (mm && e.clientX >= mm.x0 && e.clientX <= mm.x0 + mm.w && e.clientY >= mm.y0 && e.clientY <= mm.y0 + mm.h) { mmDrag = true; var wx = mm.b.x0 + (e.clientX - mm.x0 - mm.pad) / mm.sc; var wy = mm.b.y0 + (e.clientY - mm.y0 - mm.pad) / mm.sc; view.x = innerWidth / 2 - wx * view.k; view.y = innerHeight / 2 - wy * view.k; return; }\n")
    sb.append("    drag = { x: e.clientX, y: e.clientY, tx: view.x, ty: view.y, moved: false }; cv.className = 'drag'; });\n")
    sb.append("  window.addEventListener('mousemove', function (e) {\n")
    sb.append("    if (mmDrag) { var mm = cv._mm; if (!mm) return; var wx = mm.b.x0 + (e.clientX - mm.x0 - mm.pad) / mm.sc; var wy = mm.b.y0 + (e.clientY - mm.y0 - mm.pad) / mm.sc; view.x = innerWidth / 2 - wx * view.k; view.y = innerHeight / 2 - wy * view.k; return; }\n")
    sb.append("    if (drag) { var dx = e.clientX - drag.x; var dy = e.clientY - drag.y; if (Math.abs(dx) + Math.abs(dy) > 4) drag.moved = true; view.x = drag.tx + dx; view.y = drag.ty + dy; return; }\n")
    sb.append("    var m = hitTest(e.clientX, e.clientY); hover = m ? m.id : null; cv.className = m ? 'point' : '';\n")
    sb.append("  });\n")
    sb.append("  window.addEventListener('mouseup', function (e) {\n")
    sb.append("    if (mmDrag) { mmDrag = false; return; }\n")
    sb.append("    if (!drag) return; var wasClick = !drag.moved; cv.className = hover ? 'point' : ''; drag = null;\n")
    sb.append("    if (wasClick) { var m = hitTest(e.clientX, e.clientY); if (m) { if (!isArch() && m.external) { setLevel('mod', m.id.slice(8)); return; } sel = m.id; showPanel(m); } else { hidePanel(); } }\n")
    sb.append("  });\n")
    sb.append("  cv.addEventListener('dblclick', function (e) {\n")
    sb.append("    var m = hitTest(e.clientX, e.clientY);\n")
    sb.append("    if (isArch() && m && DATA.drilldown[m.id]) { setLevel('mod', m.id); return; }\n")
    sb.append("    if (!isArch() && !m) { setLevel('arch', ''); }\n")
    sb.append("  });\n")
    sb.append("  cv.addEventListener('wheel', function (e) { e.preventDefault(); var f = e.deltaY < 0 ? 1.12 : 1 / 1.12; var nk = Math.max(0.12, Math.min(3.5, view.k * f)); var r = nk / view.k; view.x = e.clientX - (e.clientX - view.x) * r; view.y = e.clientY - (e.clientY - view.y) * r; view.k = nk; }, { passive: false });\n")
    sb.append("  window.addEventListener('keydown', function (e) { if (e.key === 'Escape') { if (!isArch()) setLevel('arch', ''); else hidePanel(); } });\n")
    sb.append("  window.addEventListener('resize', resize);\n")
    sb.append("  document.querySelectorAll('.chip').forEach(function (el) {\n")
    sb.append("    var L = parseInt(el.getAttribute('data-layer'), 10); el.style.borderColor = P().cols[L];\n")
    sb.append("    el.addEventListener('click', function () { layersOn[L] = !layersOn[L]; el.className = layersOn[L] ? 'chip' : 'chip off'; }); });\n")
    sb.append("  document.getElementById('fit').addEventListener('click', function () { sel = null; hover = null; panel.style.display = 'none'; fit(); });\n")
    sb.append("  document.getElementById('th').addEventListener('click', function () { dark = !dark; document.body.className = dark ? 'dark' : 'light'; });\n")
    sb.append("  document.getElementById('q').addEventListener('keydown', function (e) { if (e.key !== 'Enter') return; var q = e.target.value.toLowerCase(); if (!q) return; var hit = null; cur().nodes.forEach(function (m) { var t = (m.id + ' ' + (m.label || '')).toLowerCase(); if (!hit && t.indexOf(q) >= 0) hit = m; }); if (hit) { sel = hit.id; showPanel(hit); center(hit); } });\n")
    sb.append("  var FILES = " + jsStr(t.filesWord) + ", SYMS = " + jsStr(t.symWord) + ", LINES = " + jsStr(t.lineWord) + ";\n")
    sb.append("  var OUT = " + jsStr(t.depsOut) + ", IN = " + jsStr(t.depsIn) + ", NONE = " + jsStr(t.none) + ";\n")
    // ⚠️ 必须取 `t.moduleWord` / `t.root`（ArchUi 两种语言都有），不能硬编码中文 ——
    // 否则英文模式（cli 按 config.language 传 en=true）下面板与面包屑会出现中文。
    sb.append("  var LAYERW = " + jsStr(t.layerWord) + ", ESC = " + jsStr(t.closeHint) + ", MODULEW = " + jsStr(t.moduleWord) + ", ROOTW = " + jsStr(t.root) + ";\n")
    // 深度技术呈现文案（单一来源 ArchUi）：卡片徽标 / 顶栏体检 / 图例
    sb.append("  var INW = " + jsStr(t.inShort) + ", OUTW = " + jsStr(t.outShort) + ", MODW = " + jsStr(t.modulesWord) + ", INSTW = " + jsStr(t.instWord) + ";\n")
    sb.append("  var HEALTHW = " + jsStr(t.healthWord) + ", FANINW = " + jsStr(t.fanInWord) + ", FANOUTW = " + jsStr(t.fanOutWord) + ";\n")
    sb.append("  var VIOLW = " + jsStr(t.violWord) + ", NOVIOLW = " + jsStr(t.noViolWord) + ", CYCW = " + jsStr(t.cycleWord) + ", NOCYCW = " + jsStr(t.noCycleWord) + ";\n")
    sb.append("  var ENTRYW = " + jsStr(t.entryWord) + ", RVIOLW = " + jsStr(t.roleViolWord) + ", COMPW = " + jsStr(t.compositionWord) + ";\n")
    sb.append("  var LEGENDW = " + jsStr(t.legendText) + ", OTHERW = " + jsStr(t.otherLayerNote) + ";\n")
    sb.append("  var en = " + (if (en) { "true" } else { "false" }) + ";\n")
    // ── 架构体检区（#bar 内整行）：总计 / 扇入 Top3 / 扇出 Top3 / 违规清单 / 环清单 ──
    // 全部从 DATA 现算——这份页面的数据就是 archJson，体检区不许另要第二份数据。
    // Top3 排序 tie-break 用模块 id：同值时顺序确定（与引擎侧确定性同一纪律）。
    sb.append("  function topFan(key) { return DATA.modules.slice().sort(function (x, y) { var d = (y[key] || 0) - (x[key] || 0); if (d !== 0) return d; return x.id < y.id ? -1 : 1; }).slice(0, 3); }\n")
    sb.append("  function buildHealth() {\n")
    sb.append("    var h = '<span class=\"hgroup\"><span class=\"hlabel\">' + HEALTHW + '</span><span class=\"hval\">' + DATA.modules.length + ' ' + MODW + ' · ' + DATA.totalFiles + ' ' + FILES + ' · ' + DATA.totalSymbols + ' ' + SYMS + ' · ' + DATA.totalLines + ' ' + LINES + '</span></span>';\n")
    sb.append("    h += '<span class=\"hgroup\"><span class=\"hlabel\">' + FANINW + ' Top3</span><span class=\"hval\">' + topFan('fanIn').map(function (m) { return escapeHtml(m.id) + ' ' + (m.fanIn || 0); }).join(' · ') + '</span></span>';\n")
    sb.append("    h += '<span class=\"hgroup\"><span class=\"hlabel\">' + FANOUTW + ' Top3</span><span class=\"hval\">' + topFan('fanOut').map(function (m) { return escapeHtml(m.id) + ' ' + (m.fanOut || 0); }).join(' · ') + '</span></span>';\n")
    sb.append("    var vp = (DATA.warnings && DATA.warnings.violationPairs) || [];\n")
    sb.append("    if (vp.length === 0) h += '<span class=\"hgroup\"><span class=\"hlabel\">' + VIOLW + '</span><span class=\"hok\">' + NOVIOLW + '</span></span>';\n")
    sb.append("    else h += '<span class=\"hgroup\"><span class=\"hlabel\">' + VIOLW + '</span><span class=\"hbad\">' + vp.map(function (pr) { return escapeHtml(pr.from) + ' → ' + escapeHtml(pr.to); }).join(' · ') + '</span></span>';\n")
    sb.append("    var cm = (DATA.warnings && DATA.warnings.cycleModules) || [];\n")
    sb.append("    if (cm.length === 0) h += '<span class=\"hgroup\"><span class=\"hlabel\">' + CYCW + '</span><span class=\"hok\">' + NOCYCW + '</span></span>';\n")
    sb.append("    else h += '<span class=\"hgroup\"><span class=\"hlabel\">' + CYCW + '</span><span class=\"hbad\">' + cm.map(function (n) { return escapeHtml(n); }).join(' · ') + '</span></span>';\n")
    sb.append("    var rv = DATA.roleViolations || 0;\n")
    sb.append("    if (rv > 0) h += '<span class=\"hgroup\"><span class=\"hlabel\">' + RVIOLW + '</span><span class=\"hbad\">' + rv + '</span></span>';\n")
    sb.append("    var box = document.createElement('div'); box.id = 'health'; box.innerHTML = h;\n")
    sb.append("    document.getElementById('bar').appendChild(box);\n")
    sb.append("  }\n")
    // ── 图例（画布左下一行）；存在未分层模块时追加一句坐标说明（数据驱动的诚实）──
    sb.append("  function buildLegend() {\n")
    sb.append("    var txt = LEGENDW; var other = false;\n")
    sb.append("    DATA.modules.forEach(function (m) { if (m.layer === 4) other = true; });\n")
    sb.append("    if (other) txt += ' · ' + OTHERW;\n")
    sb.append("    var lg = document.createElement('div'); lg.id = 'legend'; lg.textContent = txt;\n")
    sb.append("    document.body.appendChild(lg);\n")
    sb.append("  }\n")
    // 截断披露：archJson 恒发 truncated，但驱动原先从不读它 —— 键在数据里、
    // 页面不读 = 数据说了没人听见。命中时页面顶部渲染警示行（文案随语言）。
    // ⚠️ 仓颉没有 `?:` 三元 —— if 表达式先物化成局部量再拼接（AGENTS 编码约定）
    let truncWord = if (en) { "Warning: file cap reached — partial scan, not the full repository" } else { "⚠ 文件数达上限——部分扫描，不是全量" }
    sb.append("  var TRUNCW = " + jsStr(truncWord) + ";\n")
    sb.append("  if (DATA.truncated) { var tb = document.createElement('div'); tb.id = 'truncbar'; tb.textContent = TRUNCW; document.body.appendChild(tb); }\n")
    sb.append("  buildHealth(); buildLegend();\n")
    sb.append("  resize(); fit(); buildParts(); renderCrumbs();\n")
    // 视图切换 chips：职责/分层共用一块画布（setLevel 换 mode 重算布局适配）
    sb.append("  document.querySelectorAll('.vchip').forEach(function (c) { c.addEventListener('click', function () {\n")
    sb.append("    document.querySelectorAll('.vchip').forEach(function (x) { x.classList.remove('on'); });\n")
    sb.append("    c.classList.add('on'); setLevel(c.getAttribute('data-view'), '');\n");
    sb.append("  }); });\n")
    sb.append("  try {\n")
    sb.append("    var hm = (location.hash || '').match(/^#module=(.+)$/);\n")
    sb.append("    if (hm && DATA.drilldown[decodeURIComponent(hm[1])]) { setLevel('mod', decodeURIComponent(hm[1])); }\n")
    sb.append("    else if ((location.hash || '').indexOf('#view=role') === 0 && (DATA.roles || []).length) { setLevel('role', ''); }\n")
    sb.append("  } catch (_) {}\n")
    sb.append("  loop();\n")
    // ── 注入式驱动入口：契约的正式出口 ──
    // 任何提供标准 Canvas2D API 的实现（OffscreenCanvas / node-canvas /
    // Skia 绑定 / CoreGraphics 包装）都可以把自己的 ctx 传给 renderTo，
    // draw() 只调用上文审计过的那组标准方法，绘制路径不碰 DOM。
    sb.append("  window.MoongitArch = {\n")
    sb.append("    scene: DATA,\n")
    sb.append("    canvas: cv,\n")
    sb.append("    setTheme: function (d) { dark = d; document.body.className = dark ? 'dark' : 'light'; },\n")
    sb.append("    fit: fit,\n")
    sb.append("    draw: function (now) { draw(now || performance.now()); },\n")
    sb.append("    renderTo: function (ctx2, w, h, now) {\n")
    sb.append("      var keep = ctx; var ow = innerWidth; var oh = innerHeight;\n")
    sb.append("      ctx = ctx2;\n")
    sb.append("      try {\n")
    sb.append("        Object.defineProperty(window, 'innerWidth', { value: w, configurable: true });\n")
    sb.append("        Object.defineProperty(window, 'innerHeight', { value: h, configurable: true });\n")
    sb.append("        draw(now || performance.now());\n")
    sb.append("      } finally {\n")
    sb.append("        Object.defineProperty(window, 'innerWidth', { value: ow, configurable: true });\n")
    sb.append("        Object.defineProperty(window, 'innerHeight', { value: oh, configurable: true });\n")
    sb.append("        ctx = keep;\n")
    sb.append("      }\n")
    sb.append("    }\n")
    sb.append("  };\n")
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
