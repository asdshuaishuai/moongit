// graph/archscene.cj — 架构图场景构建器（驱动无关的 DisplayList）。
//
// 【分层】引擎算好**一切几何与语义**（布局/分层/依赖/统计/命中区域/动画时序），
// 产出 moongit-graph-scene v1 场景 JSON（契约见 docs/graph-scene-schema.md）。
// 驱动端（Web Canvas / CoreGraphics / SVG…）只按场景逐条执行——
// 「画什么」在引擎，「怎么画」在驱动。颜色一律用 token（cols.0 / text / node:id），
// 驱动绘制时按主题解析 ⇒ 主题切换不需要重新生成场景。
//
// 【确定性】全部排序化；粒子相位用 (i+1)/(n+1)，零随机数。
// 同一仓库两次导出场景 JSON 逐字节一致。
//
// ⚠️ M11：这里原来写的是「graph_test 有守护」—— 而那条测试**并不存在**
// （审查时逐条找过：没有任何断言钉住场景导出的字节序）。一句失实的守护声明
// 比没有声明更糟：读者会以为改动被兜住，于是放心重构。
// 现在补上真守护（graph_test 的 testSceneExportIsDeterministic）。
package moongit.graph

import std.collection.*
import std.convert.*
import moongit.util.*

// MARK: - 主题 token

/// 语言 → 色值表的**唯一构造点**（清单与色值只许写这一份）。
/// 三处消费方各自派生输出形态，不许再抄色值字面量（多份手抄副本必然漂移，
/// 漂移的症状是同一语言在 scene / 架构图页 / 图谱页三个画面颜色不一致）：
///   · themeJson()（本文件）—— scene 的 themes.{dark,light}.langs
///   · archhtml.cj 的 langPaletteJs —— 内嵌驱动 JS 的 PAL.{dark,light}.langs
///   · treehtml.cj 的 langThemesJson —— 图谱页的 langThemes.{dark,light}
/// 返回顺序（swift…module）是契约的一部分：三处输出按此序生成，字节级稳定。
public func langThemeColors(dark: Bool): ArrayList<(String, String)> {
    let out = ArrayList<(String, String)>()
    if (dark) {
        out.add(("swift", "#f05138"))
        out.add(("cangjie", "#f7801e"))
        out.add(("ts", "#3178c6"))
        out.add(("python", "#3572a5"))
        out.add(("go", "#00add8"))
        out.add(("rust", "#dea584"))
        out.add(("java", "#b07219"))
        out.add(("kotlin", "#a97bff"))
        out.add(("c", "#555555"))
        out.add(("module", "#94a3b8"))
    } else {
        out.add(("swift", "#f05138"))
        out.add(("cangjie", "#de6d10"))
        out.add(("ts", "#3178c6"))
        out.add(("python", "#3572a5"))
        out.add(("go", "#00869b"))
        out.add(("rust", "#b7410e"))
        out.add(("java", "#b07219"))
        out.add(("kotlin", "#7c4dff"))
        out.add(("c", "#444444"))
        out.add(("module", "#64748b"))
    }
    return out
}

/// langs 主题 token（scene 契约形态）：从 langThemeColors 派生，
/// 键序 = 构造点顺序（JObj 按插入序序列化）。
func langsTokenJson(dark: Bool): JsonValue {
    let o = Json.obj()
    for ((lang, color) in langThemeColors(dark)) {
        Json.set(o, lang, Json.of(color))
    }
    return o
}

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
    Json.set(dark, "langs", langsTokenJson(true))
    // M13：场景 JSON 的节点底色用的是 token `panel`，而 themes 里原来
    // **根本没有这个色值**——schema 文档承诺「颜色一律 token，按当前主题解析」
    // 且未定义未知 token 的回退语义，于是第三方驱动必然落空。
    // 引擎自带 Web 驱动不受影响（它内嵌 archJson，panel 由 CSS var 提供）——
    // 那正是它一直没被发现的原因。
    Json.set(dark, "panel", Json.of("#131e35"))
    // 语义色 token（不稳定度条三档的「危险/警戒」两档；绿档复用 accent）：
    // 场景出口不许发裸 hex —— 不在 token 表里的值驱动按「引擎违约」处理。
    Json.set(dark, "bad", Json.of("#f87171"))
    Json.set(dark, "warn", Json.of("#fbbf24"))

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
    Json.set(light, "langs", langsTokenJson(false))
    Json.set(light, "panel", Json.of("#ffffff"))
    Json.set(light, "bad", Json.of("#dc2626"))
    Json.set(light, "warn", Json.of("#d97706"))

    let th = Json.obj()
    Json.set(th, "dark", dark)
    Json.set(th, "light", light)
    return th
}

