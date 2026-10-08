// graph/archscene.cj — 架构图场景构建器（驱动无关的 DisplayList）。
//
// 【分层】引擎算好**一切几何与语义**（布局/分层/依赖/统计/命中区域/动画时序），
// 产出 moongit-graph-scene v1 场景 JSON（契约见 docs/graph-scene-schema.md）。
// 驱动端（Web Canvas / CoreGraphics / SVG…）只按场景逐条执行——
// 「画什么」在引擎，「怎么画」在驱动。颜色一律用 token（cols.0 / text / node:id），
// 驱动绘制时按主题解析 ⇒ 主题切换不需要重新生成场景。
//
// 【确定性】全部排序化；粒子相位用 (i+1)/(n+1)，零随机数。
// 同一仓库两次导出场景 JSON 逐字节一致（graph_test 有守护）。
package moongit.graph

import std.collection.*
import std.convert.*
import moongit.util.*

// MARK: - 主题 token

/// 主题对象。色值直接内嵌两套（与 Web 驱动 v1 相同的取值）——
/// 主题切换由驱动在两套之间切换，场景无需重建。
func themeJson(): JsonValue {
    let dark = Json.obj()
    Json.set(dark, "bg0", Json.of("#0d1526"))
    Json.set(dark, "bg1", Json.of("#080d1a"))
    Json.set(dark, "grid", Json.of("#1a2740"))
    Json.set(dark, "text", Json.of("#e8eef8"))
    Json.set(dark, "muted", Json.of("#8b9bb4"))
    Json.set(dark, "border", Json.of("#263650"))
    Json.set(dark, "arrow", Json.of("#64748b"))
    Json.set(dark, "accent", Json.of("#34d399"))
    Json.set(dark, "cols", Json.strArray([
        "#38bdf8", "#a78bfa", "#34d399", "#fbbf24", "#8ea3bd"]))
    Json.set(dark, "fills", Json.strArray([
        "rgba(56,189,248,0.10)", "rgba(167,139,250,0.10)", "rgba(52,211,153,0.10)",
        "rgba(251,191,36,0.08)", "rgba(142,163,189,0.08)"]))
    let dlangs = Json.obj()
    Json.set(dlangs, "swift", Json.of("#f05138"))
    Json.set(dlangs, "cangjie", Json.of("#f7801e"))
    Json.set(dlangs, "ts", Json.of("#3178c6"))
    Json.set(dlangs, "python", Json.of("#3572a5"))
    Json.set(dlangs, "go", Json.of("#00add8"))
    Json.set(dlangs, "rust", Json.of("#dea584"))
    Json.set(dlangs, "java", Json.of("#b07219"))
    Json.set(dlangs, "kotlin", Json.of("#a97bff"))
    Json.set(dlangs, "c", Json.of("#555555"))
    Json.set(dlangs, "module", Json.of("#94a3b8"))
    Json.set(dark, "langs", dlangs)

    let light = Json.obj()
    Json.set(light, "bg0", Json.of("#f7f9fd"))
    Json.set(light, "bg1", Json.of("#eef2f8"))
    Json.set(light, "grid", Json.of("#e2e8f2"))
    Json.set(light, "text", Json.of("#0f172a"))
    Json.set(light, "muted", Json.of("#64748b"))
    Json.set(light, "border", Json.of("#d8e1ec"))
    Json.set(light, "arrow", Json.of("#9aa8bd"))
    Json.set(light, "accent", Json.of("#059669"))
    Json.set(light, "cols", Json.strArray([
        "#0284c7", "#7c3aed", "#059669", "#d97706", "#64748b"]))
    Json.set(light, "fills", Json.strArray([
        "rgba(2,132,199,0.07)", "rgba(124,58,237,0.07)", "rgba(5,150,105,0.07)",
        "rgba(217,119,6,0.07)", "rgba(100,116,139,0.07)"]))
    let llangs = Json.obj()
    Json.set(llangs, "swift", Json.of("#f05138"))
    Json.set(llangs, "cangjie", Json.of("#de6d10"))
    Json.set(llangs, "ts", Json.of("#3178c6"))
    Json.set(llangs, "python", Json.of("#3572a5"))
    Json.set(llangs, "go", Json.of("#00869b"))
    Json.set(llangs, "rust", Json.of("#b7410e"))
    Json.set(llangs, "java", Json.of("#b07219"))
    Json.set(llangs, "kotlin", Json.of("#7c4dff"))
    Json.set(llangs, "c", Json.of("#444444"))
    Json.set(llangs, "module", Json.of("#64748b"))
    Json.set(light, "langs", llangs)

    let th = Json.obj()
    Json.set(th, "dark", dark)
    Json.set(th, "light", light)
    return th
}

