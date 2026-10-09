// graph/render.cj — 图谱的四种人读/机读出口：概览 / 关系树 / 符号 / 影响面。
//
// 【agent 契约】--json 的键名是稳定契约（客户端与 MCP 宿主按名解码）；
// 文本路径是人看的，措辞可以迭代，键名不许漂。
package moongit.graph

import std.collection.*
import std.sort.*
import std.convert.*
import moongit.util.*

// MARK: - 概览

public func overviewJson(graph: CodeGraph): JsonValue {
    var symbols: Int64 = 0
    let byLang = HashMap<String, Int64>()
    let byKind = HashMap<String, Int64>()
    for (f in graph.files) {
        symbols += Int64(f.symbols.size)
        match (byLang.get(f.lang)) {
            case Some(v) => byLang[f.lang] = v + 1
            case None => byLang[f.lang] = 1
        }
        for (s in f.symbols) {
            let k = symKindId(s.kind)
            match (byKind.get(k)) {
                case Some(v) => byKind[k] = v + 1
                case None => byKind[k] = 1
            }
        }
    }
    // 符号密度 top5：agent 找「这个仓库的核在哪」先看这里
    let byFile = ArrayList<FileStat>()
    for (f in graph.files) {
        byFile.add(FileStat(f.relPath, Int64(f.symbols.size), f.lines))
    }
    insertionSortBy(byFile, { a, b => if (a.syms != b.syms) { a.syms > b.syms } else { a.path < b.path } })
    let top = ArrayList<JsonValue>()
    var ti = 0
    for (item in byFile) {
        if (ti >= 5 || item.syms == 0) { break }
        let d = Json.obj()
        Json.set(d, "path", Json.of(item.path))
        Json.set(d, "symbols", Json.of(item.syms))
        Json.set(d, "lines", Json.of(item.lines))
        top.add(d)
        ti += 1
    }
    let o = Json.obj()
    Json.set(o, "root", Json.of(graph.root))
    Json.set(o, "files", Json.of(Int64(graph.files.size)))
    Json.set(o, "symbols", Json.of(symbols))
    Json.set(o, "topFiles", JArr(top))
    Json.set(o, "imports", Json.of(Int64(graph.importEdges.size)))
    Json.set(o, "referenceEdges", Json.of(Int64(graph.refEdges.size)))
    Json.set(o, "truncated", Json.of(graph.truncated))
    Json.set(o, "skipped", Json.of(graph.skipped))
    // M7：超大文件跳过数**恒发**（0 也发）——「没有」与「没扫描」是两件事，
    // 缺键会让下游把后者读成前者。
    Json.set(o, "oversizeSkipped", Json.of(graph.oversizeSkipped))
    let langs = Json.obj()
    for ((k, v) in byLang) { Json.set(langs, k, Json.of(v)) }
    Json.set(o, "byLang", langs)
    let kinds = Json.obj()
    for ((k, v) in byKind) { Json.set(kinds, k, Json.of(v)) }
    Json.set(o, "byKind", kinds)
    return o
}

