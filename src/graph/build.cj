// graph/build.cj — 图谱构建：目录遍历 → 事实提取 → 引用边 → 影响面。
//
// 【两遍扫描】第一遍只留「声明事实」（符号/导入/行数），
// 全局符号名集合建好之后第二遍重读文件数引用 —— 换取的是
// **内存与文件数解耦**：不在内存里存任何源码全文。
// 第二遍重读命中的是页缓存，代价可忽略。
//
// 【仓颉并发留白】逐文件的提取天然可 `spawn` 并行；v1 刻意串行 ——
// 确定性输出优先于吞吐（同一棵树两次构建必须逐字节一致，agent 才能对账）。
package moongit.graph

import std.collection.*
import std.convert.*
import moongit.util.*

// MARK: - 上限与跳过规则

public let GRAPH_MAX_FILES: Int64 = 4000
public let GRAPH_MAX_FILE_BYTES: Int64 = 512 * 1024
/// 单符号的影响面文件数上限（防御超大仓库的爆炸输出）
public let IMPACT_MAX_FILES: Int64 = 200

func buildSkipDirs(): HashSet<String> {
    let s = HashSet<String>()
    let names = [".git", ".build", ".idea", ".vscode", ".venv", "venv", "__pycache__",
        "node_modules", "target", "build", "dist", "out", "DerivedData",
        "Pods", "vendor", "coverage", ".next", ".gradle", ".output"]
    for (n in names) { s.add(n) }
    return s
}

let SKIP_DIRS: HashSet<String> = buildSkipDirs()

func skipDirName(name: String): Bool {
    return name.startsWith(".") || SKIP_DIRS.contains(name)
}

// MARK: - 遍历与构建

func walkSources(dir: String, rel: String, files: ArrayList<(String, String)>,
                 skippedRef: ReferVar): Unit {
    let (entries, _) = listDirChecked(dir)
    // 目录内先按名字排序：遍历顺序确定 ⇒ 输出顺序确定（agent 对账的前提）
    let names = ArrayList<String>()
    let dirs = ArrayList<String>()
    for (info in entries) {
        if (info.name.startsWith(".") || SKIP_DIRS.contains(info.name)) { continue }
        let full = if (rel.isEmpty()) { info.name } else { "${rel}/${info.name}" }
        if (isDirectoryPath("${dir}/${info.name}")) {
            dirs.add(full)
        } else {
            names.add(full)
        }
    }
    insertionSort(names)
    insertionSort(dirs)
    for (n in names) {
        if (files.size >= Int64(GRAPH_MAX_FILES)) {
            skippedRef.value += 1
            continue
        }
        files.add((dir, n))
    }
    for (d in dirs) {
        walkSources("${dir}/${lastSeg(d)}", d, files, skippedRef)
    }
}

func lastSeg(p: String): String {
    let segs = p.split("/")
    return segs[segs.size - 1]
}

/// 小规模插入排序（每层条目数有限；避免依赖不确定的泛型比较 API）
func insertionSort(list: ArrayList<String>): Unit {
    let n = Int64(list.size)
    var i: Int64 = 1
    while (i < n) {
        var j = i
        while (j > 0 && (list[j - 1] > list[j])) {
            let t = list[j - 1]
            list[j - 1] = list[j]
            list[j] = t
            j -= 1
        }
        i += 1
    }
}

/// 可变计数器（walk 递归里累积「跳过数」用；仓颉闭包捕获是值语义，
/// 用 struct 包一层才能跨递归累加）
public class ReferVar {
    public var value: Int64
    public init(v: Int64) { value = v }
}