// MARK: - 视图构建（一个视图 = 一份 shapes/particles/hits/panels）

/// 视图构建的中间态：攒 shapes/particles/hits，最后装配成 view JSON。
class SceneView {
    let id: String
    let label: String
    let parent: String   // "" = 无
    let shapes = ArrayList<JsonValue>()
    let particles = ArrayList<JsonValue>()
    let hits = ArrayList<JsonValue>()
    let labels = HashMap<String, String>()
    let nodeTheme = HashMap<String, String>()
    let nodeLayer = HashMap<String, Int64>()
    let order = HashMap<String, Int64>()
    var bx0: Float64 = 0.0
    var by0: Float64 = 0.0
    var bx1: Float64 = 0.0
    var by1: Float64 = 0.0

    init(id: String, label: String, parent: String) {
        this.id = id
        this.label = label
        this.parent = parent
    }

    func addShape(o: JsonValue): Unit {
        shapes.add(o)
    }

    func addNode(id: String, label: String, colorToken: String,
                 x: Float64, y: Float64, w: Float64, h: Float64,
                 layer: Int64, ord: Int64, drill: String, jump: String): Unit {
        labels[id] = label
        nodeTheme[id] = colorToken
        nodeLayer[id] = layer
        order[id] = ord
        let hit = Json.obj()
        Json.set(hit, "id", Json.of(id))
        Json.set(hit, "x", Json.of(x))
        Json.set(hit, "y", Json.of(y))
        Json.set(hit, "w", Json.of(w))
        Json.set(hit, "h", Json.of(h))
        if (!drill.isEmpty()) { Json.set(hit, "drill", Json.of(drill)) }
        if (!jump.isEmpty()) { Json.set(hit, "jump", Json.of(jump)) }
        hits.add(hit)
    }

    func computeBounds(): Unit {
        var first = true
        for (h in hits) {
            let hx = Json.numAt(h, "x", 0.0)
            let hy = Json.numAt(h, "y", 0.0)
            let hw = Json.numAt(h, "w", 0.0)
            let hh = Json.numAt(h, "h", 0.0)
            if (first) {
                bx0 = hx - 60.0
                by0 = hy - 90.0
                bx1 = hx + hw + 60.0
                by1 = hy + hh + 60.0
                first = false
            } else {
                if (hx - 60.0 < bx0) { bx0 = hx - 60.0 }
                if (hy - 90.0 < by0) { by0 = hy - 90.0 }
                if (hx + hw + 60.0 > bx1) { bx1 = hx + hw + 60.0 }
                if (hy + hh + 60.0 > by1) { by1 = hy + hh + 60.0 }
            }
        }
    }
}