public func overviewText(graph: CodeGraph): String {
    let o = overviewJson(graph)
    let sb = StringBuilder()
    sb.append("代码图谱 · ${graph.root}\n")
    sb.append("  文件 ${Json.intAt(o, "files", 0)} · 符号 ${Json.intAt(o, "symbols", 0)} · import 边 ${Json.intAt(o, "imports", 0)} · 引用边 ${Json.intAt(o, "referenceEdges", 0)}\n")
    if (graph.truncated) {
        sb.append("  ⚠ 文件数达到上限 ${GRAPH_MAX_FILES}，以下统计只覆盖已扫描部分（不是全量）\n")
    }
    if (graph.skipped > 0) {
        sb.append("  ⚠ ${graph.skipped} 个文件因超限被跳过（不参与统计）\n")
    }
    if (graph.oversizeSkipped > 0) {
        sb.append("  ⚠ ${graph.oversizeSkipped} 个文件超过 ${GRAPH_MAX_FILE_BYTES} 字节上限未纳入（下列统计不含它们）\n")
    }
    // 按语言 / 按种类各一行
    let langs = Json.getOr(o, "byLang")
    let kinds = Json.getOr(o, "byKind")
    var langLine = ""
    var kindLine = ""
    func numText(v: JsonValue): String {
        match (v) {
            case JNum(n) => return "${Int64(n)}"
            case _ => return "?"
        }
    }
    match (langs) {
        case JObj(m) =>
            for ((k, v) in m) { langLine = langLine + "${k}:${numText(v)} " }
        case _ => ()
    }
    match (kinds) {
        case JObj(m) =>
            for ((k, v) in m) { kindLine = kindLine + "${k}:${numText(v)} " }
        case _ => ()
    }
    sb.append("  语言  ${langLine}\n")
    sb.append("  种类  ${kindLine}\n")
    let top = Json.arrAt(o, "topFiles")
    if (top.size > 0) {
        sb.append("  符号密度 Top：\n")
        for (d in top) {
            sb.append("    ${Json.intAt(d, "symbols", 0)} 符号/${Json.intAt(d, "lines", 0)} 行  ${Json.strAt(d, "path", "")}\n")
        }
    }
    sb.append("下一步：graph tree 看关系树 · graph arch 出架构图 · graph impact <符号> 看影响面\n")
    return sb.toString()
}

// MARK: - 全量图 JSON（graph tree --json）

/// 完整图谱的机读形态：文件事实 + 两类边。契约键名稳定。
///
/// `maxDepth <= 0` = 不截断（默认全量）。> 0 时只留**目录深度**不超过它的文件
/// （根目录下的文件深度 0，`a/b.cj` 深度 1，与 treeText 的目录层级语义一致）。
///
/// ⚠️ M16：MCP 的 codegraph_tree 与 CLI 的 `graph tree --json` 都声明了
/// `--depth`，而原先**解析完就把它丢掉**（fullGraphJson 根本没有这个参数）——
/// 模型传 depth=2 期待小图，实际拿到全量图，且 schema 明写「默认 6」。
/// 参数被接受而不生效，比没有这个参数更糟：调用方按它做了预算决策。
/// 现在截断照做了，并且**恒发** depth / depthOmitted 两个键（不变量 33：
/// 「没有截断」是一个有意义的事实，缺键会被读成旧版本没有这个字段）。
public func fullGraphJson(graph: CodeGraph, maxDepth: Int64): JsonValue {
    var depthOmitted: Int64 = 0
    let fs = ArrayList<JsonValue>()
    for (f in graph.files) {
        if (maxDepth > 0 && dirDepthOf(f.relPath) > maxDepth) {
            depthOmitted += 1
            continue
        }
        let o = Json.obj()
        Json.set(o, "path", Json.of(f.relPath))
        Json.set(o, "lang", Json.of(f.lang))
        Json.set(o, "lines", Json.of(f.lines))
        let syms = ArrayList<JsonValue>()
        for (s in f.symbols) {
            let d = Json.obj()
            Json.set(d, "kind", Json.of(symKindId(s.kind)))
            Json.set(d, "name", Json.of(s.name))
            Json.set(d, "line", Json.of(s.line))
            syms.add(d)
        }
        Json.set(o, "symbols", JArr(syms))
        fs.add(o)
    }
    let imps = ArrayList<JsonValue>()
    for ((a, b) in graph.importEdges) {
        let e = ArrayList<JsonValue>()
        e.add(Json.of(a))
        e.add(Json.of(b))
        imps.add(JArr(e))
    }
    let refs = ArrayList<JsonValue>()
    for ((a, b, w) in graph.refEdges) {
        let e = ArrayList<JsonValue>()
        e.add(Json.of(a))
        e.add(Json.of(b))
        e.add(Json.of(w))
        refs.add(JArr(e))
    }
    let o = Json.obj()
    Json.set(o, "root", Json.of(graph.root))
    Json.set(o, "files", JArr(fs))
    Json.set(o, "importEdges", JArr(imps))
    Json.set(o, "referenceEdges", JArr(refs))
    Json.set(o, "truncated", Json.of(graph.truncated))
    Json.set(o, "skipped", Json.of(graph.skipped))
    Json.set(o, "oversizeSkipped", Json.of(graph.oversizeSkipped))
    // depth 截断的两个轴（M16）：请求的深度 + 因它没进本次输出的文件数。
    Json.set(o, "depth", Json.of(maxDepth))
    Json.set(o, "depthOmitted", Json.of(depthOmitted))
    return o
}

