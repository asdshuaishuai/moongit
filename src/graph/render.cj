// graph/render.cj — 图谱的四种人读/机读出口：概览 / 关系树 / 符号 / 影响面。
//
// 【agent 契约】--json 的键名是稳定契约（客户端与 MCP 宿主按名解码）；
// 文本路径是人看的，措辞可以迭代，键名不许漂。
package moongit.graph

import std.collection.*
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
    let o = Json.obj()
    Json.set(o, "root", Json.of(graph.root))
    Json.set(o, "files", Json.of(Int64(graph.files.size)))
    Json.set(o, "symbols", Json.of(symbols))
    Json.set(o, "imports", Json.of(Int64(graph.importEdges.size)))
    Json.set(o, "referenceEdges", Json.of(Int64(graph.refEdges.size)))
    Json.set(o, "truncated", Json.of(graph.truncated))
    Json.set(o, "skipped", Json.of(graph.skipped))
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
    sb.append("下一步：graph tree 看关系树 · graph arch 出架构图 · graph impact <符号> 看影响面\n")
    return sb.toString()
}

// MARK: - 全量图 JSON（graph tree --json）

/// 完整图谱的机读形态：文件事实 + 两类边。契约键名稳定。
public func fullGraphJson(graph: CodeGraph): JsonValue {
    let fs = ArrayList<JsonValue>()
    for (f in graph.files) {
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
    return o
}

// MARK: - 关系树

/// ASCII 关系树：目录 → 文件 → 符号。maxDepth 限制目录深度。
public func treeText(graph: CodeGraph, maxDepth: Int64): String {
    let sb = StringBuilder()
    sb.append("${graph.root}\n")
    renderDir(graph, "", 1, maxDepth, "", sb)
    return sb.toString()
}

let TREE_PIPE = "│  "
let TREE_TEE = "├─ "
let TREE_LAST = "└─ "

/// 树条目（目录 | 文件）。
enum TreeItem {
    | TDir(String, String)
    | TFile(FileEntry)
}

func renderDir(graph: CodeGraph, dir: String, depth: Int64, maxDepth: Int64,
               prefix: String, sb: StringBuilder): Unit {
    if (depth > maxDepth) { return }
    let relPrefix = if (dir.isEmpty()) { "" } else { dir + "/" }
    let items = ArrayList<TreeItem>()
    let seenDirs = ArrayList<String>()
    for (f in graph.files) {
        if (!f.relPath.startsWith(relPrefix)) { continue }
        let rest = if (dir.isEmpty()) { f.relPath } else { f.relPath[relPrefix.size..] }
        if (rest.contains("/")) {
            let seg = rest.split("/")[0]
            if (!seenDirs.contains(seg)) {
                seenDirs.add(seg)
                items.add(TDir(seg, if (dir.isEmpty()) { seg } else { relPrefix + seg }))
            }
        } else {
            items.add(TFile(f))
        }
    }
    insertionSortBy(items, { a, b => treeKey(a) < treeKey(b) })
    let n = Int64(items.size)
    var i: Int64 = 0
    for (item in items) {
        let connector = if (i == n - 1) { TREE_LAST } else { TREE_TEE }
        let childPrefix = if (i == n - 1) { prefix + "   " } else { prefix + TREE_PIPE }
        match (item) {
case TDir(name, full) =>
                                sb.append("${prefix}${connector}${name}/\n")
                                renderDir(graph, full, depth + 1, maxDepth, childPrefix, sb)
case TFile(f) =>
                                sb.append("${prefix}${connector}${lastSeg(f.relPath)}  (${f.lang}, ${f.lines} 行)\n")
                                renderSymbols(f, childPrefix, sb)
        }
        i += 1
    }
}

func treeKey(item: TreeItem): String {
    match (item) {
        case TDir(name, _) => return name + "/"
        case TFile(f) => return f.relPath
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
