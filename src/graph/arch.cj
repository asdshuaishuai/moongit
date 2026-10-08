// graph/arch.cj — 技术架构图：模块聚合 + 分层判定 + 布局 + 四种渲染。
//
// 【参考了谁，没抄谁】
// pyreverse / madge / dependency-cruiser 的共同核心是
// 「目录/模块聚合依赖图 + 按语义分层」；archify（deepOrca 侧）验证了
// **单文件可交互 HTML** 是给人看的正确形态。我们没有照搬它的
// SVG + 手写布局，而是：
//   · 布局由引擎从事实**确定性计算**（分层列布局，同一仓库两次渲染逐像素一致）
//   · 渲染走 **Canvas 2D**（大量节点下平移/缩放比 SVG 重绘便宜得多）
//   · 零外部依赖：无字体 CDN、无 JS 库，双击离线可开
// agent 侧另有 mermaid / dot / json 三种静态出口（agent 点不了画布）。
//
// 【分层的诚实边界】层判定是**模块名的启发式**（util→基础、kernel→核心…），
// 不是依赖方向的拓扑论证。启发式判错的层不改变边的事实——
// 边才是事实，层是解读；两者在数据里分开存放。
package moongit.graph

import std.collection.*
import std.convert.*
import moongit.util.*

// MARK: - 分层

public let LAYER_COUNT: Int64 = 5

public func layerName(layer: Int64, en: Bool): String {
    if (en) {
        match (layer) {
            case 0 => "Foundation"
            case 1 => "Core"
            case 2 => "Orchestration"
            case 3 => "Interface"
            case _ => "Other"
        }
    } else {
        match (layer) {
            case 0 => "基础层"
            case 1 => "核心层"
            case 2 => "编排层"
            case 3 => "接口层"
            case _ => "其他"
        }
    }
}

/// 包装目录：其下的第二段才是真正的模块名
func isWrapperDir(seg: String): Bool {
    let s = lowerAscii(seg)
    let names = ["src", "sources", "source", "lib", "libs", "pkg", "classes"]
    for (n in names) { if (s == n) { return true } }
    return false
}

/// 模块名 → 层（启发式词表；命中不了的进「其他」，不猜）
public func inferLayer(module: String): Int64 {
    let m = lowerAscii(module)
    let l0 = ["util", "utils", "common", "commons", "base", "foundation", "shared", "lib", "helper", "helpers"]
    let l1 = ["kernel", "core", "domain", "model", "models", "store", "storage", "engine", "graph", "entity", "entities"]
    let l2 = ["flow", "service", "services", "agent", "agents", "logic", "manager", "managers", "orchestrator", "worker", "workers", "usecase", "usecases"]
    let l3 = ["cli", "app", "ui", "api", "server", "mcp", "client", "web", "view", "views", "controller", "controllers", "cmd", "gateway", "entry", "main"]
    for (w in l0) { if (m == w) { return 0 } }
    for (w in l1) { if (m == w) { return 1 } }
    for (w in l2) { if (m == w) { return 2 } }
    for (w in l3) { if (m == w) { return 3 } }
    return 4
}

// MARK: - 聚合

public class ArchModule {
    public let id: String          // 目录名（root 文件 = "(root)"）
    public let layer: Int64
    public var files: Int64 = 0
    public var symbols: Int64 = 0
    public var lines: Int64 = 0
    public var langs: ArrayList<String> = ArrayList<String>()
    // 布局（引擎算好，HTML 只负责画）
    public var x: Float64 = 0.0
    public var y: Float64 = 0.0
    public var w: Float64 = 0.0
    public var h: Float64 = 0.0

    public init(id: String, layer: Int64) {
        this.id = id
        this.layer = layer
    }
}

/// 下钻子图里的文件节点。外部模块以**单个虚拟节点**出现
/// （id 形如 "@module:util"）——跨模块依赖不消失，只降级成一个端口。
public struct DrillNode {
    public let id: String          // 文件 relPath，或 "@module:<模块名>"
    public let label: String       // 显示名（文件取 basename，外部取模块名）
    public let lang: String        // 虚拟节点 = "module"
    public let lines: Int64
    public let symbols: Int64
    public let external: Bool
    public var x: Float64 = 0.0
    public var y: Float64 = 0.0
    public var w: Float64 = 0.0
    public var h: Float64 = 0.0

    public init(id: String, label: String, lang: String, lines: Int64, symbols: Int64, external: Bool) {
        this.id = id
        this.label = label
        this.lang = lang
        this.lines = lines
        this.symbols = symbols
        this.external = external
    }
}