/// 文件的目录深度：根目录下的文件 = 0，`a/b.cj` = 1，`a/b/c.cj` = 2。
/// 与 treeText 的目录层级同口径（那里根目录是深度 1，文件挂在目录下）。
public func dirDepthOf(relPath: String): Int64 {
    let segs = relPath.split("/")
    return Int64(segs.size) - 1
}

// MARK: - 关系树

/// 三元计数（文件/符号/行）。仓颉元组没有 `.0` 索引，具名字段即文档。
public struct Stat3 {
    public var files: Int64
    public var syms: Int64
    public var lines: Int64
    public init(f: Int64, s: Int64, l: Int64) { files = f; syms = s; lines = l }
}

/// 符号密度排序条目。
public struct FileStat {
    public let path: String
    public let syms: Int64
    public let lines: Int64
    public init(p: String, s: Int64, l: Int64) { path = p; syms = s; lines = l }
}

/// 子树聚合统计：dir 前缀 → (文件, 符号, 行)。目录行的汇总注记用。
func subtreeStats(graph: CodeGraph): HashMap<String, Stat3> {
    // ⚠️ 性能审查 §5.2：原来每层前缀都 relPath.toArray() + fromUtf8Lossy
    // （每文件 × 深度次数 × 一次整路径拷贝）。改为直接对 String 做字节切片——
    // acc 停在 '/' 边界上，切出的前缀天然是完整 UTF-8 序列（安全Slice 的前提）。
    let m = HashMap<String, Stat3>()
    for (file in graph.files) {
        let segs = file.relPath.split("/")
        var acc = 0
        var i = 0
        while (i < segs.size - 1) {
            acc = if (i == 0) { segs[i].size } else { acc + 1 + segs[i].size }
            let dir = file.relPath[0..acc]
            match (m.get(dir)) {
                case Some(old) => m[dir] = Stat3(old.files + 1, old.syms + Int64(file.symbols.size), old.lines + file.lines)
                case None => m[dir] = Stat3(1, Int64(file.symbols.size), file.lines)
            }
            i += 1
        }
    }
    return m
}

/// 目录树节点：一次构建，渲染免二次全量扫描。
class TreeDir {
    let name: String
    let full: String
    let children: ArrayList<TreeDir> = ArrayList<TreeDir>()
    let files: ArrayList<FileEntry> = ArrayList<FileEntry>()

    init(name: String, full: String) {
        this.name = name
        this.full = full
    }
}

/// 从文件列表一次构建目录树（O(F × 深度)）。
/// ⚠️ 性能审查 §2.1：原 renderDir 对**每个目录**都全量扫 graph.files 找自己的
/// 直接子项（O(D×F)；深树时 D 与 F 同阶 ⇒ 平方级）。
func buildTree(graph: CodeGraph): TreeDir {
    let root = TreeDir("", "")
    let dirs = HashMap<String, TreeDir>()
    dirs[""] = root
    for (f in graph.files) {
        let segs = f.relPath.split("/")
        var parent = root
        var acc = 0
        var i = 0
        while (i < segs.size - 1) {
            acc = if (i == 0) { segs[i].size } else { acc + 1 + segs[i].size }
            let full = f.relPath[0..acc]
            match (dirs.get(full)) {
                case Some(d) => parent = d
                case None =>
                    let d = TreeDir(segs[i], full)
                    parent.children.add(d)
                    dirs[full] = d
                    parent = d
            }
            i += 1
        }
        parent.files.add(f)
    }
    return root
}

func totalSymbols(graph: CodeGraph): Int64 {
    var n: Int64 = 0
    for (f in graph.files) { n += Int64(f.symbols.size) }
    return n
}