/// 场景装配：架构视图 + 每模块文件级子视图 + panels + meta + 主题。
public func buildArchScene(data: ArchData, en: Bool): JsonValue {
    layoutArch(data)
    let ui = archUiText(en)

    // ── 架构视图 ──
    let arch = SceneView("arch", ui.root, "")
    // 排序后的模块列表（order 与绘制序）
    let sorted = ArrayList<ArchModule>()
    for (m in data.modules) { sorted.add(m) }
    insertionSortBy(sorted, { a, b => a.id < b.id })
    var ord: Int64 = 1
    for (m in sorted) {
        arch.order[m.id] = ord
        ord += 1
    }
    // 层框（虚线 + 标签）
    var col = 0
    while (col < LAYER_COUNT) {
        let colMods = ArrayList<ArchModule>()
        for (m in sorted) { if (m.layer == col) { colMods.add(m) } }
        if (colMods.size > 0) {
            var x0 = 0.0
            var y0 = 0.0
            var x1 = 0.0
            var y1 = 0.0
            var first = true
            for (m in colMods) {
                if (first) {
                    x0 = m.x - 18.0
                    y0 = m.y - 46.0
                    x1 = m.x + m.w + 18.0
                    y1 = m.y + m.h + 18.0
                    first = false
                } else {
                    if (m.x - 18.0 < x0) { x0 = m.x - 18.0 }
                    if (m.y - 46.0 < y0) { y0 = m.y - 46.0 }
                    if (m.x + m.w + 18.0 > x1) { x1 = m.x + m.w + 18.0 }
                    if (m.y + m.h + 18.0 > y1) { y1 = m.y + m.h + 18.0 }
                }
            }
            let frame = Json.obj()
            Json.set(frame, "t", Json.of("frame"))
            Json.set(frame, "x", Json.of(x0))
            Json.set(frame, "y", Json.of(y0))
            Json.set(frame, "w", Json.of(x1 - x0))
            Json.set(frame, "h", Json.of(y1 - y0))
            Json.set(frame, "label", Json.of("${layerName(col, en)}  L${col}"))
            Json.set(frame, "color", Json.of("cols.${col}"))
            arch.addShape(frame)
        }
        col += 1
    }
    // 边（渐变 + 箭头 + 生长动画声明）
    for ((a, b, w) in data.edges) {
        match ((findModule(sorted, a), findModule(sorted, b))) {
            case (Some(am), Some(bm)) =>
        let x1 = am.x + am.w
        let y1 = am.y + am.h / 2.0
        let x2 = bm.x
        let y2 = bm.y + bm.h / 2.0
        let mx = (x1 + x2) / 2.0
        let e = Json.obj()
        Json.set(e, "t", Json.of("edge"))
        Json.set(e, "p", numsJson([x1, y1, mx, y1, mx, y2, x2, y2]))
        Json.set(e, "c0", Json.of("node:${a}"))
        Json.set(e, "c1", Json.of("node:${b}"))
        Json.set(e, "sw", Json.of(if (w > 8) { 3.0 } else { if (w > 3) { 2.2 } else { 1.4 } }))
        Json.set(e, "alpha", Json.of(if (w > 8) { 0.9 } else { if (w > 3) { 0.7 } else { 0.5 } }))
        Json.set(e, "arrow", Json.of(9.0))
        Json.set(e, "edge", Json.strArray([a, b]))
        Json.set(e, "delay", Json.of(300.0 + Float64(am.layer + bm.layer) * 50.0))
        arch.addShape(e)
        // 粒子（密度 ∝ 权重；相位确定性）
        let n = if (1 + w / 5 < 6) { 1 + w / 5 } else { 6 }
        let parts = Json.obj()
        Json.set(parts, "p", numsJson([x1, y1, mx, y1, mx, y2, x2, y2]))
        Json.set(parts, "n", Json.of(n))
        Json.set(parts, "sp", Json.of(0.00012 + Float64(w) * 0.000004))
        Json.set(parts, "color", Json.of("node:${b}"))
        arch.particles.add(parts)
            case _ => ()
        }
    }
    // 节点（bg / 左色条 / 标签 / 副行 / 下钻角标）
    for (m in sorted) {
        let tok = "cols.${m.layer}"
        let myOrd = match (arch.order.get(m.id)) {
            case Some(c) => c
            case None => 1
        }
        arch.addNode(m.id, m.id, tok, m.x, m.y, m.w, m.h, m.layer, myOrd,
            "module:${m.id}", "")
        let bg = Json.obj()
        Json.set(bg, "t", Json.of("rrect"))
        Json.set(bg, "x", Json.of(m.x))
        Json.set(bg, "y", Json.of(m.y))
        Json.set(bg, "w", Json.of(m.w))
        Json.set(bg, "h", Json.of(m.h))
        Json.set(bg, "r", Json.of(11.0))
        Json.set(bg, "fill", Json.of("panel"))
        Json.set(bg, "stroke", Json.of("node:${m.id}"))
        Json.set(bg, "sw", Json.of(1.2))
        Json.set(bg, "node", Json.of(m.id))
        arch.addShape(bg)
        let bar = Json.obj()
        Json.set(bar, "t", Json.of("rect"))
        Json.set(bar, "x", Json.of(m.x))
        Json.set(bar, "y", Json.of(m.y + 9.0))
        Json.set(bar, "w", Json.of(3.2))
        Json.set(bar, "h", Json.of(m.h - 18.0))
        Json.set(bar, "fill", Json.of("node:${m.id}"))
        Json.set(bar, "node", Json.of(m.id))
        arch.addShape(bar)
        let label = Json.obj()
        Json.set(label, "t", Json.of("text"))
        Json.set(label, "x", Json.of(m.x + 13.0))
        Json.set(label, "y", Json.of(m.y + 23.0))
        Json.set(label, "text", Json.of(m.id))
        Json.set(label, "size", Json.of(13.0))
        Json.set(label, "weight", Json.of(600))
        Json.set(label, "color", Json.of("text"))
        Json.set(label, "align", Json.of("left"))
        Json.set(label, "maxw", Json.of(m.w - 22.0))
        Json.set(label, "node", Json.of(m.id))
        arch.addShape(label)
        let sub = Json.obj()
        Json.set(sub, "t", Json.of("text"))
        Json.set(sub, "x", Json.of(m.x + 13.0))
        Json.set(sub, "y", Json.of(m.y + m.h - 12.0))
        Json.set(sub, "text", Json.of("${m.files} ${ui.filesWord} · ${m.symbols} ${ui.symWord} · ${m.lines} ${ui.lineWord}"))
        Json.set(sub, "size", Json.of(11.0))
        Json.set(sub, "weight", Json.of(400))
        Json.set(sub, "color", Json.of("muted"))
        Json.set(sub, "align", Json.of("left"))
        Json.set(sub, "maxw", Json.of(m.w - 22.0))
        Json.set(sub, "node", Json.of(m.id))
        arch.addShape(sub)
        if (hasDrilldown(data, m.id)) {
            let plus = Json.obj()
            Json.set(plus, "t", Json.of("text"))
            Json.set(plus, "x", Json.of(m.x + m.w - 14.0))
            Json.set(plus, "y", Json.of(m.y + 20.0))
            Json.set(plus, "text", Json.of("+"))
            Json.set(plus, "size", Json.of(11.0))
            Json.set(plus, "weight", Json.of(400))
            Json.set(plus, "color", Json.of("muted"))
            Json.set(plus, "align", Json.of("right"))
            Json.set(plus, "node", Json.of(m.id))
            arch.addShape(plus)
        }
    }
    arch.computeBounds()

    // ── 模块子视图（文件级）──
    let views = Json.obj()
    viewsSet(views, "arch", archViewJson(arch, data))
    let panels = Json.obj()

    // 架构级 panel（每模块）
    for (m in sorted) {
        let po = Json.obj()
        Json.set(po, "title", Json.of(m.id))
        Json.set(po, "sub", Json.of("${ui.layerWord} L${m.layer} · ${layerName(m.layer, en)}"))
        Json.set(po, "stats", Json.of("${m.files} ${ui.filesWord} · ${m.symbols} ${ui.symWord} · ${m.lines} ${ui.lineWord}"))
        Json.set(po, "langs", Json.strArray(m.langs.toArray()))
        let o = ArrayList<JsonValue>()
        let i2 = ArrayList<JsonValue>()
        for ((a, b, w) in data.edges) {
            if (a == m.id) {
                let d = Json.obj()
                Json.set(d, "id", Json.of(b))
                Json.set(d, "w", Json.of(w))
                o.add(d)
            }
            if (b == m.id) {
                let d = Json.obj()
                Json.set(d, "id", Json.of(a))
                Json.set(d, "w", Json.of(w))
                i2.add(d)
            }
        }
        Json.set(po, "out", JArr(o))
        Json.set(po, "in", JArr(i2))
        Json.set(panels, "arch:${m.id}", po)
    }

    // 模块子视图
    for (dg in data.drilldown) {
        let v = SceneView("module:${dg.moduleId}", dg.moduleId, "arch")
        var ford: Int64 = 1
        for (n in dg.nodes) {
            let tok = if (n.external) { "langs.module" } else { "langs.${n.lang}" }
            v.addNode(n.id, n.label, tok, n.x, n.y, n.w, n.h, -1, ford,
                "", if (n.external) { "module:${n.label}" } else { "" })
            ford += 1
            let bg = Json.obj()
            Json.set(bg, "t", Json.of("rrect"))
            Json.set(bg, "x", Json.of(n.x))
            Json.set(bg, "y", Json.of(n.y))
            Json.set(bg, "w", Json.of(n.w))
            Json.set(bg, "h", Json.of(n.h))
            Json.set(bg, "r", Json.of(10.0))
            Json.set(bg, "fill", Json.of("panel"))
            Json.set(bg, "stroke", Json.of("node:${n.id}"))
            Json.set(bg, "sw", Json.of(1.2))
            Json.set(bg, "node", Json.of(n.id))
            v.addShape(bg)
            let bar = Json.obj()
            Json.set(bar, "t", Json.of("rect"))
            Json.set(bar, "x", Json.of(n.x))
            Json.set(bar, "y", Json.of(n.y + 8.0))
            Json.set(bar, "w", Json.of(3.0))
            Json.set(bar, "h", Json.of(n.h - 16.0))
            Json.set(bar, "fill", Json.of("node:${n.id}"))
            Json.set(bar, "node", Json.of(n.id))
            v.addShape(bar)
            let lb = Json.obj()
            Json.set(lb, "t", Json.of("text"))
            Json.set(lb, "x", Json.of(n.x + 12.0))
            Json.set(lb, "y", Json.of(n.y + 21.0))
            let disp = if (n.external) { "@ ${n.label}" } else { n.label }
            Json.set(lb, "text", Json.of(disp))
            Json.set(lb, "size", Json.of(12.0))
            Json.set(lb, "weight", Json.of(600))
            Json.set(lb, "color", Json.of("text"))
            Json.set(lb, "align", Json.of("left"))
            Json.set(lb, "maxw", Json.of(n.w - 20.0))
            Json.set(lb, "node", Json.of(n.id))
            v.addShape(lb)
            let subT = if (n.external) { ui.moduleWord } else { "${n.lang} · ${n.symbols} ${ui.symWord} · ${n.lines} ${ui.lineWord}" }
            let sub = Json.obj()
            Json.set(sub, "t", Json.of("text"))
            Json.set(sub, "x", Json.of(n.x + 12.0))
            Json.set(sub, "y", Json.of(n.y + n.h - 11.0))
            Json.set(sub, "text", Json.of(subT))
            Json.set(sub, "size", Json.of(11.0))
            Json.set(sub, "weight", Json.of(400))
            Json.set(sub, "color", Json.of("muted"))
            Json.set(sub, "align", Json.of("left"))
            Json.set(sub, "maxw", Json.of(n.w - 20.0))
            Json.set(sub, "node", Json.of(n.id))
            v.addShape(sub)
        }
        for ((a, b, w) in dg.edges) {
            match ((drillFind(dg.nodes, a), drillFind(dg.nodes, b))) {
                case (Some(an), Some(bn)) =>
            let x1 = an.x + an.w
            let y1 = an.y + an.h / 2.0
            let x2 = bn.x
            let y2 = bn.y + bn.h / 2.0
            let mx = (x1 + x2) / 2.0
            let e = Json.obj()
            Json.set(e, "t", Json.of("edge"))
            Json.set(e, "p", numsJson([x1, y1, mx, y1, mx, y2, x2, y2]))
            Json.set(e, "c0", Json.of("node:${a}"))
            Json.set(e, "c1", Json.of("node:${b}"))
            Json.set(e, "sw", Json.of(1.4))
            Json.set(e, "alpha", Json.of(0.55))
            Json.set(e, "arrow", Json.of(8.0))
            Json.set(e, "edge", Json.strArray([a, b]))
            Json.set(e, "delay", Json.of(260.0))
            v.addShape(e)
            let parts = Json.obj()
            Json.set(parts, "p", numsJson([x1, y1, mx, y1, mx, y2, x2, y2]))
            Json.set(parts, "n", Json.of(1))
            Json.set(parts, "sp", Json.of(0.00012))
            Json.set(parts, "color", Json.of("node:${b}"))
            v.particles.add(parts)
                case _ => ()
            }
        }
        v.computeBounds()
        viewsSet(views, v.id, sceneViewJson(v))

        // 文件级 panel
        for (n in dg.nodes) {
            if (n.external) { continue }
            let po = Json.obj()
            Json.set(po, "title", Json.of(n.label))
            Json.set(po, "sub", Json.of("${n.lang} · ${n.lines} ${ui.lineWord}"))
            Json.set(po, "stats", Json.of("${n.symbols} ${ui.symWord}"))
            Json.set(po, "out", JArr(ArrayList<JsonValue>()))
            Json.set(po, "in", JArr(ArrayList<JsonValue>()))
            Json.set(panels, "${v.id}:${n.id}", po)
        }
    }

    // ── 装配 ──
    let chips = ArrayList<JsonValue>()
    col = 0
    while (col < LAYER_COUNT) {
        var count: Int64 = 0
        for (m in data.modules) { if (m.layer == col) { count += 1 } }
        if (count > 0) {
            let c = Json.obj()
            Json.set(c, "layer", Json.of(col))
            Json.set(c, "label", Json.of("${layerName(col, en)} ${count}"))
            chips.add(c)
        }
        col += 1
    }
    let meta = Json.obj()
    Json.set(meta, "title", Json.of(ui.title))
    Json.set(meta, "sub", Json.of(ui.sub))
    Json.set(meta, "stats", Json.of("${data.totalFiles} ${ui.filesWord} / ${data.totalSymbols} ${ui.symWord} / ${data.totalLines} ${ui.lineWord}"))
    Json.set(meta, "hint", Json.of(ui.hint))
    Json.set(meta, "root", Json.of(ui.root))
    Json.set(meta, "search", Json.of(ui.search))
    Json.set(meta, "fit", Json.of(ui.fit))
    Json.set(meta, "themeBtn", Json.of(ui.theme))
    Json.set(meta, "chips", JArr(chips))
    let pw = Json.obj()
    Json.set(pw, "out", Json.of(ui.depsOut))
    Json.set(pw, "in", Json.of(ui.depsIn))
    Json.set(pw, "none", Json.of(ui.none))
    Json.set(pw, "layer", Json.of(ui.layerWord))
    Json.set(pw, "esc", Json.of(ui.closeHint))
    Json.set(pw, "files", Json.of(ui.filesWord))
    Json.set(pw, "syms", Json.of(ui.symWord))
    Json.set(pw, "lines", Json.of(ui.lineWord))
    Json.set(pw, "module", Json.of(ui.moduleWord))
    Json.set(meta, "panel", pw)

    let o = Json.obj()
    Json.set(o, "v", Json.of(1))
    Json.set(o, "gen", Json.of("moongit-graph"))
    Json.set(o, "meta", meta)
    Json.set(o, "themes", themeJson())
    Json.set(o, "views", views)
    Json.set(o, "panels", panels)
    return o
}

