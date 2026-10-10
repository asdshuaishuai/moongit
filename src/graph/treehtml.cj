// graph/treehtml.cj — 代码图谱导出（图树主轴 × 置信度，左树右详情双栏）。
//
// 【形态】左树右详情：左栏 = 项目/目录/文件/符号四级树（行内 ⚠N 疑点徽标 +
// 全局分数 chip），右栏 = 单符号详情（源码 / 置信度 / 关系 三 tab，切换 =
// 替换而非追加）。原 deepOrca「引用方|焦点|被调」三列卡片形态已废弃——
// 关系信息收编进「关系」tab 的单列两段列表。
//
// 【堆叠纪律】整页布局块恰为 2（[data-pane=tree] + [data-pane=detail]），
// 两栏间仅 1px 分隔线；独立滚动区恰为 2（树栏 + 当前激活 tab）；详情内容
// 只有代码块一层 1px 边框；无 fixed/absolute 内容浮层（<880px 时详情改
// 覆盖式单面板是唯一例外，由窄屏单块规则强制）。
//
// 【代码高亮】符号实码内嵌（引擎契约截 40 行，页面尾部披露），仓颉
// tokenizer 四类着色（关键字/字符串/注释/数字），深浅主题各一组 token。
//
// 【数据】`graph tree --json` 契约 + functionGraphData（函数/调用边/实码）
// + confidence（分数/astNote 降级说明/平铺 findings 带证据与维度）。
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
            Json.set(o, "lang", Json.of(detectLang(fe.relPath)))
            Json.set(o, "findings", JArr(fd))
            Json.set(o, "weight", Json.of(maxW))
            // 实码是否命中引擎 40 行截断契约（graph-scene-schema.md:70-76：截断必须披露）
            Json.set(o, "trunc", Json.of(bodyEnd - bodyStart + 1 > 40))
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

// MARK: - 置信度内嵌（页面「置信度」tab 的数据源）

/// 置信度报告的页面内嵌形态：分数（L0 分数 chip）+ astNote（astUsed=false
/// 时顶部降级披露，审计 M2：不可静默）+ 平铺 findings（每条带证据与维度，
/// 证据必须自足——人不开编辑器就能判断，confidence.cj:266 注释原话）。
/// 限流披露两个布尔：全量 400 条封顶 / 同类每文件 6 条封顶
/// （CONF_MAX_FINDINGS / CONF_MAX_PER_KIND_PER_FILE，confidence.cj:258-260）。
func confidenceEmbedJson(conf: ConfidenceReport): JsonValue {
    let o = Json.obj()
    Json.set(o, "score", Json.of(conf.score))
    Json.set(o, "astUsed", Json.of(conf.astUsed))
    Json.set(o, "astNote", Json.of(conf.astNote))
    Json.set(o, "cappedTotal", Json.of(Int64(conf.findings.size) >= CONF_MAX_FINDINGS))
    let perKind = HashMap<String, Int64>()
    var cappedKind = false
    for (f in conf.findings) {
        let key = f.file + "|" + flawId(f.kind)
        let c = match (perKind.get(key)) {
            case Some(v) => v + 1
            case None => 1
        }
        perKind[key] = c
        if (c >= CONF_MAX_PER_KIND_PER_FILE) { cappedKind = true }
    }
    Json.set(o, "cappedKind", Json.of(cappedKind))
    let fs = ArrayList<JsonValue>()
    for (f in conf.findings) {
        let d = Json.obj()
        Json.set(d, "file", Json.of(f.file))
        Json.set(d, "line", Json.of(f.line))
        Json.set(d, "kind", Json.of(flawId(f.kind)))
        Json.set(d, "weight", Json.of(flawWeight(f.kind)))
        Json.set(d, "dim", Json.of(dimensionId(flawDimension(f.kind))))
        Json.set(d, "symbol", Json.of(f.symbol))
        Json.set(d, "evidence", Json.of(f.evidence))
        fs.add(d)
    }
    Json.set(o, "findings", JArr(fs))
    return o
}

/// 语言点色（L2 文件行的 6px 圆点）：沿用 scene 契约 themes.langs 的
/// 既有 token（graph-scene-schema.md:65-66；色值与 archscene.cj 同源，
/// 不新增色相）。无 token 的语言由页面回退中性灰。
func langThemesJson(): JsonValue {
    let dark = Json.obj()
    Json.set(dark, "swift", Json.of("#f05138"))
    Json.set(dark, "cangjie", Json.of("#f7801e"))
    Json.set(dark, "ts", Json.of("#3178c6"))
    Json.set(dark, "python", Json.of("#3572a5"))
    Json.set(dark, "go", Json.of("#00add8"))
    Json.set(dark, "rust", Json.of("#dea584"))
    Json.set(dark, "java", Json.of("#b07219"))
    Json.set(dark, "kotlin", Json.of("#a97bff"))
    Json.set(dark, "c", Json.of("#555555"))
    Json.set(dark, "module", Json.of("#94a3b8"))
    let light = Json.obj()
    Json.set(light, "swift", Json.of("#f05138"))
    Json.set(light, "cangjie", Json.of("#de6d10"))
    Json.set(light, "ts", Json.of("#3178c6"))
    Json.set(light, "python", Json.of("#3572a5"))
    Json.set(light, "go", Json.of("#00869b"))
    Json.set(light, "rust", Json.of("#b7410e"))
    Json.set(light, "java", Json.of("#b07219"))
    Json.set(light, "kotlin", Json.of("#7c4dff"))
    Json.set(light, "c", Json.of("#444444"))
    Json.set(light, "module", Json.of("#64748b"))
    let th = Json.obj()
    Json.set(th, "dark", dark)
    Json.set(th, "light", light)
    return th
}

// MARK: - HTML 交付物（左树右详情双栏）

func langAttr(en: Bool): String {
    return if (en) { "en" } else { "zh-CN" }
}

