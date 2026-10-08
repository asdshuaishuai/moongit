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
import std.sort.*
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
        if (skipDirName(info.name)) { continue }
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
                if (Int64(text.size) > GRAPH_MAX_FILE_BYTES) {
                    continue   // 超大文件不是分析目标（生成物/打包产物）
                }
                let f = scanSource(text)
                facts.add(FileEntry(rel, lang, f.lineCount, f.symbols, f.imports))
            case None => ()   // 读不出 ≠ 有害；跳过且不计数（权限噪音不该污染统计）
        }
    }
    insertionSortBy(facts, { a, b => a.relPath < b.relPath })

    // ── 文件 → 模块索引 + 文件级 import 解析 ──
    // ⚠️ 性能审查 §2.1：原来是「每个 import × 扫描全部文件」的嵌套扫描
    // （F×I×F，1000 文件仓库是百万级路径包含判断，每次都要 split 路径）。
    // 改为一次建索引：每个目录段与文件名去扩展后作为键，值 = 排序序下前两个命中
    // ——「前两个」是为了复刻原「首个非自身命中」语义（首个恰是自己时取第二个）。
    let moduleIndex = HashMap<String, ArrayList<String>>()
    func indexKey(key: String, relPath: String): Unit {
        if (key.isEmpty()) { return }
        match (moduleIndex.get(key)) {
            case Some(list) =>
                if (list.size < 2) { list.add(relPath) }
            case None =>
                let list = ArrayList<String>()
                list.add(relPath)
                moduleIndex[key] = list
        }
    }
    for (g in facts) {
        for (seg in g.relPath.split("/")) { indexKey(seg, g.relPath) }
        let name = lastSeg(g.relPath)
        match (name.lastIndexOf(".")) {
            case Some(dot) => if (dot > 0) { indexKey(name[0..dot], g.relPath) }
            case None => ()
        }
    }
    let importEdges = ArrayList<(String, String)>()
    for (f in facts) {
        for (mod in f.imports) {
            match (moduleIndex.get(mod)) {
                case Some(list) =>
                    for (cand in list) {
                        if (cand != f.relPath) {
                            importEdges.add((f.relPath, cand))
                            break
                        }
                    }
                case None => ()
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
    // 引用计数：from 文件 → to 文件 → 命中的**不同**符号名个数。
    // 同时累积 referencedNames：**被当作标识符用过**（非声明位置）的符号名集合，
    // 供符号级孤儿检测使用（见 confidence_detect.detectOrphans）。
    //
    // ⚠️ 性能审查 §5.1/§6.1：原来每个 token 命中都拼一次 "from|to" 字符串 key
    // 再查全局 map（同行同 token 重复也重复拼）；tokenize 还逐行分配 ArrayList。
    // 现在：逐文件 token 去重（token → HashSet，文件切换即丢），
    // 计数用嵌套 map，字符串 key 只在外层文件对首次建立时出现。
    let refCount = HashMap<String, HashMap<String, Int64>>()
    let referencedNames = HashSet<String>()
    for (f in facts) {
        // 本文件各行的声明符号名（声明位置自身不算「使用」）
        let declAtLine = HashMap<Int64, HashSet<String>>()
        for (s in f.symbols) {
            match (declAtLine.get(s.line)) {
                case Some(ns) => ns.add(s.name)
                case None =>
                    let ns = HashSet<String>()
                    ns.add(s.name)
                    declAtLine[s.line] = ns
            }
        }
        let content = readFileText("${root}/${f.relPath}")
        match (content) {
            case Some(text) =>
                let seen = HashSet<String>()
                var strState: Int64 = 0
                var lineNo: Int64 = 0
                for (line in text.lazySplit("\n")) {
                    lineNo += 1
                    // 注释与字符串内的标识符都不算引用（与 scanSource 同一套）
                    let (t, nextState) = stripCode(line, strState)
                    strState = nextState
                    let lineDecls = declAtLine.get(lineNo)
                    // 符号级孤儿用：注释剥掉但**保留字符串** —— Cangjie/Swift 的
                    // `"${expr}"` 里嵌的是代码，stripCode 会把它们一并剥掉，导致
                    // 「只在插值里用到」的符号被误判孤儿（实测 sanitizeId / sumLines / numText）。
                    // 声明位置自身不算「使用」：否则「定义即使用」让孤儿永远检不出。
                    forEachToken(stripComment(line)) { tok =>
                        let isDecl = match (lineDecls) {
                            case Some(ns) => ns.contains(tok)
                            case None => false
                        }
                        if (!isDecl && defFiles.get(tok).isSome()) { referencedNames.add(tok) }
                    }
                    if (blankLine(t)) { continue }
                    // 引用计数：同一文件里同一符号只计一次（复刻原 pairNames 的集合语义）
                    forEachToken(t) { tok =>
                        if (seen.contains(tok)) { return }
                        seen.add(tok)
                        match (defFiles.get(tok)) {
                            case Some(list) =>
                                for (defFile in list) {
                                    if (defFile == f.relPath) { continue }
                                    match (refCount.get(f.relPath)) {
                                        case Some(inner) =>
                                            match (inner.get(defFile)) {
                                                case Some(v) => inner[defFile] = v + 1
                                                case None => inner[defFile] = 1
                                            }
                                        case None =>
                                            let inner = HashMap<String, Int64>()
                                            inner[defFile] = 1
                                            refCount[f.relPath] = inner
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
    for ((from, inner) in refCount) {
        for ((to, count) in inner) {
            refEdges.add((from, to, count))
        }
    }

    return CodeGraph(root, facts, importEdges, refEdges,
                     files.size >= Int64(GRAPH_MAX_FILES), skipped.value,
                     referencedNames)
}

// 泛型排序：**共享给全 graph 包**（render/arch 都在用）。
//
// ⚠️ 性能审查 §2.1：原实现是手写插入排序 O(n²) —— 对「每目录条目数有限」
// 的假设成立，但对整仓文件列表（320 文件是 5 万次比较，4000 文件是千万级）
// 不成立。仓颉标准库 std.sort.sort 是 O(n log n) 的稳定实现，直接换掉；
// 包内唯一的排序入口保留在这一个函数里，语义（less 闭包）不变。
func insertionSortBy<T>(list: ArrayList<T>, less: (T, T) -> Bool): Unit {
    sort(list, by: { a, b =>
        if (less(a, b)) {
            Ordering.LT
        } else if (less(b, a)) {
            Ordering.GT
        } else {
            Ordering.EQ
        }
    })
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