// MARK: - 视图构建（一个视图 = 一份 shapes/particles/hits/panels）

/// 单视图最多导出的边数 —— **兜底**，不是容量调节手段。
/// 容量由运行期堆决定（`cjHeapSize`，见 README「已知边界」）；这项上限只防御
/// 「病态规模的视图」把输出炸掉：scene 的每条边会展开成「渐变形状 + 流动粒子」两组对象。
/// 阈值取得刻意宽：实测最"正常的大仓库"单视图 ≤560 边、极端单视图 8836 边 —— 都不会被截断。
/// 一旦真的触发，按**权重降序**保留（留最重的依赖 —— 有原则的截断），
/// 并在视图里**恒发** `edgesDropped`（同不变量 33：截断必须披露）。
public let SCENE_MAX_EDGES_PER_VIEW: Int64 = 10000

/// 取视图要导出的边：按 (权重↓, from↑, to↑) 排序后截断到 max 条。返回 (保留, 丢弃数)。
func sceneEdges(edges: ArrayList<(String, String, Int64)>, max: Int64): (ArrayList<(String, String, Int64)>, Int64) {
    let sorted = ArrayList<(String, String, Int64)>()
    for (e in edges) { sorted.add(e) }
    insertionSortBy(sorted, { a, b =>
        if (a[2] != b[2]) { return a[2] > b[2] }
        if (a[0] != b[0]) { return a[0] < b[0] }
        return a[1] < b[1]
    })
    let kept = ArrayList<(String, String, Int64)>()
    var i: Int64 = 0
    while (i < Int64(sorted.size) && i < max) {
        kept.add(sorted[i])
        i += 1
    }
    return (kept, Int64(sorted.size) - Int64(kept.size))
}

/// ArchEdge 版本的容量截断（按权重降序，tie 按 from/to）。
func sceneEdgesArch(edges: ArrayList<ArchEdge>, max: Int64): (ArrayList<ArchEdge>, Int64) {
    let sorted = ArrayList<ArchEdge>()
    for (e in edges) { sorted.add(e) }
    insertionSortBy(sorted, { a, b =>
        if (a.weight != b.weight) { return a.weight > b.weight }
        if (a.fromId != b.fromId) { return a.fromId < b.fromId }
        return a.toId < b.toId
    })
    let kept = ArrayList<ArchEdge>()
    var i: Int64 = 0
    while (i < Int64(sorted.size) && i < max) {
        kept.add(sorted[i])
        i += 1
    }
    return (kept, Int64(sorted.size) - Int64(kept.size))
}