public func treeCanvasHtml(graph: CodeGraph, depth: Int64, en: Bool, findings: ConfidenceReport): String {
    let root = fullGraphJson(graph, depth)
    Json.set(root, "functionGraph", functionGraphData(graph, findings))
    Json.set(root, "confidence", confidenceEmbedJson(findings))
    Json.set(root, "langThemes", langThemesJson())
    Json.set(root, "project", Json.of(basename(graph.root)))
    let json = jsonSafeForEmbed(Json.pretty(root))
    let title = if (en) { "Code Graph" } else { "代码图谱" }
    let searchPh = if (en) { "focus a symbol…" } else { "聚焦符号，如 parseFlags" }
    let treeLabel = if (en) { "code graph tree" } else { "代码图谱树" }
    let detailLabel = if (en) { "symbol detail" } else { "符号详情" }
    let emptyHint = if (en) { "Select a symbol on the left" } else { "在左侧选择一个符号" }
    let backLabel = if (en) { "Back" } else { "返回" }
    let dividerTitle = if (en) { "drag to resize · double-click to reset" } else { "拖拽调整宽度，双击复位" }
    let langTag = if (en) { "en" } else { "zh-CN" }
    let sb = StringBuilder()
    sb.append("<!DOCTYPE html>\n<html lang=\"${langTag}\">\n<head>\n<meta charset=\"UTF-8\">\n")
    sb.append("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n")
    sb.append("<meta name=\"generator\" content=\"moonGit graph tree (Cangjie engine, deterministic layout)\">\n")
    sb.append("<title>${title} · ${graph.files.size} files</title>\n")
    sb.append("""
<style>
:root, body.dark {
  --hue-focus:#38bdf8; --focus-ring:rgba(56,189,248,0.4);
  --bg:#0b1120; --bg2:#0f172a; --text:#e2e8f0; --text2:#b3bfd4;
  --muted:#8b9bb4; --muted3:#55637d;
  --border:#24334d; --code-bg:#0a101e;
  --bad:#f87171; --warn:#fbbf24; --gray:#8b9bb4; --health:#2dd4bf;
}
body.light {
  --hue-focus:#0284c7; --focus-ring:rgba(2,132,199,0.4);
  --bg:#f6f8fb; --bg2:#ffffff; --text:#0f172a; --text2:#3b4a63;
  --muted:#64748b; --muted3:#94a3b8;
  --border:#d5deeb; --code-bg:#f1f5f9;
  --bad:#dc2626; --warn:#d97706; --gray:#64748b; --health:#0d9488;
}
* { margin:0; padding:0; box-sizing:border-box; }
[hidden] { display:none !important; }
html, body { height:100%; }
body { background:var(--bg); color:var(--text); overflow:hidden;
  font:12.5px/1.5 -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,'PingFang SC','Microsoft YaHei',sans-serif; }
button { font-family:inherit; }
:focus-visible { outline:2px solid var(--focus-ring); outline-offset:-2px; }
.shell { display:flex; height:100%; position:relative; }
[data-pane="tree"] { flex:none; width:296px; max-width:420px; min-width:240px; background:var(--bg2);
  display:flex; flex-direction:column; }
[data-pane="detail"] { flex:1; min-width:0; background:var(--bg); display:flex; flex-direction:column; }
#divider { flex:none; width:1px; background:var(--border); cursor:col-resize; }
body.dragging { cursor:col-resize; user-select:none; }
/* ── 树栏头部：L0 项目锚点行（bg2，与下方滚动区拉开半档明度）+ 搜索 ── */
.tree-head { flex:none; background:var(--bg2); border-bottom:1px solid var(--border); }
#root-row { height:36px; display:flex; align-items:center; gap:8px; padding:0 12px 0 8px; cursor:default; }
#root-row:hover { background:rgba(148,163,184,0.06); }
#root-row .rname { flex:1; min-width:0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap;
  font-size:13px; font-weight:600; }
.searchrow { padding:6px 12px 10px 8px; }
.searchrow input { width:100%; height:26px; background:var(--bg); border:1px solid var(--border);
  border-radius:6px; color:var(--text); font:12px -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,'PingFang SC','Microsoft YaHei',sans-serif;
  padding:0 8px; outline:none; }
.searchrow input:focus { border-color:var(--hue-focus); }
.searchrow input::placeholder { color:var(--muted3); }
/* ── 树滚动区（全页仅有的两个滚动容器之一）── */
.tree-scroll { flex:1; overflow-y:auto; overflow-x:hidden; background:var(--bg); outline:none; position:relative; }
.tree-canvas { position:relative; width:100%; }
/* ── 行（虚拟滚动：绝对定位，top 由驱动计算）── */
.row { position:absolute; left:0; right:0; display:flex; align-items:center; padding-right:12px; cursor:default; }
.row:hover { background:rgba(148,163,184,0.06); }
.row.sel { background:rgba(56,189,248,0.10); }
.row.sel::before { content:''; position:absolute; left:0; top:0; bottom:0; width:2px; background:var(--hue-focus); }
.row .guide { position:absolute; top:0; bottom:0; width:1px; background:rgba(36,51,77,0.4); }
body.light .row .guide { background:rgba(213,222,235,0.65); }
.slot { flex:none; width:16px; height:16px; display:flex; align-items:center; justify-content:center; color:var(--muted); }
.chev { display:flex; cursor:pointer; transition:transform 0.12s ease-out; }
.chev.open { transform:rotate(90deg); }
.ficon { flex:none; width:15px; display:flex; align-items:center; justify-content:center; color:var(--muted); margin-right:5px; }
.langdot { flex:none; width:6px; height:6px; border-radius:50%; margin:0 5px 0 4px; }
.kbadge { flex:none; width:12px; height:12px; border:1px solid var(--muted3); border-radius:1px;
  margin:0 5px 0 4px; font:10px/10px ui-monospace,'SFMono-Regular',Menlo,Consolas,monospace;
  color:var(--text); display:flex; align-items:center; justify-content:center; }
.rname { flex:1; min-width:0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; font-size:12.5px; }
.row.dir .rname { color:var(--text2); }
.row.sym .rname { font-family:ui-monospace,'SFMono-Regular',Menlo,Consolas,monospace; font-size:12px; }
.meta { flex:none; margin-left:auto; padding-left:8px; color:var(--muted); font-size:11px;
  font-variant-numeric:tabular-nums; }
.hit { color:var(--hue-focus); }
.pill { flex:none; margin-left:12px; height:16px; border-radius:8px; border:1px solid; padding:0 5px;
  background:transparent; cursor:pointer; font:10.5px/14px ui-monospace,'SFMono-Regular',Menlo,Consolas,monospace;
  font-variant-numeric:tabular-nums; }
.chip { flex:none; height:16px; border-radius:4px; border:1px solid; padding:0 5px;
  font:10.5px/14px ui-monospace,'SFMono-Regular',Menlo,Consolas,monospace; font-variant-numeric:tabular-nums; }
.row.enter { animation:rowin 0.1s ease-out; }
@keyframes rowin { from { opacity:0; } to { opacity:1; } }
/* ── 详情栏：单行详情头 + tab 栏 + 唯一滚动区 ── */
.detail-head { flex:none; display:flex; align-items:center; gap:8px; height:40px; padding:0 24px; }
.backbtn { display:none; flex:none; width:24px; height:24px; border:none; background:none;
  color:var(--muted); cursor:pointer; align-items:center; justify-content:center; }
.crumb { flex:1; min-width:0; overflow:hidden; white-space:nowrap; text-overflow:ellipsis;
  color:var(--muted); font:11px ui-monospace,'SFMono-Regular',Menlo,Consolas,monospace; }
.ktag { flex:none; font:11px ui-monospace,'SFMono-Regular',Menlo,Consolas,monospace;
  color:var(--muted3); text-transform:uppercase; letter-spacing:0.06em; }
.dname { flex:none; max-width:45%; overflow:hidden; text-overflow:ellipsis; white-space:nowrap;
  font:600 13px ui-monospace,'SFMono-Regular',Menlo,Consolas,monospace; }
.tabbar { flex:none; display:flex; gap:20px; padding:8px 24px 0; border-bottom:1px solid var(--border);
  position:relative; }
.tabbar button { border:none; background:none; cursor:pointer; color:var(--muted);
  font:12.5px -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,'PingFang SC','Microsoft YaHei',sans-serif;
  padding:0 0 8px; }
.tabbar button.on { color:var(--text); }
#tab-ind { position:absolute; bottom:-1px; height:2px; background:var(--hue-focus);
  transition:left 0.16s ease, width 0.16s ease; }
.detail-scroll { flex:1; overflow:auto; }
.tabbody { padding:12px 24px 32px; }
#empty { height:100%; display:flex; align-items:center; justify-content:center;
  color:var(--muted); font-size:12.5px; }
/* ── 源码 tab：唯一允许的一层 1px 边框（代码块）── */
.codeblock { border:1px solid var(--border); background:var(--code-bg); border-radius:8px;
  padding:12px 16px; font-family:ui-monospace,'SFMono-Regular',Menlo,Consolas,monospace;
  font-size:12.5px; line-height:1.65; }
.cline { display:flex; position:relative; }
.cline .ln { flex:none; width:var(--lnw, 3ch); text-align:right; color:var(--muted);
  font-variant-numeric:tabular-nums; margin-right:16px; user-select:none; }
.cline .lc { white-space:pre; flex:1; min-width:0; }
.cline.hasf { cursor:pointer; }
.cline.hasf .ln { color:var(--tc); }
.cline.hasf::before { content:''; position:absolute; left:-16px; top:0; bottom:0; width:2px;
  background:var(--tc); }
.truncnote { margin-top:8px; color:var(--muted); font-size:11px;
  font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,'PingFang SC','Microsoft YaHei',sans-serif; }
/* ── 置信度 tab：单列分区列表（档位色点 + kind + 行号 + 证据等宽块）── */
.degrade { color:var(--muted); font-size:11px; margin-bottom:8px; }
.sechead { color:var(--muted); font-size:11px; text-transform:uppercase; letter-spacing:0.08em;
  margin:16px 0 4px; font-variant-numeric:tabular-nums; }
.tabbody .sechead:first-child { margin-top:4px; }
.finding { padding:6px 0 10px; }
.fmeta { display:flex; align-items:center; gap:8px; }
.fdot { flex:none; width:6px; height:6px; border-radius:50%; }
.fkind { font:11px ui-monospace,'SFMono-Regular',Menlo,Consolas,monospace; color:var(--text2); }
.fline { font:11px ui-monospace,'SFMono-Regular',Menlo,Consolas,monospace; color:var(--muted);
  font-variant-numeric:tabular-nums; }
.fev { margin:4px 0 0 14px; font:12px/1.6 ui-monospace,'SFMono-Regular',Menlo,Consolas,monospace;
  white-space:pre-wrap; word-break:break-all; }
.capnote { margin-top:12px; color:var(--muted); font-size:11px; }
.noneword { color:var(--muted); font-size:11px; padding:4px 0; }
/* ── 关系 tab：单列两段列表 ── */
.relrow { display:flex; align-items:baseline; gap:8px; padding:5px 4px; cursor:pointer; border-radius:4px; }
.relrow:hover { background:rgba(148,163,184,0.06); }
.rname2 { flex:none; max-width:45%; overflow:hidden; text-overflow:ellipsis; white-space:nowrap;
  font:12px ui-monospace,'SFMono-Regular',Menlo,Consolas,monospace; }
.rpath { flex:1; min-width:0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap;
  color:var(--muted); font:11px ui-monospace,'SFMono-Regular',Menlo,Consolas,monospace; }
.rw { flex:none; color:var(--muted); font-size:11px; font-variant-numeric:tabular-nums; }
/* 语法高亮四类 token：关键字/字符串/注释/数字（深浅主题各一组） */
body.dark .k { color:#c084fc; } body.dark .s { color:#86efac; } body.dark .c { color:#64748b; } body.dark .n { color:#fbbf24; }
body.light .k { color:#7c3aed; } body.light .s { color:#16a34a; } body.light .c { color:#94a3b8; } body.light .n { color:#b45309; }
/* ── 窄屏 <880px：单块覆盖式详情面板（同屏可见 pane 数 = 1）── */
@media (max-width:879.9px) {
  #divider { display:none; }
  [data-pane="tree"] { width:100% !important; max-width:none !important; }
  body.detail-open [data-pane="tree"] { visibility:hidden; }
  [data-pane="detail"] { position:absolute; top:0; left:0; right:0; bottom:0;
    transform:translateX(100%); transition:transform 0.2s ease; z-index:5; }
  body.detail-open [data-pane="detail"] { transform:translateX(0); }
  .backbtn { display:flex; }
}
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after { transition:none !important; animation:none !important; }
}
</style>
</head>
<body>
<main class="shell">
  <aside data-pane="tree" aria-label="${treeLabel}">
    <div class="tree-head">
      <div id="root-row" role="treeitem" aria-level="1" aria-expanded="true"></div>
      <div class="searchrow"><input id="q" type="text" placeholder="${searchPh}" aria-label="${searchPh}"></div>
    </div>
    <div id="tree-scroll" class="tree-scroll" tabindex="0" role="tree" aria-label="${treeLabel}">
      <div id="tree-canvas" class="tree-canvas"></div>
    </div>
  </aside>
  <div id="divider" title="${dividerTitle}"></div>
  <section data-pane="detail" aria-label="${detailLabel}">
    <div id="d-head" class="detail-head" hidden>
      <button id="d-back" class="backbtn" type="button" aria-label="${backLabel}"><svg viewBox="0 0 12 12" width="12" height="12"><path d="M8 2.2 L3.8 6 L8 9.8" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg></button>
      <span id="d-crumb" class="crumb"></span>
      <span id="d-ktag" class="ktag"></span>
      <span id="d-name" class="dname"></span>
    </div>
    <div id="d-tabs" class="tabbar" role="tablist" hidden></div>
    <div id="d-scroll" class="detail-scroll">
      <div id="empty">${emptyHint}</div>
      <div id="tab-source" class="tabbody" role="tabpanel" style="display:none"></div>
      <div id="tab-conf" class="tabbody" role="tabpanel" style="display:none"></div>
      <div id="tab-rel" class="tabbody" role="tabpanel" style="display:none"></div>
    </div>
  </section>
</main>
<script>
window.__CODEGRAPH__ = """)
    sb.append(json)
    sb.append(";\n</script>\n<script>\n")
    sb.append(codegraphDriverJs(en))
    sb.append("\n</script>\n</body>\n</html>\n")
    return sb.toString()
}