/// 一个模块的文件级子图。
public struct DrillGraph {
    public let moduleId: String
    public let nodes: ArrayList<DrillNode>
    public let edges: ArrayList<(String, String, Int64)>   // 文件(或虚拟) → 文件(或虚拟)

    public init(moduleId: String, nodes: ArrayList<DrillNode>, edges: ArrayList<(String, String, Int64)>) {
        this.moduleId = moduleId
        this.nodes = nodes
        this.edges = edges
    }
}

public class ArchData {
    public let modules: ArrayList<ArchModule>
    public let edges: ArrayList<(String, String, Int64)>   // fromModule, toModule, weight
    public let totalFiles: Int64
    public let totalSymbols: Int64
    public let totalLines: Int64
    public let truncated: Bool
    /// 每模块的文件级下钻子图（引擎算好布局，Canvas 只负责画）
    public let drilldown: ArrayList<DrillGraph>

    public init(modules: ArrayList<ArchModule>, edges: ArrayList<(String, String, Int64)>,
                totalFiles: Int64, totalSymbols: Int64, totalLines: Int64, truncated: Bool,
                drilldown: ArrayList<DrillGraph>) {
        this.modules = modules
        this.edges = edges
        this.totalFiles = totalFiles
        this.totalSymbols = totalSymbols
        this.totalLines = totalLines
        this.truncated = truncated
        this.drilldown = drilldown
    }
}

/// 模块 = 相对路径的首段目录（根文件聚成 "(root)"）。
/// 相对路径 → 模块名（buildArch 与边聚合**必须**共用这一个函数 ——
/// 各写各的，节点叫 util、边却聚到 src，图就变成一堆孤岛）。
public func moduleOfPath(relPath: String): String {
    let segs = relPath.split("/")
    if (segs.size >= 2) {
        if (isWrapperDir(segs[0]) && segs.size >= 3) { return segs[1] }
        return segs[0]
    }
    return "(root)"
}

public func buildArch(graph: CodeGraph): ArchData {
    let mods = HashMap<String, ArchModule>()
    func modOf(dir: String): ArchModule {
        match (mods.get(dir)) {
            case Some(m) => return m
            case None =>
                let m = ArchModule(dir, inferLayer(dir))
                mods[dir] = m
                return m
        }
    }
    for (f in graph.files) {
        let m = modOf(moduleOfPath(f.relPath))
        m.files += 1
        m.symbols += Int64(f.symbols.size)
        m.lines += f.lines
        if (!m.langs.contains(f.lang)) { m.langs.add(f.lang) }
    }
    // 边：文件级（import + reference）按模块对聚合求和
    let weight = HashMap<String, Int64>()
    func bump(a: String, b: String, w: Int64): Unit {
        let da = moduleOfPath(a)
        let db = moduleOfPath(b)
        if (da == db) { return }
        let key = "${da}|${db}"
        match (weight.get(key)) {
            case Some(v) => weight[key] = v + w
            case None => weight[key] = w
        }
    }
    for ((from, to) in graph.importEdges) { bump(from, to, 1) }
    for ((from, to, w) in graph.refEdges) { bump(from, to, w) }

    let edges = ArrayList<(String, String, Int64)>()
    for ((key, w) in weight) {
        let segs = key.split("|")
        if (segs.size == 2) { edges.add((segs[0], segs[1], w)) }
    }

    var totalFiles: Int64 = 0
    var totalSymbols: Int64 = 0
    var totalLines: Int64 = 0
    let list = ArrayList<ArchModule>()
    for ((_, m) in mods) { list.add(m) }
    insertionSortBy(list, { a, b => a.id < b.id })
    for (m in list) {
        totalFiles += m.files
        totalSymbols += m.symbols
        totalLines += m.lines
    }
    let drill = buildDrilldown(graph, list)
    return ArchData(list, edges, totalFiles, totalSymbols, totalLines, graph.truncated, drill)
}

// MARK: - 下钻子图（模块 → 文件级）