/// ASCII 关系树：目录 → 文件 → 符号；目录行带**子树汇总**，深度截断处披露。
public func treeText(graph: CodeGraph, maxDepth: Int64): String {
    let sb = StringBuilder()
    sb.append("${graph.root}  (${Int64(graph.files.size)} 文件 · ${totalSymbols(graph)} 符号 · ${sumLines(graph)} 行)\n")
    renderDir(graph, buildTree(graph), 1, maxDepth, "", subtreeStats(graph), sb)
    if (graph.truncated) {
        sb.append("⚠ 文件数达到上限 ${GRAPH_MAX_FILES}，以上不是全量\n")
    }
    return sb.toString()
}

func sumLines(graph: CodeGraph): Int64 {
    var n: Int64 = 0
    for (f in graph.files) { n += f.lines }
    return n
}

let TREE_PIPE = "│  "
let TREE_TEE = "├─ "
let TREE_LAST = "└─ "

/// 树条目 + 排序键。**键必须复刻旧实现**（目录 key = 名 + "/"，文件 key = 完整
/// relPath），否则输出序会变 —— 实测过：目录全在前 + 文件全在后是
/// **另一个序**（Package.swift ↔ scripts/ 的先后会翻转）。契约是「同一仓库
/// 两次构建逐字节一致」以及与旧版一致，保持原比较语义。
struct TreeItem2 {
    let key: String
    let dir: Option<TreeDir>
    let file: Option<FileEntry>

    init(key: String, dir: Option<TreeDir>, file: Option<FileEntry>) {
        this.key = key
        this.dir = dir
        this.file = file
    }
}

func renderDir(graph: CodeGraph, node: TreeDir, depth: Int64, maxDepth: Int64,
               prefix: String, stats: HashMap<String, Stat3>,
               sb: StringBuilder): Unit {
    let items = ArrayList<TreeItem2>()
    for (d in node.children) {
        items.add(TreeItem2(d.name + "/", Some(d), None))
    }
    for (f in node.files) {
        items.add(TreeItem2(f.relPath, None, Some(f)))
    }
    sort(items, by: { a, b => a.key.compare(b.key) })
    let n = Int64(items.size)
    var i: Int64 = 0
    for (item in items) {
        let connector = if (i == n - 1) { TREE_LAST } else { TREE_TEE }
        let childPrefix = if (i == n - 1) { prefix + "   " } else { prefix + TREE_PIPE }
        match ((item.dir, item.file)) {
            case (Some(d), _) =>
                var note = ""
                match (stats.get(d.full)) {
                    case Some(st) => note = "  (${st.files} 文件 · ${st.syms} 符号 · ${st.lines} 行)"
                    case None => ()
                }
                sb.append("${prefix}${connector}${d.name}/${note}\n")
                if (depth + 1 > maxDepth) {
                    sb.append("${childPrefix}   … 深度截断（提高 --depth 展开）\n")
                } else {
                    renderDir(graph, d, depth + 1, maxDepth, childPrefix, stats, sb)
                }
            case (_, Some(f)) =>
                sb.append("${prefix}${connector}${lastSeg(f.relPath)}  (${f.lang}, ${f.lines} 行, ${Int64(f.symbols.size)} 符号)\n")
                renderSymbols(f, childPrefix, sb)
            case _ => ()
        }
        i += 1
    }
}

func renderSymbols(f: FileEntry, prefix: String, sb: StringBuilder): Unit {
    let maxShow: Int64 = 12
    var i: Int64 = 0
    for (s in f.symbols) {
        if (i >= maxShow) {
            sb.append("${prefix}   … 共 ${Int64(f.symbols.size)} 个符号，其余略\n")
            break
        }
        sb.append("${prefix}   ${symKindId(s.kind)} ${s.name} (L${s.line})\n")
        i += 1
    }
}

// MARK: - 符号定位