/// 边宽 ∝ weight：min(3.5, 1 + weight*0.15)。架构视图与下钻视图共用
/// 这一个公式——同一个量只允许一个算法（两处各写一份必然漂移，
/// Web 驱动的 renderJs 侧同式，两侧对同一数据画出的边一样粗）。
func archEdgeStroke(weight: Int64): Float64 {
    let v = 1.0 + Float64(weight) * 0.15
    return if (v > 3.5) { 3.5 } else { v }
}

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
    /// 因上限而未导出的边数（恒发；>0 时驱动应告知「图不完整」）
    var dropped: Int64 = 0

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
    // 泳道（分层泳道布局：几何唯一来源 = archLaneRects，与 archJson 的 lanes
    // 是同一份——这里不再从模块 bounds 反推，反推是第二份布局必然漂移）。
    // fill token 让认识 fills 的驱动画出「按层配色的实色淡底泳道」；
    // 只认描边的既有驱动忽略追加键、仍按 frame 画框——向后兼容。
    for (lane in archLaneRects(data, en)) {
        let li = Json.intAt(lane, "layer", 0)
        let lx = Json.numAt(lane, "x", 0.0)
        let ly = Json.numAt(lane, "y", 0.0)
        let lw = Json.numAt(lane, "w", 0.0)
        let lh = Json.numAt(lane, "h", 0.0)
        let lc = Json.intAt(lane, "modules", 0)
        let frame = Json.obj()
        Json.set(frame, "t", Json.of("frame"))
        Json.set(frame, "x", Json.of(lx))
        Json.set(frame, "y", Json.of(ly))
        Json.set(frame, "w", Json.of(lw))
        Json.set(frame, "h", Json.of(lh))
        Json.set(frame, "label", Json.of("L${li} ${layerName(li, en)} · ${lc} ${ui.modulesWord}"))
        Json.set(frame, "color", Json.of("cols.${li}"))
        Json.set(frame, "fill", Json.of("fills.${li}"))
        arch.addShape(frame)
    }
    // 边（渐变 + 箭头 + 生长动画声明）。受 SCENE_MAX_EDGES_PER_VIEW 限制并披露丢弃数。
    let (archEdges, archDropped) = sceneEdgesArch(data.edges, SCENE_MAX_EDGES_PER_VIEW)
    arch.dropped = archDropped
    for (ae in archEdges) {
        match ((findModule(sorted, ae.fromId), findModule(sorted, ae.toId))) {
            case (Some(am), Some(bm)) =>
        let x1 = am.x + am.w
        let y1 = am.y + am.h / 2.0
        let x2 = bm.x
        let y2 = bm.y + bm.h / 2.0
        let mx = (x1 + x2) / 2.0
        let shape = Json.obj()
        Json.set(shape, "t", Json.of("edge"))
        Json.set(shape, "p", numsJson([x1, y1, mx, y1, mx, y2, x2, y2]))
        Json.set(shape, "c0", Json.of("node:${ae.fromId}"))
        Json.set(shape, "c1", Json.of("node:${ae.toId}"))
        Json.set(shape, "sw", Json.of(archEdgeStroke(ae.weight)))
        Json.set(shape, "alpha", Json.of(if (ae.weight > 8) { 0.9 } else { if (ae.weight > 3) { 0.7 } else { 0.5 } }))
        Json.set(shape, "arrow", Json.of(9.0))
        Json.set(shape, "edge", Json.strArray([ae.fromId, ae.toId]))
        Json.set(shape, "delay", Json.of(300.0 + Float64(am.layer + bm.layer) * 50.0))
        if (ae.violation) { Json.set(shape, "viol", Json.of(true)) }
        if (ae.cycle) { Json.set(shape, "cyc", Json.of(true)) }
        arch.addShape(shape)
        // 粒子（密度 ∝ 权重；相位确定性）
        let n = if (1 + ae.weight / 5 < 6) { 1 + ae.weight / 5 } else { 6 }
        let parts = Json.obj()
        Json.set(parts, "p", numsJson([x1, y1, mx, y1, mx, y2, x2, y2]))
        Json.set(parts, "n", Json.of(n))
        Json.set(parts, "sp", Json.of(0.00012 + Float64(ae.weight) * 0.000004))
        Json.set(parts, "color", Json.of("node:${ae.toId}"))
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
        Json.set(label, "x", Json.of(m.x + 12.0))
        Json.set(label, "y", Json.of(m.y + 22.0))
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
        Json.set(sub, "x", Json.of(m.x + 12.0))
        Json.set(sub, "y", Json.of(m.y + 39.0))
        Json.set(sub, "text", Json.of("${m.files} ${ui.filesWord} · ${m.symbols} ${ui.symWord} · ${m.lines} ${ui.lineWord}"))
        Json.set(sub, "size", Json.of(11.0))
        Json.set(sub, "weight", Json.of(400))
        Json.set(sub, "color", Json.of("muted"))
        Json.set(sub, "align", Json.of("left"))
        Json.set(sub, "maxw", Json.of(m.w - 22.0))
        Json.set(sub, "node", Json.of(m.id))
        arch.addShape(sub)
        // 入出徽标 + 不稳定度条（60×5，按 instability% 填充；三档色 token：
        // >66 bad / 33..66 warn / <33 accent——阈值只写这一处，Web 驱动同式）
        let fan = Json.obj()
        Json.set(fan, "t", Json.of("text"))
        Json.set(fan, "x", Json.of(m.x + 12.0))
        Json.set(fan, "y", Json.of(m.y + 59.0))
        Json.set(fan, "text", Json.of("${ui.inShort} ${m.fanIn} / ${ui.outShort} ${m.fanOut}"))
        Json.set(fan, "size", Json.of(10.0))
        Json.set(fan, "weight", Json.of(400))
        Json.set(fan, "color", Json.of("muted"))
        Json.set(fan, "align", Json.of("left"))
        Json.set(fan, "node", Json.of(m.id))
        arch.addShape(fan)
        let barBg = Json.obj()
        Json.set(barBg, "t", Json.of("rect"))
        Json.set(barBg, "x", Json.of(m.x + 96.0))
        Json.set(barBg, "y", Json.of(m.y + 52.0))
        Json.set(barBg, "w", Json.of(60.0))
        Json.set(barBg, "h", Json.of(5.0))
        Json.set(barBg, "fill", Json.of("border"))
        Json.set(barBg, "node", Json.of(m.id))
        arch.addShape(barBg)
        let instTok = if (m.instability > 66) { "bad" } else { if (m.instability >= 33) { "warn" } else { "accent" } }
        let barFill = Json.obj()
        Json.set(barFill, "t", Json.of("rect"))
        Json.set(barFill, "x", Json.of(m.x + 96.0))
        Json.set(barFill, "y", Json.of(m.y + 52.0))
        Json.set(barFill, "w", Json.of(60.0 * Float64(m.instability) / 100.0))
        Json.set(barFill, "h", Json.of(5.0))
        Json.set(barFill, "fill", Json.of(instTok))
        Json.set(barFill, "node", Json.of(m.id))
        arch.addShape(barFill)
        let instPct = Json.obj()
        Json.set(instPct, "t", Json.of("text"))
        Json.set(instPct, "x", Json.of(m.x + 162.0))
        Json.set(instPct, "y", Json.of(m.y + 59.0))
        Json.set(instPct, "text", Json.of("${m.instability}%"))
        Json.set(instPct, "size", Json.of(9.0))
        Json.set(instPct, "weight", Json.of(400))
        Json.set(instPct, "color", Json.of(instTok))
        Json.set(instPct, "align", Json.of("left"))
        Json.set(instPct, "node", Json.of(m.id))
        arch.addShape(instPct)
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
    // bounds 必须把泳道框进来：computeBounds 只看 hits（卡片），而泳道左端的
    // 层标签区在最左卡片左侧 150px——不扩进去，按 bounds fit 的驱动会把它裁掉
    for (lane in archLaneRects(data, en)) {
        let lx = Json.numAt(lane, "x", 0.0)
        let ly = Json.numAt(lane, "y", 0.0)
        let lw = Json.numAt(lane, "w", 0.0)
        let lh = Json.numAt(lane, "h", 0.0)
        if (lx - 60.0 < arch.bx0) { arch.bx0 = lx - 60.0 }
        if (ly - 90.0 < arch.by0) { arch.by0 = ly - 90.0 }
        if (lx + lw + 60.0 > arch.bx1) { arch.bx1 = lx + lw + 60.0 }
        if (ly + lh + 60.0 > arch.by1) { arch.by1 = ly + lh + 60.0 }
    }

    // ── 模块子视图（文件级）──
    let views = Json.obj()
    viewsSet(views, "arch", sceneViewJson(arch))
    let panels = Json.obj()

    // 架构级 panel（每模块）。治理四键恒发（0 也发）——与 archJson 的 modules
    // 同一份事实、同一个口径（模块级 ArchEdge），场景消费方（客户端详情面板）
    // 不必再从 out/in 数组自己求和算第二份。
    for (m in sorted) {
        let po = Json.obj()
        Json.set(po, "title", Json.of(m.id))
        Json.set(po, "sub", Json.of("${ui.layerWord} L${m.layer} · ${layerName(m.layer, en)}"))
        Json.set(po, "stats", Json.of("${m.files} ${ui.filesWord} · ${m.symbols} ${ui.symWord} · ${m.lines} ${ui.lineWord}"))
        Json.set(po, "langs", Json.strArray(m.langs.toArray()))
        Json.set(po, "fanIn", Json.of(m.fanIn))
        Json.set(po, "fanOut", Json.of(m.fanOut))
        Json.set(po, "instability", Json.of(m.instability))
        Json.set(po, "layerName", Json.of(layerName(m.layer, en)))
        let o = ArrayList<JsonValue>()
        let i2 = ArrayList<JsonValue>()
        for (e in data.edges) {
            if (e.fromId == m.id) {
                let d = Json.obj()
                Json.set(d, "id", Json.of(e.toId))
                Json.set(d, "w", Json.of(e.weight))
                o.add(d)
            }
            if (e.toId == m.id) {
                let d = Json.obj()
                Json.set(d, "id", Json.of(e.fromId))
                Json.set(d, "w", Json.of(e.weight))
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
        // ⚠️ L8：装配原先对每条边线性扫 nodes（drillFind 是 O(N)），
        // 单视图最坏 O(E×N)——11000 条边 × 数百节点就是千万级比较。
        // buildDrilldown 手里本来就有 byId 这张 HashMap，只是没随 DrillGraph
        // 带出来。这里在装配处建一次，之后纯查表。
        let nodeIdx = HashMap<String, DrillNode>()
        for (n in dg.nodes) { nodeIdx[n.id] = n }
        let (dgEdges, dgDropped) = sceneEdges(dg.edges, SCENE_MAX_EDGES_PER_VIEW)
        v.dropped = dgDropped
        for ((a, b, w) in dgEdges) {
            match ((nodeIdx.get(a), nodeIdx.get(b))) {
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
            Json.set(e, "sw", Json.of(archEdgeStroke(w)))
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

        // 文件级 panel。out/in 与模块级**同构**，取自该模块的文件级边 ——
        // ⚠️ 原实现恒发空数组：键在、结构合法，却等于对驱动声称「这个文件没有任何依赖」。
        // 恒空假值比缺键更坏（驱动无从分辨「没依赖」与「引擎没填」）。
        // ⚠️ L8：out/in 的累积原来是「每个节点各扫一遍全表」= O(N×E)；
        // 改成只扫一遍边，按端点往 HashMap 里累加。输出顺序不变（入边/出边
        // 各自保持扫描序），所以契约不变，只是不再平方。
        let outsById = HashMap<String, ArrayList<JsonValue>>()
        let insById = HashMap<String, ArrayList<JsonValue>>()
        for ((ea, eb, ew) in dg.edges) {
            let d1 = Json.obj()
            Json.set(d1, "id", Json.of(eb))
            Json.set(d1, "w", Json.of(ew))
            match (outsById.get(ea)) {
                case Some(l) => l.add(d1)
                case None =>
                    let l = ArrayList<JsonValue>()
                    l.add(d1)
                    outsById[ea] = l
            }
            let d2 = Json.obj()
            Json.set(d2, "id", Json.of(ea))
            Json.set(d2, "w", Json.of(ew))
            match (insById.get(eb)) {
                case Some(l) => l.add(d2)
                case None =>
                    let l = ArrayList<JsonValue>()
                    l.add(d2)
                    insById[eb] = l
            }
        }
        for (n in dg.nodes) {
            if (n.external) { continue }
            let po = Json.obj()
            Json.set(po, "title", Json.of(n.label))
            Json.set(po, "sub", Json.of("${n.lang} · ${n.lines} ${ui.lineWord}"))
            Json.set(po, "stats", Json.of("${n.symbols} ${ui.symWord}"))
            let outs = match (outsById.get(n.id)) {
                case Some(l) => l
                case None => ArrayList<JsonValue>()
            }
            let ins = match (insById.get(n.id)) {
                case Some(l) => l
                case None => ArrayList<JsonValue>()
            }
            Json.set(po, "out", JArr(outs))
            Json.set(po, "in", JArr(ins))
            Json.set(panels, "${v.id}:${n.id}", po)
        }
    }

    // ── 装配 ──
    let chips = ArrayList<JsonValue>()
    var col: Int64 = 0
    while (col < LAYER_COUNT) {
        var count: Int64 = 0
        for (m in data.modules) { if (m.layer == col) { count += 1 } }
        if (count > 0) {
            let c = Json.obj()
            Json.set(c, "layer", Json.of(col))
            // ⚠️ M14：count 必须是**独立的数字字段**，原来只把它拼进 label。
            // 文档的 chips 契约写的是 {layer,label,count} —— 消费方要按数量
            // 排布/汇总时得从中文（或英文）文案里抠数字，那不是契约是猜。
            Json.set(c, "count", Json.of(count))
            Json.set(c, "label", Json.of("${layerName(col, en)} ${count}"))
            chips.add(c)
        }
        col += 1
    }
    let warnings = Json.obj()
    Json.set(warnings, "violations", Json.of(data.violationCount))
    Json.set(warnings, "cycleEdges", Json.of(data.cycleEdgeCount))
    let vps = ArrayList<JsonValue>()
    for (p in data.violationPairs) {
        let po = Json.obj()
        Json.set(po, "from", Json.of(p[0]))
        Json.set(po, "to", Json.of(p[1]))
        vps.add(po)
    }
    Json.set(warnings, "violationPairs", JArr(vps))
    Json.set(warnings, "cycleModules", Json.strArray(data.cycleModules.toArray()))
    let meta = Json.obj()
    Json.set(meta, "title", Json.of(ui.title))
    Json.set(meta, "warnings", warnings)
    // 恒发 truncated（false 也发）：「文件数达上限、部分扫描不是全量」是驱动
    // 必须能回答的事实。原先只有 archJson 出口有这个键，scene 连键都没有 ——
    // 数据在数据出口说了、在场景出口没说（数据显示=没算）。与 archJson 同名键
    // 同一事实（data.truncated 由 buildArch 从 graph.truncated 透传）。
    Json.set(meta, "truncated", Json.of(data.truncated))
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

/// 对象键按全序插入（M11 残留：HashMap 迭代序不可依赖，而 JObj 按插入序
/// 序列化——scene 的字节契约必须自定键序）。wrap 由调用方给定，各表值类型不同。
func setObjKeysSorted<T>(o: JsonValue, m: HashMap<String, T>, wrap: (T) -> JsonValue): Unit {
    let keys = ArrayList<String>()
    for ((k, _) in m) { keys.add(k) }
    insertionSortBy(keys, { a, b => a < b })
    for (k in keys) {
        match (m.get(k)) {
            case Some(v) => Json.set(o, k, wrap(v))
            case None => ()
        }
    }
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
    setObjKeysSorted(nt, v.nodeTheme, { x => Json.of(x) })
    Json.set(o, "nodeTheme", nt)
    let nl = Json.obj()
    setObjKeysSorted(nl, v.nodeLayer, { x => Json.of(x) })
    Json.set(o, "nodeLayer", nl)
    let od = Json.obj()
    setObjKeysSorted(od, v.order, { x => Json.of(x) })
    Json.set(o, "order", od)
    let lbl = Json.obj()
    setObjKeysSorted(lbl, v.labels, { x => Json.of(x) })
    Json.set(o, "labels", lbl)
    Json.set(o, "shapes", JArr(v.shapes))
    Json.set(o, "particles", JArr(v.particles))
    Json.set(o, "hits", JArr(v.hits))
    // 恒发：因上限未导出的边数（0 = 完整）—— 驱动可以据此提示「图不完整」
    Json.set(o, "edgesDropped", Json.of(v.dropped))
    return o
}

func viewsSet(views: JsonValue, key: String, v: JsonValue): Unit {
    Json.set(views, key, v)
}