/// 为每个模块构建文件级子图：
///   节点 = 模块内文件 + 有依赖往来的外部模块（虚拟节点）
///   边   = 文件级 import/reference（跨模块的指向虚拟节点）
/// 布局：内部文件按目录聚类网格排列，外部虚拟节点靠右一列——确定性，可对账。
func buildDrilldown(graph: CodeGraph, modules: ArrayList<ArchModule>): ArrayList<DrillGraph> {
    let out = ArrayList<DrillGraph>()
    for (m in modules) {
        let nodes = ArrayList<DrillNode>()
        let byId = HashMap<String, DrillNode>()
        // 内部文件
        for (f in graph.files) {
            if (moduleOfPath(f.relPath) != m.id) { continue }
            let segs = f.relPath.split("/")
            let base = segs[segs.size - 1]
            let n = DrillNode(f.relPath, base, f.lang, f.lines, Int64(f.symbols.size), false)
            nodes.add(n)
            byId[f.relPath] = n
        }
        // 外部往来模块 → 虚拟节点
        let extMods = ArrayList<String>()
        for ((from, to, _) in graph.refEdges) {
            let fa = moduleOfPath(from)
            let fb = moduleOfPath(to)
            if (fa == m.id && fb != m.id && !extMods.contains(fb)) { extMods.add(fb) }
            if (fb == m.id && fa != m.id && !extMods.contains(fa)) { extMods.add(fa) }
        }
        for ((from, to) in graph.importEdges) {
            let fa = moduleOfPath(from)
            let fb = moduleOfPath(to)
            if (fa == m.id && fb != m.id && !extMods.contains(fb)) { extMods.add(fb) }
            if (fb == m.id && fa != m.id && !extMods.contains(fa)) { extMods.add(fa) }
        }
        insertionSortBy(extMods, { a, b => a < b })
        for (x in extMods) {
            let n = DrillNode("@module:${x}", x, "module", 0, 0, true)
            nodes.add(n)
            byId[n.id] = n
        }
        // 边：文件级，两端都在子图节点集里（跨模块的落在外部虚拟节点上）
        let edges = ArrayList<(String, String, Int64)>()
        for ((from, to, w) in graph.refEdges) {
            let fa = moduleOfPath(from)
            let fb = moduleOfPath(to)
            if (fa != m.id && fb != m.id) { continue }
            var a = from
            var b = to
            if (fa != m.id) { a = "@module:${fa}" }
            if (fb != m.id) { b = "@module:${fb}" }
            if (byId.get(a).isSome() && byId.get(b).isSome() && a != b) {
                edges.add((a, b, w))
            }
        }
        for ((from, to) in graph.importEdges) {
            let fa = moduleOfPath(from)
            let fb = moduleOfPath(to)
            if (fa != m.id && fb != m.id) { continue }
            var a = from
            var b = to
            if (fa != m.id) { a = "@module:${fa}" }
            if (fb != m.id) { b = "@module:${fb}" }
            if (byId.get(a).isSome() && byId.get(b).isSome() && a != b) {
                edges.add((a, b, 1))
            }
        }
        layoutDrill(nodes, m.id)
        out.add(DrillGraph(m.id, nodes, edges))
    }
    return out
}

/// 文件子图布局：目录聚类 → 列网格；外部虚拟节点靠右独立列。
/// 确定性：行/列序都来自排序后的 id。
func layoutDrill(nodes: ArrayList<DrillNode>, moduleId: String): Unit {
    let w: Float64 = 208.0
    let h: Float64 = 46.0
    let gx: Float64 = 26.0
    let gy: Float64 = 22.0
    let margin: Float64 = 56.0
    let internalNodes = ArrayList<DrillNode>()
    let externalNodes = ArrayList<DrillNode>()
    for (n in nodes) {
        if (n.external) { externalNodes.add(n) } else { internalNodes.add(n) }
    }
    insertionSortBy(internalNodes, { a, b => a.id < b.id })
    insertionSortBy(externalNodes, { a, b => a.id < b.id })
    // 网格 4 列（列数随规模自适应：≤8 个单列居中排）
    var cols: Int64 = 4
    if (Int64(internalNodes.size) <= 8) { cols = 2 }
    if (Int64(internalNodes.size) <= 3) { cols = 1 }
    var row: Float64 = 0.0
    var col: Int64 = 0
    // struct 是值类型：下标取出 → 改 → 写回
    var i: Int64 = 0
    while (i < Int64(internalNodes.size)) {
        var n = internalNodes[i]
        n.w = w
        n.h = h
        n.x = margin + Float64(col) * (w + gx)
        n.y = margin + row * (h + gy)
        internalNodes[i] = n
        col += 1
        if (col >= cols) {
            col = 0
            row += 1.0
        }
        i += 1
    }
    // 外部列：与内部区同顶部
    var extX = margin + Float64(cols) * (w + gx) + 60.0
    var ey: Float64 = margin
    i = 0
    while (i < Int64(externalNodes.size)) {
        var n = externalNodes[i]
        n.w = w
        n.h = h
        n.x = extX
        n.y = ey
        externalNodes[i] = n
        ey += h + gy
        i += 1
    }
    // 布局写回总表（nodes 里的元素同样按 id 回填）
    var k: Int64 = 0
    while (k < Int64(nodes.size)) {
        var n = nodes[k]
        match (byIdLike(internalNodes, n.id)) {
            case Some(fixed) => n = fixed
            case None => ()
        }
        match (byIdLike(externalNodes, n.id)) {
            case Some(fixed) => n = fixed
            case None => ()
        }
        nodes[k] = n
        k += 1
    }
}