public func symbolJson(graph: CodeGraph, name: String): JsonValue {
    let idx = graph.symbolIndex()
    let o = Json.obj()
    Json.set(o, "name", Json.of(name))
    match (idx.get(name)) {
        case Some(defs) =>
            let arr = ArrayList<JsonValue>()
            for ((f, s) in defs) {
                let d = Json.obj()
                Json.set(d, "file", Json.of(f))
                Json.set(d, "line", Json.of(s.line))
                Json.set(d, "kind", Json.of(symKindId(s.kind)))
                arr.add(d)
            }
            Json.set(o, "defs", JArr(arr))
            let refs = ArrayList<JsonValue>()
            for ((from, to, w) in graph.refEdges) {
                var isDef = false
                for ((f, _) in defs) { if (f == to) { isDef = true } }
                if (isDef) {
                    let r = Json.obj()
                    Json.set(r, "file", Json.of(from))
                    Json.set(r, "weight", Json.of(w))
                    refs.add(r)
                }
            }
            Json.set(o, "referencedBy", JArr(refs))
        case None => Json.set(o, "defs", Json.arr())
    }
    return o
}

public func symbolText(graph: CodeGraph, name: String): String {
    let o = symbolJson(graph, name)
    let defs = Json.arrAt(o, "defs")
    if (defs.size == 0) {
        return "未找到符号「${name}」（词法索引里没有这个名字；符号只覆盖支持的源码语言）"
    }
    let sb = StringBuilder()
    sb.append("符号 ${name} · ${defs.size} 处定义\n")
    for (d in defs) {
        sb.append("  ${Json.strAt(d, "file", "")}:${Json.intAt(d, "line", 0)}  (${Json.strAt(d, "kind", "")})\n")
    }
    let refs = Json.arrAt(o, "referencedBy")
    if (refs.size == 0) {
        sb.append("  引用：无（词法级；未被其它文件以同名标识符引用）\n")
    } else {
        sb.append("  引用（${refs.size} 个文件，按词法命中）：\n")
        for (r in refs) {
            sb.append("    ${Json.strAt(r, "file", "")}  ×${Json.intAt(r, "weight", 0)}\n")
        }
    }
    return sb.toString()
}

// MARK: - 影响面

public func impactJson(res: ImpactResult): JsonValue {
    let o = Json.obj()
    Json.set(o, "name", Json.of(res.name))
    let ds = ArrayList<JsonValue>()
    for ((f, s) in res.defs) {
        let d = Json.obj()
        Json.set(d, "file", Json.of(f))
        Json.set(d, "line", Json.of(s.line))
        Json.set(d, "kind", Json.of(symKindId(s.kind)))
        ds.add(d)
    }
    Json.set(o, "defs", JArr(ds))
    Json.set(o, "refFiles", Json.strArray(res.refFiles.toArray()))
    let im = ArrayList<JsonValue>()
    for ((f, s) in res.impactedSymbols) {
        let d = Json.obj()
        Json.set(d, "file", Json.of(f))
        Json.set(d, "symbol", Json.of(s.name))
        Json.set(d, "kind", Json.of(symKindId(s.kind)))
        im.add(d)
    }
    Json.set(o, "impactedSymbols", JArr(im))
    Json.set(o, "granularity", Json.of("lexical-file-level"))
    return o
}

public func impactText(res: ImpactResult): String {
    let sb = StringBuilder()
    sb.append("影响面 · ${res.name}\n")
    sb.append("  定义（${res.defs.size} 处）：\n")
    for ((f, s) in res.defs) {
        sb.append("    ${f}:${s.line}  (${symKindId(s.kind)})\n")
    }
    sb.append("  引用文件（${res.refFiles.size} 个，词法级候选——改这里会读到那里，不是编译器闭包）：\n")
    for (f in res.refFiles) {
        sb.append("    ${f}\n")
    }
    if (res.impactedSymbols.size > 0) {
        sb.append("  受影响符号（${res.impactedSymbols.size} 个，上限 ${IMPACT_MAX_FILES}）：\n")
        for ((f, s) in res.impactedSymbols) {
            sb.append("    ${symKindId(s.kind)} ${s.name}  ${f}\n")
        }
    }
    return sb.toString()
}