func findModule(list: ArrayList<ArchModule>, id: String): Option<ArchModule> {
    for (m in list) {
        if (m.id == id) { return Some(m) }
    }
    return None
}

func drillFind(list: ArrayList<DrillNode>, id: String): Option<DrillNode> {
    for (n in list) {
        if (n.id == id) { return Some(n) }
    }
    return None
}

func hasDrilldown(data: ArchData, moduleId: String): Bool {
    for (dg in data.drilldown) {
        if (dg.moduleId == moduleId) { return true }
    }
    return false
}

func numsJson(vals: Array<Float64>): JsonValue {
    let a = ArrayList<JsonValue>()
    for (v in vals) { a.add(Json.of(v)) }
    return JArr(a)
}

func archViewJson(v: SceneView, data: ArchData): JsonValue {
    let o = Json.obj()
    Json.set(o, "label", Json.of(v.label))
    if (!v.parent.isEmpty()) {
        Json.set(o, "parent", Json.of(v.parent))
    }
    let b = Json.obj()
    Json.set(b, "x0", Json.of(v.bx0))
    Json.set(b, "y0", Json.of(v.by0))
    Json.set(b, "x1", Json.of(v.bx1))
    Json.set(b, "y1", Json.of(v.by1))
    Json.set(o, "bounds", b)
    let nt = Json.obj()
    for ((k, tok) in v.nodeTheme) { Json.set(nt, k, Json.of(tok)) }
    Json.set(o, "nodeTheme", nt)
    let nl = Json.obj()
    for ((k, l) in v.nodeLayer) { Json.set(nl, k, Json.of(l)) }
    Json.set(o, "nodeLayer", nl)
    let od = Json.obj()
    for ((k, c) in v.order) { Json.set(od, k, Json.of(c)) }
    Json.set(o, "order", od)
    let lbl = Json.obj()
    for ((k, s) in v.labels) { Json.set(lbl, k, Json.of(s)) }
    Json.set(o, "labels", lbl)
    Json.set(o, "shapes", JArr(v.shapes))
    Json.set(o, "particles", JArr(v.particles))
    Json.set(o, "hits", JArr(v.hits))
    return o
}