func byIdLike(list: ArrayList<DrillNode>, id: String): Option<DrillNode> {
    var i: Int64 = 0
    while (i < Int64(list.size)) {
        if (list[i].id == id) { return Some(list[i]) }
        i += 1
    }
    return None
}

// MARK: - 布局（确定性：层为列，列内按模块名排）

public func layoutArch(data: ArchData): Unit {
    let nodeH: Float64 = 64.0
    let nodeWMin: Float64 = 132.0
    let colGap: Float64 = 110.0
    let rowGap: Float64 = 40.0
    let margin: Float64 = 64.0
    // 先按层收集并量好尺寸（确定性：列内按模块名排）
    var colMods = HashMap<Int64, ArrayList<ArchModule>>()
    var colW = HashMap<Int64, Float64>()
    var colH = HashMap<Int64, Float64>()
    var col = 0
    while (col < LAYER_COUNT) {
        let list = ArrayList<ArchModule>()
        for (m in data.modules) {
            if (m.layer == col) { list.add(m) }
        }
        insertionSortBy(list, { a, b => a.id < b.id })
        var maxW: Float64 = nodeWMin
        var h: Float64 = 0.0
        for (m in list) {
            let est = 44.0 + Float64(m.id.toArray().size) * 8.4
            m.w = if (est < nodeWMin) { nodeWMin } else { if (est > 264.0) { 264.0 } else { est } }
            m.h = nodeH
            if (m.w > maxW) { maxW = m.w }
            h += nodeH + rowGap
        }
        if (list.size > 0) { h -= rowGap }
        colMods[col] = list
        colW[col] = maxW
        colH[col] = h
        col += 1
    }
    // 全图统一内容高度 ⇒ 每列垂直居中；x 单遍顺序累加（列定位只此一处，不再二次平移）
    var maxH: Float64 = 0.0
    col = 0
    while (col < LAYER_COUNT) {
        match (colH.get(col)) {
            case Some(h) => if (h > maxH) { maxH = h }
            case None => ()
        }
        col += 1
    }
    var xCursor = margin
    col = 0
    while (col < LAYER_COUNT) {
        var list: ArrayList<ArchModule>
        match (colMods.get(col)) {
            case Some(l) => list = l
            case None => list = ArrayList<ArchModule>()
        }
        if (list.size == 0) {
            col += 1
            continue
        }
        var ch: Float64 = 0.0
        match (colH.get(col)) {
            case Some(h) => ch = h
            case None => ()
        }
        var y = margin + (maxH - ch) / 2.0
        for (m in list) {
            m.x = xCursor
            m.y = y
            y += nodeH + rowGap
        }
        var cw: Float64 = nodeWMin
        match (colW.get(col)) {
            case Some(w) => cw = w
            case None => ()
        }
        xCursor += cw + colGap
        col += 1
    }
}


// MARK: - JSON