/// 构建代码图谱。root 必须是已存在的目录。
public func buildGraph(root: String): CodeGraph {
    let files = ArrayList<(String, String)>()   // (绝对目录, 相对路径)
    let skipped = ReferVar(0)
    walkSources(root, "", files, skipped)

    // ── 第一遍：声明事实 ──
    let facts = ArrayList<FileEntry>()
    for ((absDir, rel) in files) {
        let lang = detectLang(rel)
        if (lang.isEmpty()) { continue }
        let content = readFileText("${absDir}/${lastSeg(rel)}")
        match (content) {
            case Some(text) =>
                if (Int64(text.toArray().size) > GRAPH_MAX_FILE_BYTES) {
                    continue   // 超大文件不是分析目标（生成物/打包产物）
                }
                let f = scanSource(text)
                facts.add(FileEntry(rel, lang, f.lineCount, f.symbols, f.imports))
            case None => ()   // 读不出 ≠ 有害；跳过且不计数（权限噪音不该污染统计）
        }
    }
    insertionSortBy(facts, { a, b => a.relPath < b.relPath })

    // ── 文件 → 模块索引 + 文件级 import 解析 ──
    let importEdges = ArrayList<(String, String)>()
    for (f in facts) {
        for (mod in f.imports) {
            // 解析：路径中含该模块段的另一个文件（首个命中，按排序序确定）
            for (g in facts) {
                if (g.relPath == f.relPath) { continue }
                if (pathContainsModule(g.relPath, mod)) {
                    importEdges.add((f.relPath, g.relPath))
                    break
                }
            }
        }
    }

    // ── 第二遍：词法引用边 ──
    // 全局符号名集合（一个名字可能多处定义 → 定义文件集合）
    let defFiles = HashMap<String, ArrayList<String>>()
    for (f in facts) {
        for (s in f.symbols) {
            match (defFiles.get(s.name)) {
                case Some(list) =>
                    if (!list.contains(f.relPath)) { list.add(f.relPath) }
                case None =>
                    let list = ArrayList<String>()
                    list.add(f.relPath)
                    defFiles[s.name] = list
            }
        }
    }
    // 引用计数：pair → 命中的不同符号名集合大小
    let pairNames = HashMap<String, HashSet<String>>()
    for (f in facts) {
        let content = readFileText("${root}/${f.relPath}")
        match (content) {
            case Some(text) =>
                for (line in text.split("\n")) {
                    let t = stripComment(line)
                    if (t.trimAscii().isEmpty()) { continue }
                    for (tok in tokenize(t)) {
                        match (defFiles.get(tok)) {
                            case Some(list) =>
                                for (defFile in list) {
                                    if (defFile == f.relPath) { continue }
                                    let key = "${f.relPath}|${defFile}"
                                    match (pairNames.get(key)) {
                                        case Some(set) =>
                                            set.add(tok)
                                        case None =>
                                            let set = HashSet<String>()
                                            set.add(tok)
                                            pairNames[key] = set
                                    }
                                }
                            case None => ()
                        }
                    }
                                }
            case None => ()
        }
    }
    let refEdges = ArrayList<(String, String, Int64)>()
    for ((key, set) in pairNames) {
        let segs = key.split("|")
        if (segs.size == 2) {
            refEdges.add((segs[0], segs[1], Int64(set.size)))
        }
    }

    return CodeGraph(root, facts, importEdges, refEdges,
                     files.size >= Int64(GRAPH_MAX_FILES), skipped.value)
}

/// relPath 里是否含名为 mod 的目录段（import 模块 → 文件的启发式解析）
func pathContainsModule(relPath: String, mod: String): Bool {
    if (mod.isEmpty()) { return false }
    for (seg in relPath.split("/")) {
        if (seg == mod) { return true }
    }
    // 顶层单文件名去扩展后命中也算（`import util` ↔ util.cj / util.swift）
    let name = lastSeg(relPath)
    match (name.lastIndexOf(".")) {
        case Some(dot) =>
            if (dot > 0) {
                let stem = name[0..dot]
                return stem == mod
            }
            return false
        case None => return false
    }
}

// 泛型插入排序（比较器是闭包；facts 规模有限，O(n²) 无碍）
func insertionSortBy<T>(list: ArrayList<T>, less: (T, T) -> Bool): Unit {
    let n = Int64(list.size)
    var i: Int64 = 1
    while (i < n) {
        var j = i
        while (j > 0 && less(list[j], list[j - 1])) {
            let t = list[j - 1]
            list[j - 1] = list[j]
            list[j] = t
            j -= 1
        }
        i += 1
    }
}

// MARK: - 影响面

/// 影响面：符号的定义处 + 引用它的文件（词法候选，如实标注粒度）。
public struct ImpactResult {
    public let name: String
    public let defs: ArrayList<(String, SymDecl)>
    public let refFiles: ArrayList<String>          // 引用文件（不含定义文件）
    public let impactedSymbols: ArrayList<(String, SymDecl)>  // 引用文件里声明的符号

    public init(name: String, defs: ArrayList<(String, SymDecl)>,
                refFiles: ArrayList<String>,
                impactedSymbols: ArrayList<(String, SymDecl)>) {
        this.name = name
        this.defs = defs
        this.refFiles = refFiles
        this.impactedSymbols = impactedSymbols
    }
}

public func impactOf(graph: CodeGraph, name: String): Option<ImpactResult> {
    let idx = graph.symbolIndex()
    match (idx.get(name)) {
        case Some(defs) =>
            let defSet = HashSet<String>()
            for ((f, _) in defs) { defSet.add(f) }
            let refFiles = ArrayList<String>()
            for ((from, to, _) in graph.refEdges) {
                if (defSet.contains(to) && !defSet.contains(from) && !refFiles.contains(from)) {
                    refFiles.add(from)
                    if (Int64(refFiles.size) >= IMPACT_MAX_FILES) { break }
                }
            }
            let impacted = ArrayList<(String, SymDecl)>()
            for (f in factsOf(graph)) {
                if (!refFiles.contains(f.relPath)) { continue }
                for (s in f.symbols) {
                    impacted.add((f.relPath, s))
                    if (Int64(impacted.size) >= IMPACT_MAX_FILES) { break }
                }
                if (Int64(impacted.size) >= IMPACT_MAX_FILES) { break }
            }
            return Some(ImpactResult(name, defs, refFiles, impacted))
        case None => return None
    }
}

func factsOf(graph: CodeGraph): ArrayList<FileEntry> {
    return graph.files
}
