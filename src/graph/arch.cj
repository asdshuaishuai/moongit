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

public class ArchData {
    public let modules: ArrayList<ArchModule>
    public let edges: ArrayList<(String, String, Int64)>   // fromModule, toModule, weight
    public let totalFiles: Int64
    public let totalSymbols: Int64
    public let totalLines: Int64
    public let truncated: Bool

    public init(modules: ArrayList<ArchModule>, edges: ArrayList<(String, String, Int64)>,
                totalFiles: Int64, totalSymbols: Int64, totalLines: Int64, truncated: Bool) {
        this.modules = modules
        this.edges = edges
        this.totalFiles = totalFiles
        this.totalSymbols = totalSymbols
        this.totalLines = totalLines
        this.truncated = truncated
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
    return ArchData(list, edges, totalFiles, totalSymbols, totalLines, graph.truncated)
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
    let o = Json.obj()
    Json.set(o, "modules", JArr(ms))
    Json.set(o, "edges", JArr(es))
    Json.set(o, "layers", JArr(layerList))
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