public func archJson(data: ArchData, en: Bool): JsonValue {
    let layerList = ArrayList<JsonValue>()
    var i: Int64 = 0
    while (i < LAYER_COUNT) {
        var count: Int64 = 0
        for (m in data.modules) { if (m.layer == i) { count += 1 } }
        let l = Json.obj()
        Json.set(l, "index", Json.of(i))
        Json.set(l, "name", Json.of(layerName(i, en)))
        Json.set(l, "modules", Json.of(count))
        layerList.add(l)
        i += 1
    }
    let ms = ArrayList<JsonValue>()
    for (m in data.modules) {
        let o = Json.obj()
        Json.set(o, "id", Json.of(m.id))
        Json.set(o, "layer", Json.of(m.layer))
        Json.set(o, "files", Json.of(m.files))
        Json.set(o, "symbols", Json.of(m.symbols))
        Json.set(o, "lines", Json.of(m.lines))
        Json.set(o, "langs", Json.strArray(m.langs.toArray()))
        Json.set(o, "x", Json.of(m.x))
        Json.set(o, "y", Json.of(m.y))
        Json.set(o, "w", Json.of(m.w))
        Json.set(o, "h", Json.of(m.h))
        ms.add(o)
    }
    let es = ArrayList<JsonValue>()
    for ((a, b, w) in data.edges) {
        let o = Json.obj()
        Json.set(o, "from", Json.of(a))
        Json.set(o, "to", Json.of(b))
        Json.set(o, "weight", Json.of(w))
        es.add(o)
    }
    let dd = Json.obj()
    for (dg in data.drilldown) {
        let sub = Json.obj()
        let ns = ArrayList<JsonValue>()
        for (n in dg.nodes) {
            let no = Json.obj()
            Json.set(no, "id", Json.of(n.id))
            Json.set(no, "label", Json.of(n.label))
            Json.set(no, "lang", Json.of(n.lang))
            Json.set(no, "lines", Json.of(n.lines))
            Json.set(no, "symbols", Json.of(n.symbols))
            Json.set(no, "external", Json.of(n.external))
            Json.set(no, "x", Json.of(n.x))
            Json.set(no, "y", Json.of(n.y))
            Json.set(no, "w", Json.of(n.w))
            Json.set(no, "h", Json.of(n.h))
            ns.add(no)
        }
        Json.set(sub, "nodes", JArr(ns))
        let es2 = ArrayList<JsonValue>()
        for ((a, b, w) in dg.edges) {
            let eo = Json.obj()
            Json.set(eo, "from", Json.of(a))
            Json.set(eo, "to", Json.of(b))
            Json.set(eo, "weight", Json.of(w))
            es2.add(eo)
        }
        Json.set(sub, "edges", JArr(es2))
        Json.set(dd, dg.moduleId, sub)
    }
    let o = Json.obj()
    Json.set(o, "modules", JArr(ms))
    Json.set(o, "edges", JArr(es))
    Json.set(o, "layers", JArr(layerList))
    Json.set(o, "drilldown", dd)
    Json.set(o, "totalFiles", Json.of(data.totalFiles))
    Json.set(o, "totalSymbols", Json.of(data.totalSymbols))
    Json.set(o, "totalLines", Json.of(data.totalLines))
    Json.set(o, "truncated", Json.of(data.truncated))
    return o
}

// MARK: - Mermaid / DOT（agent 出口）

public func archMermaid(data: ArchData, en: Bool): String {
    let sb = StringBuilder()
    sb.append("flowchart LR\n")
    var i: Int64 = 0
    while (i < LAYER_COUNT) {
        let colMods = ArrayList<ArchModule>()
        for (m in data.modules) { if (m.layer == i) { colMods.add(m) } }
        insertionSortBy(colMods, { a, b => a.id < b.id })
        if (colMods.size > 0) {
            sb.append("  subgraph L${i}[\"${layerName(i, en)}\"]\n")
            for (m in colMods) {
                sb.append("    M${sanitizeId(m.id)}[\"${m.id} · ${m.files}f/${m.symbols}s\"]\n")
            }
            sb.append("  end\n")
        }
        i += 1
    }
    for ((a, b, w) in data.edges) {
        sb.append("  M${sanitizeId(a)} -->|${w}| M${sanitizeId(b)}\n")
    }
    return sb.toString()
}

public func archDot(data: ArchData, en: Bool): String {
    let sb = StringBuilder()
    sb.append("digraph architecture {\n  rankdir=LR;\n  node [shape=box, style=\"rounded,filled\", fillcolor=\"#eef2ff\", color=\"#6366f1\", fontname=\"Helvetica\"];\n")
    for (m in data.modules) {
        let label = "${m.id}\\n${m.files} files / ${m.symbols} symbols"
        sb.append("  \"${m.id}\" [label=\"${label}\", group=\"L${m.layer}\"];\n")
    }
    for ((a, b, w) in data.edges) {
        sb.append("  \"${a}\" -> \"${b}\" [label=\"${w}\", penwidth=${if (w > 8) { 3 } else { if (w > 3) { 2 } else { 1 } }}];\n")
    }
    sb.append("}\n")
    return sb.toString()
}

/// mermaid 节点 id 只收字母数字下划线
func sanitizeId(s: String): String {
    let out = ArrayList<UInt8>()
    for (b in s.toArray()) {
        if (isIdentByte(b)) { out.add(b) } else { out.add(95) }   // '_'
    }
    return fromUtf8Lossy(out.toArray())
}