func sceneViewJson(v: SceneView): JsonValue {
    let o = Json.obj()
    Json.set(o, "label", Json.of(v.label))
    if (!v.parent.isEmpty()) {
        Json.set(o, "parent", Json.of(v.parent))
    }
    let b = Json.obj()
    Json.set(b, "x0", Json.of(v.bx0))
    Json.set(b, "y0", Json.of(v.by0))
    Json.set(b, "x1", Json.of(v.bx1))
    Json.set(b, "y1", Json.of(v.by1))
    Json.set(o, "bounds", b)
    let nt = Json.obj()
    for ((k, tok) in v.nodeTheme) { Json.set(nt, k, Json.of(tok)) }
    Json.set(o, "nodeTheme", nt)
    let nl = Json.obj()
    for ((k, l) in v.nodeLayer) { Json.set(nl, k, Json.of(l)) }
    Json.set(o, "nodeLayer", nl)
    let od = Json.obj()
    for ((k, c) in v.order) { Json.set(od, k, Json.of(c)) }
    Json.set(o, "order", od)
    let lbl = Json.obj()
    for ((k, s) in v.labels) { Json.set(lbl, k, Json.of(s)) }
    Json.set(o, "labels", lbl)
    Json.set(o, "shapes", JArr(v.shapes))
    Json.set(o, "particles", JArr(v.particles))
    Json.set(o, "hits", JArr(v.hits))
    return o
}

func viewsSet(views: JsonValue, key: String, v: JsonValue): Unit {
    Json.set(views, key, v)
}