/// 驱动：左树右详情。树四级（项目/目录/文件/符号）+ 行内 ⚠N 徽标 + 虚拟
/// 滚动；详情三 tab（源码/置信度/关系）切换即替换；关系行点击 = 左树
/// re-center。零随机、零外部请求。
func codegraphDriverJs(en: Bool): String {
    let tSrc = if (en) { "Source" } else { "源码" }
    let tConf = if (en) { "Confidence" } else { "置信度" }
    let tRel = if (en) { "Relations" } else { "关系" }
    let callers = if (en) { "CALLERS" } else { "调用方" }
    let callees = if (en) { "CALLEES" } else { "被调" }
    let noneIn = if (en) { "no callers" } else { "无调用方" }
    let noneOut = if (en) { "no callees" } else { "无被调" }
    let truncNote = if (en) { "truncated to 40 lines per engine contract" } else { "已按引擎契约截断至 40 行" }
    let capNote = if (en) { "engine caps: 6 per kind per file / 400 total — excess summarized" }
        else { "同类每文件最多 6 条 / 全量最多 400 条，超出已汇总" }
    let srcNa = if (en) { "source unavailable" } else { "源码不可用" }
    let clean = if (en) { "no findings — clean" } else { "无疑点——干净" }
    let findAria = if (en) { " findings, max weight " } else { " 项疑点，最高权重 " }
    let scoreTitle = if (en) { "global confidence score" } else { "全局置信度分数" }
    let filesTitle = if (en) { " files" } else { " 个文件" }
    let kProject = if (en) { "project" } else { "项目" }
    let kDir = if (en) { "dir" } else { "目录" }
    let kFile = if (en) { "file" } else { "文件" }
    let dimVar = if (en) { "Variables" } else { "变量" }
    let dimFn = if (en) { "Functions" } else { "函数" }
    let dimType = if (en) { "Types" } else { "类型" }
    let dimPtr = if (en) { "Pointers" } else { "指针" }
    let dimConc = if (en) { "Concurrency" } else { "并发" }
    let dimStruct = if (en) { "Structure" } else { "结构" }
    let constJs = "var T = { src: " + jsStr(tSrc) + ", conf: " + jsStr(tConf) + ", rel: " + jsStr(tRel)
        + ", callers: " + jsStr(callers) + ", callees: " + jsStr(callees)
        + ", noneIn: " + jsStr(noneIn) + ", noneOut: " + jsStr(noneOut)
        + ", truncNote: " + jsStr(truncNote) + ", capNote: " + jsStr(capNote)
        + ", srcNa: " + jsStr(srcNa) + ", clean: " + jsStr(clean)
        + ", findAria: " + jsStr(findAria) + ", scoreTitle: " + jsStr(scoreTitle)
        + ", filesTitle: " + jsStr(filesTitle)
        + ", kProject: " + jsStr(kProject) + ", kDir: " + jsStr(kDir) + ", kFile: " + jsStr(kFile)
        + ", dims: { variable: " + jsStr(dimVar) + ", function: " + jsStr(dimFn)
        + ", type: " + jsStr(dimType) + ", pointer: " + jsStr(dimPtr)
        + ", concurrency: " + jsStr(dimConc) + ", structure: " + jsStr(dimStruct) + " } };\n"
    return constJs + """
'use strict';
var D = window.__CODEGRAPH__;
var NL = String.fromCharCode(10);
var CONF = D.confidence || { score: 100, astUsed: true, astNote: '', cappedTotal: false, cappedKind: false, findings: [] };
var FG = D.functionGraph || { functions: [], functionEdges: [], codeSnippets: {} };
var LT = D.langThemes || { dark: {}, light: {} };

// ── 工具 ──
function esc(s) { return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;'); }
function isLight() { return document.body.classList.contains('light'); }
function tierHex(w) {
  var L = isLight();
  if (w >= 8) { return L ? '#dc2626' : '#f87171'; }
  if (w >= 4) { return L ? '#d97706' : '#fbbf24'; }
  return L ? '#64748b' : '#8b9bb4';
}
function scoreHex(s) {
  var L = isLight();
  if (s >= 80) { return L ? '#0d9488' : '#2dd4bf'; }
  if (s >= 60) { return L ? '#d97706' : '#fbbf24'; }
  return L ? '#dc2626' : '#f87171';
}
function hexRgba(hex, a) {
  var r = parseInt(hex.slice(1, 3), 16);
  var g = parseInt(hex.slice(3, 5), 16);
  var b = parseInt(hex.slice(5, 7), 16);
  return 'rgba(' + r + ',' + g + ',' + b + ',' + a + ')';
}
function langColor(l) {
  var m = isLight() ? LT.light : LT.dark;
  return m[l] || m.module || '#64748b';
}
function midTrunc(s, max) {
  if (!s || s.length <= max) { return s; }
  var segs = s.split('/');
  if (segs.length < 4) { return s; }
  var out = segs.slice(0, 2).join('/') + '/…/' + segs.slice(-2).join('/');
  if (out.length > max + 8) { out = segs[0] + '/…/' + segs.slice(-2).join('/'); }
  return out;
}

// ── 语法高亮（多语言关键字表 + 注释风格；与引擎 tokenizer 四类 token 对齐）──
var LANG = {
  cangjie: { lineCm: '//', kws: new Set(('package import class struct enum interface extend func let var const '
    + 'match case if else while for return try catch throw true false this super init override '
    + 'public private internal protected static abstract open where in as is spawn prop '
    + 'volatile unsafe mut ref final sealed typealias operator infix').split(' ')) },
  swift: { lineCm: '//', kws: new Set(('import class struct enum protocol func let var if else guard while '
    + 'for return try catch throw true false self super init override public private internal fileprivate '
    + 'open static final where in as is extension weak unowned lazy mutating didSet willSet some any '
    + 'async await throws rethrows case switch default break continue fallthrough').split(' ')) },
  ts: { lineCm: '//', kws: new Set(('import export from class extends implements interface type enum function '
    + 'const let var if else while for of in return try catch throw true false null undefined this super new '
    + 'delete typeof instanceof void async await yield static get set public private protected readonly '
    + 'abstract as is break continue case switch default do').split(' ')) },
  python: { lineCm: '#', kws: new Set(('import from class def lambda if elif else while for in return try '
    + 'except finally raise True False None self super global nonlocal yield async await with as pass '
    + 'break continue and or not is del').split(' ')) },
  go: { lineCm: '//', kws: new Set(('package import func var const type struct interface map chan go defer '
    + 'if else for range return switch case default true false nil break continue goto fallthrough select').split(' ')) },
  rust: { lineCm: '//', kws: new Set(('fn let mut const struct enum trait impl for in if else while loop match '
    + 'return true false self Self super crate mod pub use extern as where async await move ref dyn box type '
    + 'unsafe break continue').split(' ')) },
  java: { lineCm: '//', kws: new Set(('package import class interface enum record extends implements public private '
    + 'protected static final abstract void int long double float boolean char byte short if else while for '
    + 'return try catch finally throw throws true false null this super new instanceof synchronized volatile '
    + 'transient default sealed permits var break continue do switch case').split(' ')) },
  kotlin: { lineCm: '//', kws: new Set(('package import class object interface fun val var if else when while for '
    + 'return try catch finally throw true false null this super init override open abstract final sealed data '
    + 'companion internal private protected public lateinit lazy by is as in out reified crossinline noinline '
    + 'suspend inline operator infix external const break continue do').split(' ')) },
  c: { lineCm: '//', kws: new Set(('auto break case char const continue default do double else enum extern float '
    + 'for goto if inline int long register restrict return short signed sizeof static struct switch typedef union '
    + 'unsigned void volatile while class public private protected virtual override final template typename '
    + 'namespace using new delete nullptr constexpr noexcept').split(' ')) },
};
function langOf(path) {
  if (path.endsWith('.ts') || path.endsWith('.tsx') || path.endsWith('.js') || path.endsWith('.jsx') || path.endsWith('.mjs')) { return 'ts'; }
  if (path.endsWith('.swift')) { return 'swift'; }
  if (path.endsWith('.cj')) { return 'cangjie'; }
  if (path.endsWith('.py')) { return 'python'; }
  if (path.endsWith('.go')) { return 'go'; }
  if (path.endsWith('.rs')) { return 'rust'; }
  if (path.endsWith('.java')) { return 'java'; }
  if (path.endsWith('.kt') || path.endsWith('.kts')) { return 'kotlin'; }
  if (path.endsWith('.c') || path.endsWith('.h') || path.endsWith('.cpp') || path.endsWith('.hpp')) { return 'c'; }
  return 'cangjie';
}
function hl2(code, lang) {
  var cfg = LANG[lang] || LANG.cangjie;
  var kws = cfg.kws; var lineCm = cfg.lineCm;
  var out = ''; var i = 0; var n = code.length;
  while (i < n) {
    var ch = code[i];
    if (lineCm !== '#' && ch === '/' && code[i + 1] === '/') {
      var j = code.indexOf(NL, i); if (j < 0) { j = n; }
      out += '<span class="c">' + esc(code.slice(i, j)) + '</span>'; i = j; continue;
    }
    if (lineCm === '#' && ch === '#') {
      var j2 = code.indexOf(NL, i); if (j2 < 0) { j2 = n; }
      out += '<span class="c">' + esc(code.slice(i, j2)) + '</span>'; i = j2; continue;
    }
    if (ch === '"' || ch === "'") {
      var k = i + 1;
      while (k < n && code[k] !== ch) { if (code[k] === String.fromCharCode(92)) { k += 1; } k += 1; }
      out += '<span class="s">' + esc(code.slice(i, Math.min(k + 1, n))) + '</span>'; i = k + 1; continue;
    }
    if (ch >= '0' && ch <= '9') {
      var m = i;
      while (m < n && /[0-9a-fA-FxX_.]/.test(code[m])) { m += 1; }
      out += '<span class="n">' + esc(code.slice(i, m)) + '</span>'; i = m; continue;
    }
    if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch === '_') {
      var p = i;
      while (p < n && (/[A-Za-z0-9_]/.test(code[p]))) { p += 1; }
      var w = code.slice(i, p);
      out += kws.has(w) ? '<span class="k">' + esc(w) + '</span>' : esc(w);
      i = p; continue;
    }
    out += esc(ch); i += 1;
  }
  return out;
}

// ── 函数索引与调用边 ──
var FN = {}; var IN_EDGE = {}; var OUT_EDGE = {};
FG.functions.forEach(function (f) { FN[f.id] = f; });
FG.functionEdges.forEach(function (e) {
  (OUT_EDGE[e.from] = OUT_EDGE[e.from] || []).push([e.to, e.w]);
  (IN_EDGE[e.to] = IN_EDGE[e.to] || []).push([e.from, e.w]);
});
var BY_FILE = {};
(CONF.findings || []).forEach(function (f) { (BY_FILE[f.file] = BY_FILE[f.file] || []).push(f); });

// ── 树构建（L0 项目 / L1 目录 / L2 文件 / L3 符号）──
var KIND_CH = { 'func': 'ƒ', 'class': 'C', 'struct': 'S', 'interface': 'I', 'enum': 'E', 'extension': 'X', 'typealias': 'T' };
var SYM_NODE = {}; var NODE_BY = {}; var PARENT = {};
var ROOT = { type: 'root', id: 'root', name: D.project || 'project', children: [],
  fileN: 0, fileFindings: [], rollN: 0, rollW: 0 };
NODE_BY.root = ROOT;
var DIRS = {};
function dirNode(path) {
  if (!path) { return ROOT; }
  if (DIRS[path]) { return DIRS[path]; }
  var segs = path.split('/');
  var n = { type: 'dir', id: 'd:' + path, name: segs[segs.length - 1], path: path,
    children: [], fileN: 0, fileFindings: [], rollN: 0, rollW: 0 };
  DIRS[path] = n; NODE_BY[n.id] = n;
  var parent = dirNode(segs.slice(0, -1).join('/'));
  PARENT[n.id] = parent; parent.children.push(n);
  return n;
}
D.files.forEach(function (fe) {
  var segs = fe.path.split('/');
  var parent = dirNode(segs.slice(0, -1).join('/'));
  var fn = { type: 'file', id: 'p:' + fe.path, name: segs[segs.length - 1], path: fe.path,
    lang: fe.lang, lines: fe.lines, children: [], fileN: 0, fileFindings: [], rollN: 0, rollW: 0, ownW: 0 };
  NODE_BY[fn.id] = fn;
  (fe.symbols || []).forEach(function (s) {
    var sn = { type: 'sym', id: 'f:' + fe.path + ':' + s.line + ':' + s.name, name: s.name,
      kind: s.kind, line: s.line, file: fe.path, lang: fe.lang, findings: [] };
    fn.children.push(sn); SYM_NODE[sn.id] = sn; NODE_BY[sn.id] = sn; PARENT[sn.id] = fn;
  });
  // 归属规则：finding 按行号落进符号体区间则挂符号行，否则挂文件行
  var target = null;
  (BY_FILE[fe.path] || []).forEach(function (f) {
    target = null;
    fn.children.forEach(function (sn) { if (sn.line <= f.line) { target = sn; } });
    if (target) { target.findings.push(f); } else { fn.fileFindings.push(f); }
  });
  PARENT[fn.id] = parent; parent.children.push(fn);
});
(function sortChildren(n) {
  if (!n.children || !n.children.length) { return; }
  n.children.sort(function (a, b) {
    var ta = a.type === 'dir' ? 0 : 1;
    var tb = b.type === 'dir' ? 0 : 1;
    if (ta !== tb) { return ta - tb; }
    return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0);
  });
  n.children.forEach(sortChildren);
})(ROOT);
(function roll(n) {
  var cnt = 0; var w = 0;
  if (n.type === 'sym') {
    n.findings.forEach(function (f) { cnt += 1; if (f.weight > w) { w = f.weight; } });
  } else {
    n.fileFindings.forEach(function (f) { cnt += 1; if (f.weight > w) { w = f.weight; } });
    if (n.type === 'file') { n.ownW = w; }
    n.children.forEach(function (c) {
      roll(c); cnt += c.rollN; if (c.rollW > w) { w = c.rollW; }
      n.fileN += (c.type === 'file') ? 1 : c.fileN;
    });
  }
  n.rollN = cnt; n.rollW = w;
})(ROOT);

// ── 状态 ──
var state = { selId: '', q: '', tab: 'source', node: null };
var expandSet = { root: true };
ROOT.children.forEach(function (c) { if (c.type === 'dir') { expandSet[c.id] = true; } });

// ── 扁平化 + 虚拟滚动 ──
var ROWS = []; var H = { root: 36, dir: 28, file: 28, sym: 24 };
function indentOf(d) { return 8 + 16 * d; }
function isOpen(n) { return state.q ? !!n.sOpen : !!expandSet[n.id]; }
function flatten() {
  ROWS = [];
  var mq = (state.q || '').trim().toLowerCase();
  if (mq) { searchVis(ROOT, mq, false); }
  // L0 项目行固定在树栏头部（锚点行），滚动区只承载 L1 及以下
  if (!isOpen(ROOT)) { return; }
  ROOT.children.forEach(function (c) {
    if (!mq || c.vis) {
      (function walk2(n, depth) {
        ROWS.push({ n: n, d: depth });
        if (isOpen(n) && n.children) {
          n.children.forEach(function (cc) { if (!mq || cc.vis) { walk2(cc, depth + 1); } });
        }
      })(c, 1);
    }
  });
}
function markAll(n) {
  n.vis = true;
  n.sOpen = !!(n.children && n.children.length);
  (n.children || []).forEach(markAll);
}
function searchVis(n, mq, parentHit) {
  var self = n.name.toLowerCase().indexOf(mq) >= 0;
  var hit = self || parentHit;
  if (n.type === 'sym') { n.vis = hit; n.sOpen = false; return hit; }
  if (n.type === 'file') { n.vis = hit; n.sOpen = hit && n.children.length > 0; return hit; }
  if (self) { n.vis = true; n.sOpen = true; n.children.forEach(markAll); return true; }
  var any = false;
  n.children.forEach(function (c) { if (searchVis(c, mq, false)) { any = true; } });
  n.vis = (n.type === 'root') ? true : any;
  n.sOpen = any;
  return any;
}

var canvas = document.getElementById('tree-canvas');
var scroller = document.getElementById('tree-scroll');
var rendered = {};
var pendingEnter = false;
function layout() {
  var y = 0;
  for (var i = 0; i < ROWS.length; i++) { ROWS[i].y = y; y += H[ROWS[i].n.type]; }
  canvas.style.height = y + 'px';
}
function syncRow(el, r) {
  el.style.top = r.y + 'px';
  if (state.selId === r.n.id) { el.classList.add('sel'); } else { el.classList.remove('sel'); }
  var chev = el.querySelector('.chev');
  if (chev) {
    var open = isOpen(r.n);
    if (open) { chev.classList.add('open'); el.setAttribute('aria-expanded', 'true'); }
    else { chev.classList.remove('open'); el.setAttribute('aria-expanded', 'false'); }
  }
}
function paint() {
  var st = scroller.scrollTop; var vh = scroller.clientHeight;
  var lo = st - 480; var hi = st + vh + 480; var keep = {}; var frag = null;
  for (var i = 0; i < ROWS.length; i++) {
    var r = ROWS[i];
    if (r.y + H[r.n.type] < lo) { continue; }
    if (r.y > hi) { break; }
    keep[r.n.id] = 1;
    if (rendered[r.n.id]) { syncRow(rendered[r.n.id], r); continue; }
    var el = buildRow(r);
    rendered[r.n.id] = el;
    if (!frag) { frag = document.createDocumentFragment(); }
    frag.appendChild(el);
  }
  if (frag) { canvas.appendChild(frag); }
  var dead = [];
  for (var id in rendered) { if (!keep[id]) { dead.push(id); } }
  dead.forEach(function (k) { rendered[k].remove(); delete rendered[k]; });
}
var rafPending = false;
scroller.addEventListener('scroll', function () {
  if (rafPending) { return; }
  rafPending = true;
  requestAnimationFrame(function () { rafPending = false; paint(); });
});
window.addEventListener('resize', function () { paint(); });

// ── 行构建 ──
function svgChev() {
  return '<svg viewBox="0 0 12 12" width="12" height="12"><path d="M4 2.2 L8.2 6 L4 9.8" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg>';
}
function svgFolder() {
  return '<svg viewBox="0 0 14 14" width="13" height="13"><path d="M1.2 3.4 h4.2 l1.6 1.9 h5.8 v6.5 h-11.6 z" fill="none" stroke="currentColor" stroke-width="1.1" stroke-linejoin="round"/></svg>';
}
function pillTitleOf(list) {
  var agg = {};
  list.forEach(function (f) { agg[f.kind] = (agg[f.kind] || 0) + 1; });
  var parts = [];
  for (var k in agg) { parts.push(k + ' ×' + agg[k]); }
  return parts.join('、');
}
function collectRoll(n, out) {
  (n.fileFindings || []).forEach(function (f) { out.push(f); });
  (n.children || []).forEach(function (c) { collectRoll(c, out); });
}
function pillHtml(count, w, title) {
  var c = tierHex(w);
  return '<button type="button" class="pill" style="color:' + c + ';border-color:' + c + ';background:'
    + hexRgba(c, 0.14) + '" title="' + esc(title) + '" aria-label="' + count + T.findAria + w + '">'
    + '⚠ ' + count + '</button>';
}
function nodeBadge(n) {
  if (n.type === 'sym' && n.findings.length > 0) { return pillHtml(n.findings.length, n.findings[0] ? maxW(n.findings) : 0, pillTitleOf(n.findings)); }
  if (n.type === 'file' && n.fileFindings.length > 0) { return pillHtml(n.fileFindings.length, n.ownW, pillTitleOf(n.fileFindings)); }
  if ((n.type === 'dir' || n.type === 'root') && n.rollN > 0) {
    var list = []; collectRoll(n, list);
    return pillHtml(n.rollN, n.rollW, pillTitleOf(list));
  }
  return '';
}
function maxW(list) { var w = 0; list.forEach(function (f) { if (f.weight > w) { w = f.weight; } }); return w; }
function nameHtml(name) {
  var s = esc(name);
  var mq = (state.q || '').trim().toLowerCase();
  if (!mq) { return s; }
  var at = name.toLowerCase().indexOf(mq);
  if (at < 0) { return s; }
  return esc(name.slice(0, at)) + '<span class="hit">' + esc(name.slice(at, at + mq.length)) + '</span>'
    + esc(name.slice(at + mq.length));
}
function buildRow(r) {
  var n = r.n; var d = r.d;
  var el = document.createElement('div');
  el.className = 'row ' + n.type + (pendingEnter ? ' enter' : '');
  el.style.height = H[n.type] + 'px';
  el.style.paddingLeft = indentOf(d) + 'px';
  el.dataset.id = n.id;
  el.setAttribute('role', 'treeitem');
  el.setAttribute('aria-level', String(d + 1));
  var h = '';
  for (var a = 0; a < d; a++) { h += '<span class="guide" style="left:' + (indentOf(a) + 8) + 'px"></span>'; }
  var hasKids = n.children && n.children.length > 0;
  h += '<span class="slot">' + (hasKids ? '<span class="chev' + (isOpen(n) ? ' open' : '') + '">' + svgChev() + '</span>' : '') + '</span>';
  if (n.type === 'dir') { h += '<span class="ficon">' + svgFolder() + '</span>'; }
  else if (n.type === 'file') { h += '<span class="langdot" style="background:' + langColor(n.lang) + '"></span>'; }
  else if (n.type === 'sym') { h += '<span class="kbadge">' + esc(KIND_CH[n.kind] || 'T') + '</span>'; }
  h += '<span class="rname">' + nameHtml(n.name) + '</span>';
  if (n.type === 'file') {
    h += '<span class="meta"' + (n.lines ? ' title="' + n.lines + T.filesTitle + '"' : '') + '>' + (n.lines || '') + '</span>';
  } else if (n.type === 'sym') {
    h += '<span class="meta">' + n.line + '</span>';
  } else if (n.type === 'dir') {
    h += '<span class="meta" title="' + n.fileN + T.filesTitle + '">' + n.fileN + '</span>';
  }
  h += nodeBadge(n);
  el.innerHTML = h;
  syncRow(el, r);
  return el;
}

// ── L0 项目锚点行（固定在树栏头部，不随树滚动）──
var rootRow = document.getElementById('root-row');
function paintRootRow() {
  var c = scoreHex(CONF.score);
  var h = '<span class="slot"><span class="chev' + (expandSet.root ? ' open' : '') + '">' + svgChev() + '</span></span>'
    + '<span class="rname">' + esc(ROOT.name) + '</span>'
    + '<span class="chip" style="color:' + c + ';border-color:' + c + ';background:' + hexRgba(c, 0.12)
    + '" title="' + T.scoreTitle + ' ' + CONF.score + '">' + CONF.score + '</span>';
  h += nodeBadge(ROOT);
  rootRow.innerHTML = h;
  rootRow.setAttribute('aria-expanded', expandSet.root ? 'true' : 'false');
}
rootRow.addEventListener('click', function (e) {
  if (e.target.closest('.pill')) { openDetail(ROOT, 'conf'); return; }
  expandSet.root = !expandSet.root;
  paintRootRow();
  refreshTree(true);
});

// ── 选择 / 展开 / 刷新 ──
function setSel(id) {
  if (state.selId && rendered[state.selId]) { rendered[state.selId].classList.remove('sel'); }
  state.selId = id;
  if (id && rendered[id]) { rendered[id].classList.add('sel'); }
}
function rowIndexOf(id) {
  for (var i = 0; i < ROWS.length; i++) { if (ROWS[i].n.id === id) { return i; } }
  return -1;
}
function scrollToIndex(i) {
  var r = ROWS[i];
  if (!r) { return; }
  var top = r.y; var bot = r.y + H[r.n.type];
  if (top < scroller.scrollTop + 4) { scroller.scrollTop = Math.max(0, top - 4); }
  else if (bot > scroller.scrollTop + scroller.clientHeight - 4) { scroller.scrollTop = bot - scroller.clientHeight + 4; }
}
function refreshTree(enter) {
  pendingEnter = !!enter;
  flatten(); layout(); paint();
  pendingEnter = false;
}
function toggle(n) {
  if (!n.children || !n.children.length) { return; }
  expandSet[n.id] = !expandSet[n.id];
  refreshTree(true);
}
canvas.addEventListener('click', function (e) {
  var pillBtn = e.target.closest ? e.target.closest('.pill') : null;
  var rowEl = e.target.closest ? e.target.closest('.row') : null;
  scroller.focus();
  if (pillBtn && rowEl) {
    var n0 = NODE_BY[rowEl.dataset.id];
    if (n0) { setSel(n0.id); openDetail(n0, 'conf'); }
    e.stopPropagation();
    return;
  }
  if (rowEl) {
    var n = NODE_BY[rowEl.dataset.id];
    if (!n) { return; }
    setSel(n.id);
    if (n.type === 'sym') { openDetail(n, 'source'); } else { toggle(n); }
  }
});

// ── 键盘（Xcode 级树内导航）──
scroller.addEventListener('keydown', function (e) {
  var i = rowIndexOf(state.selId);
  if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
    e.preventDefault();
    if (i < 0) { i = 0; } else { i += (e.key === 'ArrowDown') ? 1 : -1; }
    if (i < 0) { i = 0; }
    if (i >= ROWS.length) { i = ROWS.length - 1; }
    if (ROWS[i]) { setSel(ROWS[i].n.id); scrollToIndex(i); }
  } else if (e.key === 'ArrowRight') {
    e.preventDefault();
    var n = (i >= 0) ? ROWS[i].n : null;
    if (n && n.children && n.children.length) {
      if (!isOpen(n)) { toggle(n); }
      else if (i + 1 < ROWS.length) { setSel(ROWS[i + 1].n.id); scrollToIndex(i + 1); }
    }
  } else if (e.key === 'ArrowLeft') {
    e.preventDefault();
    var n2 = (i >= 0) ? ROWS[i].n : null;
    if (n2 && n2.children && n2.children.length && isOpen(n2)) { toggle(n2); }
    else if (n2 && PARENT[n2.id]) {
      setSel(PARENT[n2.id].id);
      var pi = rowIndexOf(PARENT[n2.id].id);
      if (pi >= 0) { scrollToIndex(pi); }
    }
  } else if (e.key === 'Enter') {
    e.preventDefault();
    var n3 = (i >= 0) ? ROWS[i].n : null;
    if (!n3) { return; }
    if (n3.type === 'sym') { openDetail(n3, 'source'); } else { toggle(n3); }
  }
});

// ── 搜索 ──
var qEl = document.getElementById('q');
function clearRendered() {
  for (var id in rendered) { rendered[id].remove(); }
  rendered = {};
}
qEl.addEventListener('input', function () {
  state.q = qEl.value;
  // 行内容随查询变化（命中高亮），已渲染行全部重建
  clearRendered();
  flatten(); layout();
  scroller.scrollTop = 0;
  paint();
});

// ── 详情栏 ──
var BODY = {
  source: document.getElementById('tab-source'),
  conf: document.getElementById('tab-conf'),
  rel: document.getElementById('tab-rel'),
};
var TAB_BTNS = [];
function confCount(n) {
  if (n.type === 'sym') { return n.findings.length; }
  if (n.type === 'file') { return n.fileFindings.length; }
  return n.rollN;
}
function tabDefsFor(n) {
  if (n.type === 'sym') {
    var defs = [{ key: 'source', label: T.src }];
    var c = n.findings.length;
    if (c > 0) { defs.push({ key: 'conf', label: T.conf + ' (' + c + ')' }); }
    defs.push({ key: 'rel', label: T.rel });
    return defs;
  }
  return [{ key: 'conf', label: T.conf + ' (' + confCount(n) + ')' }];
}
function ktagOf(n) {
  if (n.type === 'sym') { return n.kind; }
  if (n.type === 'file') { return T.kFile; }
  if (n.type === 'dir') { return T.kDir; }
  return T.kProject;
}
function buildTabbar(defs) {
  var tabs = document.getElementById('d-tabs');
  var h = '';
  defs.forEach(function (d) {
    h += '<button type="button" role="tab" data-k="' + d.key + '" aria-selected="false">' + esc(d.label) + '</button>';
  });
  h += '<span id="tab-ind"></span>';
  tabs.innerHTML = h;
  TAB_BTNS = [];
  defs.forEach(function (d) {
    var b = tabs.querySelector('button[data-k="' + d.key + '"]');
    TAB_BTNS.push(b);
    b.addEventListener('click', function () { setTab(d.key); });
  });
}
function setTab(key, instant) {
  var has = false;
  TAB_BTNS.forEach(function (b) { if (b.dataset.k === key) { has = true; } });
  if (!has) { return; }
  state.tab = key;
  TAB_BTNS.forEach(function (b) {
    var on = b.dataset.k === key;
    if (on) { b.classList.add('on'); b.setAttribute('aria-selected', 'true'); }
    else { b.classList.remove('on'); b.setAttribute('aria-selected', 'false'); }
  });
  BODY.source.style.display = (key === 'source') ? '' : 'none';
  BODY.conf.style.display = (key === 'conf') ? '' : 'none';
  BODY.rel.style.display = (key === 'rel') ? '' : 'none';
  var ind = document.getElementById('tab-ind');
  var btn = null;
  TAB_BTNS.forEach(function (b) { if (b.dataset.k === key) { btn = b; } });
  if (!ind || !btn) { return; }
  if (instant) { ind.style.transition = 'none'; }
  ind.style.left = btn.offsetLeft + 'px';
  ind.style.width = btn.offsetWidth + 'px';
  ind.style.opacity = '1';
  if (instant) { requestAnimationFrame(function () { ind.style.transition = ''; }); }
}
document.getElementById('d-tabs').addEventListener('keydown', function (e) {
  if (e.key !== 'ArrowRight' && e.key !== 'ArrowLeft') { return; }
  var idx = -1;
  TAB_BTNS.forEach(function (b, i) { if (b.dataset.k === state.tab) { idx = i; } });
  var ni = idx + ((e.key === 'ArrowRight') ? 1 : -1);
  if (ni < 0 || ni >= TAB_BTNS.length) { return; }
  e.preventDefault();
  TAB_BTNS[ni].focus();
  setTab(TAB_BTNS[ni].dataset.k);
});
function openDetail(node, tab) {
  state.node = node;
  state.tab = tab || 'source';
  document.body.classList.add('detail-open');
  renderDetail();
}
function closeDetail() {
  state.node = null;
  document.body.classList.remove('detail-open');
  setSel('');
  renderDetail();
}
document.getElementById('d-back').addEventListener('click', closeDetail);
function renderDetail() {
  var head = document.getElementById('d-head');
  var tabs = document.getElementById('d-tabs');
  var empty = document.getElementById('empty');
  if (!state.node) {
    head.hidden = true; tabs.hidden = true; empty.hidden = false;
    BODY.source.style.display = 'none'; BODY.source.innerHTML = '';
    BODY.conf.style.display = 'none'; BODY.conf.innerHTML = '';
    BODY.rel.style.display = 'none'; BODY.rel.innerHTML = '';
    return;
  }
  empty.hidden = true; head.hidden = false; tabs.hidden = false;
  var n = state.node;
  var crumb = (n.type === 'sym') ? (n.file + ':' + n.line) : (n.path || '');
  var crumbEl = document.getElementById('d-crumb');
  crumbEl.textContent = midTrunc(crumb, 56);
  crumbEl.title = crumb;
  document.getElementById('d-ktag').textContent = ktagOf(n);
  document.getElementById('d-name').textContent = n.name;
  var defs = tabDefsFor(n);
  buildTabbar(defs);
  if (n.type === 'sym') { renderSource(n); renderRel(n); }
  else { BODY.source.innerHTML = ''; BODY.rel.innerHTML = ''; }
  renderConf(n);
  var hasCur = false;
  defs.forEach(function (d) { if (d.key === state.tab) { hasCur = true; } });
  if (!hasCur) { state.tab = defs[0].key; }
  setTab(state.tab, true);
}

// ── 源码 tab ──
function renderSource(n) {
  var box = BODY.source;
  box.innerHTML = '';
  var code = FG.codeSnippets[n.id] || '';
  if (!code) { box.innerHTML = '<div class="noneword">' + T.srcNa + '</div>'; return; }
  var lines = code.split(NL);
  if (lines.length && lines[lines.length - 1] === '') { lines.pop(); }
  var start = n.line;
  var digits = Math.max(3, String(start + lines.length - 1).length);
  var byLine = {};
  n.findings.forEach(function (f) { if (!byLine[f.line]) { byLine[f.line] = f; } });
  var blk = document.createElement('div');
  blk.className = 'codeblock';
  blk.style.setProperty('--lnw', digits + 'ch');
  var h = '';
  for (var i = 0; i < lines.length; i++) {
    var ln = start + i;
    var f = byLine[ln];
    if (f) {
      h += '<div class="cline hasf" style="--tc:' + tierHex(f.weight) + '" data-ln="' + ln + '">'
        + '<span class="ln">' + ln + '</span><span class="lc">' + hl2(lines[i], n.lang || langOf(n.file)) + '</span></div>';
    } else {
      h += '<div class="cline"><span class="ln">' + ln + '</span><span class="lc">' + hl2(lines[i], n.lang || langOf(n.file)) + '</span></div>';
    }
  }
  blk.innerHTML = h;
  var meta = FN[n.id];
  if (meta && meta.trunc) {
    var note = document.createElement('div');
    note.className = 'truncnote';
    note.textContent = T.truncNote;
    blk.appendChild(note);
  }
  blk.addEventListener('click', function (e) {
    var cl = e.target.closest ? e.target.closest('.cline.hasf') : null;
    if (!cl) { return; }
    var ln2 = parseInt(cl.dataset.ln, 10);
    setTab('conf');
    var target = BODY.conf.querySelector('[data-fln="' + ln2 + '"]');
    if (target) { target.scrollIntoView({ block: 'center' }); }
  });
  box.appendChild(blk);
}

// ── 置信度 tab ──
function renderConf(n) {
  var box = BODY.conf;
  var list = [];
  if (n.type === 'sym') { list = n.findings; }
  else if (n.type === 'file') { list = n.fileFindings; }
  else { collectRoll(n, list); }
  var h = '';
  if (!CONF.astUsed && CONF.astNote) { h += '<div class="degrade">' + esc(CONF.astNote) + '</div>'; }
  if (!list.length) {
    h += '<div class="noneword">' + T.clean + '</div>';
  } else {
    var order = ['variable', 'function', 'type', 'pointer', 'concurrency', 'structure'];
    var groups = {};
    list.forEach(function (f) { (groups[f.dim] = groups[f.dim] || []).push(f); });
    order.forEach(function (dm) {
      var g = groups[dm];
      if (!g || !g.length) { return; }
      h += '<div class="sechead">' + T.dims[dm] + ' · ' + g.length + '</div>';
      g.forEach(function (f) {
        var c = tierHex(f.weight);
        h += '<div class="finding" data-fln="' + f.line + '"><div class="fmeta">'
          + '<span class="fdot" style="background:' + c + '"></span>'
          + '<span class="fkind">' + esc(f.kind) + '</span>'
          + '<span class="fline">L' + f.line + '</span></div>'
          + '<div class="fev">' + esc(f.evidence || '') + '</div></div>';
      });
    });
  }
  if (CONF.cappedTotal || CONF.cappedKind) { h += '<div class="capnote">' + T.capNote + '</div>'; }
  box.innerHTML = h;
}

// ── 关系 tab（re-center：点击 = 左树跳转定位该符号）──
function renderRel(n) {
  var box = BODY.rel;
  function edgeLess(a, b) {
    if (b[1] !== a[1]) { return b[1] - a[1]; }
    var na = FN[a[0]] ? FN[a[0]].name : a[0];
    var nb = FN[b[0]] ? FN[b[0]].name : b[0];
    return na < nb ? -1 : (na > nb ? 1 : 0);
  }
  var ins = (IN_EDGE[n.id] || []).slice().sort(edgeLess);
  var outs = (OUT_EDGE[n.id] || []).slice().sort(edgeLess);
  function relRowHtml(p) {
    var f = FN[p[0]];
    var nm = f ? f.name : p[0];
    var path = f ? f.file : '';
    return '<div class="relrow" data-peer="' + esc(p[0]) + '" role="button" tabindex="0">'
      + '<span class="rname2">' + esc(nm) + '</span>'
      + '<span class="rpath">' + esc(path) + '</span>'
      + '<span class="rw">×' + p[1] + '</span></div>';
  }
  var h = '<div class="sechead">' + T.callers + ' · ' + ins.length + '</div>';
  if (!ins.length) { h += '<div class="noneword">' + T.noneIn + '</div>'; }
  ins.forEach(function (p) { h += relRowHtml(p); });
  h += '<div class="sechead">' + T.callees + ' · ' + outs.length + '</div>';
  if (!outs.length) { h += '<div class="noneword">' + T.noneOut + '</div>'; }
  outs.forEach(function (p) { h += relRowHtml(p); });
  box.innerHTML = h;
  box.querySelectorAll('.relrow').forEach(function (el) {
    el.addEventListener('click', function () { jumpTo(el.dataset.peer); });
    el.addEventListener('keydown', function (ev) {
      if (ev.key === 'Enter') { jumpTo(el.dataset.peer); }
    });
  });
}
function jumpTo(id) {
  var sn = SYM_NODE[id];
  if (!sn) { return; }
  expandSet.root = true;
  var segs = sn.file.split('/');
  var acc = '';
  for (var i = 0; i < segs.length - 1; i++) {
    acc = acc ? acc + '/' + segs[i] : segs[i];
    expandSet['d:' + acc] = true;
  }
  expandSet['p:' + sn.file] = true;
  state.q = '';
  if (qEl) { qEl.value = ''; }
  setSel(id);
  refreshTree(false);
  var idx = rowIndexOf(id);
  if (idx >= 0) {
    scroller.scrollTop = Math.max(0, ROWS[idx].y - scroller.clientHeight / 2);
    paint();
  }
  openDetail(sn, 'source');
}

// ── 全局键盘（⌘1/⌘2/⌘3 切 tab · / 聚焦搜索 · Esc 清空或关闭详情）──
document.addEventListener('keydown', function (e) {
  if ((e.metaKey || e.ctrlKey) && (e.key === '1' || e.key === '2' || e.key === '3')) {
    var map = { '1': 'source', '2': 'conf', '3': 'rel' };
    var k = map[e.key];
    var has = false;
    TAB_BTNS.forEach(function (b) { if (b.dataset.k === k) { has = true; } });
    if (state.node && has) { setTab(k); e.preventDefault(); }
    return;
  }
  if (e.key === 'Escape') {
    if (document.activeElement === qEl && qEl.value) {
      qEl.value = '';
      state.q = '';
      refreshTree(false);
      qEl.blur();
      return;
    }
    if (state.node) { closeDetail(); }
    return;
  }
  if (e.key === '/') {
    var tag = document.activeElement ? document.activeElement.tagName : '';
    if (tag !== 'INPUT' && tag !== 'TEXTAREA' && document.activeElement !== qEl) {
      e.preventDefault();
      qEl.focus();
      qEl.select();
    }
  }
});

// ── 分隔线拖拽（240–420px，双击复位 296px）──
var treePane = document.querySelector('[data-pane="tree"]');
var divider = document.getElementById('divider');
var dragging = false;
divider.addEventListener('mousedown', function (e) {
  dragging = true;
  document.body.classList.add('dragging');
  e.preventDefault();
});
document.addEventListener('mousemove', function (e) {
  if (!dragging) { return; }
  var rect = document.querySelector('.shell').getBoundingClientRect();
  var w = e.clientX - rect.left;
  if (w < 240) { w = 240; }
  if (w > 420) { w = 420; }
  treePane.style.width = w + 'px';
});
document.addEventListener('mouseup', function () {
  if (dragging) { dragging = false; document.body.classList.remove('dragging'); }
});
divider.addEventListener('dblclick', function () { treePane.style.width = '296px'; });

// ── 初始化 ──
paintRootRow();
refreshTree(false);
renderDetail();
window.MoongitCodeGraph = {
  scene: D, functions: FG.functions, edges: FG.functionEdges,
  setFocus: function (id) { jumpTo(id); },
  closeDetail: closeDetail,
};
"""
}
