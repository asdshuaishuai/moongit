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
    // ⚠️ M7：超大文件原来是 `continue` 且**不计数**，任何出口都看不出它被跳过了
    // （对比：文件数上限有 truncated + skipped 双字段并输出 ⚠，scene 边截断恒发
    // edgesDropped）。「看了但没留下痕迹」与「这里没有文件」在响应里同构 ——
    // 截断必须披露，否则语言分布/影响面都在一份未声明的残缺样本上说话。
    let oversize = ReferVar(0)
    for ((absDir, rel) in files) {
        let lang = detectLang(rel)
        if (lang.isEmpty()) { continue }
        let content = readFileText("${absDir}/${lastSeg(rel)}")
        match (content) {
            case Some(text) =>
                if (Int64(text.size) > GRAPH_MAX_FILE_BYTES) {
                    oversize.value += 1
                    continue
                }
                let f = scanSource(text, lang)
                facts.add(FileEntry(rel, lang, f.lineCount, f.symbols, f.imports, f.importLines))
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
    // 未解析调用：文件 → (函数名 → 首现行号)。构建后平坦化进 CodeGraph。
    let unresolvedCalls = HashMap<String, HashMap<String, Int64>>()
    let tokBuf = ArrayList<String>()
    let dotBuf = ArrayList<Bool>()
    let parenBuf = ArrayList<Bool>()
    // 名字 → 出现它的文件集合（幻觉调用的 FP 过滤：标准库函数被多文件调用）
    let nameFiles = HashMap<String, HashSet<String>>()
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
                // 未解析调用（幻觉 API）检测的逐文件缓存
                let seenUnresolved = HashSet<String>()
                // 每行 token 缓冲（复用容量；带前导点标志，供接收者调用豁免）
                let tokBuf = ArrayList<String>()
                let dotBuf = ArrayList<Bool>()
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
                    // ── 未解析调用（幻觉 API）：`name(` 形态的**自由函数调用**，
                    // 名字既不在全仓定义里，也不是语言内建/常见类型。接收者调用
                    // （a.b()）豁免——方法可能定义在别的仓库/库里。
                    // ⚠️ 位置感知扫描：tokenize 会丢掉括号，无法判断「后面是不是 (」。
                    tokBuf.clear()
                    dotBuf.clear()
                    parenBuf.clear()
                    let lb = line.toArray()
                    let ln2 = Int64(lb.size)
                    var i2: Int64 = 0
                    var prevDot = false
                    while (i2 < ln2) {
                        let b = lb[i2]
                        if (isIdentByte(b)) {
                            let st = i2
                            while (i2 < ln2 && isIdentByte(lb[i2])) { i2 += 1 }
                            tokBuf.add(fromUtf8Lossy(lb[st..i2]))
                            dotBuf.add(prevDot)
                            parenBuf.add(i2 < ln2 && lb[i2] == 40)   // '('
                            prevDot = false
                        } else {
                            prevDot = (b == 46)   // '.'
                            i2 += 1
                        }
                    }
                    var ti: Int64 = 0
                    while (ti < Int64(tokBuf.size)) {
                        let tok = tokBuf[ti]
                        let isCall = parenBuf[ti]
                        let prevDotTok = if (ti > 0) { dotBuf[ti - 1] } else { false }
                        if (isCall && !prevDotTok && !isBuiltinName(tok)
                            && defFiles.get(tok).isNone()) {
                            let ukey = f.relPath + "|" + tok
                            if (!seenUnresolved.contains(ukey)) {
                                seenUnresolved.add(ukey)
                                match (unresolvedCalls.get(f.relPath)) {
                                    case Some(inner) => inner[tok] = lineNo
                                    case None =>
                                        let inner = HashMap<String, Int64>()
                                        inner[tok] = lineNo
                                        unresolvedCalls[f.relPath] = inner
                                }
                            }
                        }
                        ti += 1
                    }

                    // 引用计数：同一文件里同一符号只计一次（复刻原 pairNames 的集合语义）
                    forEachToken(t) { tok =>
                        if (seen.contains(tok)) { return }
                        seen.add(tok)
                        match (nameFiles.get(tok)) {
                            case Some(fs) => fs.add(f.relPath)
                            case None =>
                                let fs = HashSet<String>()
                                fs.add(f.relPath)
                                nameFiles[tok] = fs
                        }
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

    // 物化处：**顺序由这里决定**，出口只是照抄（render/arch 都按本序列输出）。
    // 源码守卫 __lintRefEdgesMaterializationHasATotalOrder 钉住「这一处有排序」。
    let refEdges = ArrayList<(String, String, Int64)>()
    for ((from, inner) in refCount) {
        for ((to, count) in inner) {
            refEdges.add((from, to, count))
        }
    }
    // ⚠️ H3：refCount 是两层 HashMap，两层迭代都无序；而 render.cj 的
    // fullGraphJson 直接按本序列输出 referenceEdges，arch.cj 的 rawPairs /
    // violationPairs / mermaid / dot 也全部按它派生。物化处不定序 ⇒ 出口字节序
    // 跟着 HashMap 走，违反「同一仓库两次导出一致」这个 agent 对账前提
    // （AGENTS.md 不变量 126：任何 HashMap 迭代 + 排序都要问并列时按什么定序）。
    // scene 路径有 sceneEdgesArch、confidence 有 sortFindings，唯独这里没有。
    // 补齐到最后一位：from↑ → to↑ → count↑。
    insertionSortBy(refEdges, { a, b =>
        if (a[0] != b[0]) { return a[0] < b[0] }
        if (a[1] != b[1]) { return a[1] < b[1] }
        return a[2] < b[2]
    })

    // ── 未使用 import：import 解析到了 g，但 g 的任何符号都没在 f 出现过 ──
    // （行号来自 FileEntry.importLines，与 imports 平行）
    //
    // ⚠️ M6（引擎自食其果）：原判据是「f 是否引用了**解析出的那一个文件**」。
    // 仓颉/Swift 的 import 是**包级**语义（`import moongit.util` 引入整个 util
    // 模块），而 moduleIndex 按目录段取「排序序前两个」里的第一个 ⇒ import 到
    // util 的 build.cj 被拿去对账 util/errors.cj，真正用到的 readFileText
    // 在 util/paths.cj —— 于是「用了」被报成未使用。实测本仓库 10 条报告里
    // 至少 9 条是误报。粒度必须与 import 本身的粒度一致：**引用到同一模块的
    // 任一文件即视为已用**。
    // 「(文件 \u{1f} 模块) 在仓内解析得到目标」的集合（L4：一次建好，别按 import 逐条扫边）
    let importResolves = HashSet<String>()
    for ((from, to) in importEdges) {
        if (from == to) { continue }
        importResolves.add(from + "\u{1f}" + moduleOfPath(to))
    }
    let unusedImports = ArrayList<(String, String, Int64)>()
    for (f in facts) {
        var idx = 0
        for (mod in f.imports) {
            let impLine = if (idx < Int64(f.importLines.size)) { f.importLines[idx] } else { 1 }
            idx += 1
            // 同模块被引用即可（见上：包级 import 的判定也必须是包级）
            var used = false
            match (refCount.get(f.relPath)) {
                case Some(inner) =>
                    for ((to, _) in inner) {
                        if (to != f.relPath && moduleOfPath(to) == mod) { used = true }
                    }
                case None => ()
            }
            if (used) { continue }
            // 解析不到任何仓内目标 = 无法判定（外部依赖），不报；
            // 解析到而一个符号都没引用 = 真的没用这个模块
            //
            // L4：判定原先是「每个 (文件×import) × 扫全部 importEdges」
            // = O(F×I×E)。moduleIndex 的同类老问题早就建过一次索引治好了，
            // 这里照同一办法：一次建好「(文件, 模块) 能否解析」的集合，
            // 之后纯查表。语义不变 —— 仍然是「这个 import 在仓内有没有命中目标」。
            if (importResolves.contains(f.relPath + "\u{1f}" + mod)) {
                unusedImports.add((f.relPath, mod, impLine))
            }
        }
    }

    // unresolvedCalls 的嵌套 map → 平坦列表（file, name, firstLine）。
    // ⚠️ FP 过滤：名字在 ≥2 个文件出现 ⇒ 大概率是标准库/依赖的函数（多文件共用），
    // 不报；只在唯一文件出现的自由调用才报——那才是「幻觉 API」的形态。
    let unresolvedList = ArrayList<(String, String, Int64)>()
    for ((file, inner) in unresolvedCalls) {
        for ((name, ln) in inner) {
            match (nameFiles.get(name)) {
                case Some(fs) =>
                    if (Int64(fs.size) == 1) {
                        unresolvedList.add((file, name, ln))
                    }
                case None => ()
            }
        }
    }
    // ⚠️ M10：本列表的顺序决定 confidence_detect 的**每文件每类限流留下哪 6 条**，
    // 而它源自两层 HashMap 迭代 ⇒ 「报哪几条」由偶然顺序决定。AST 路径对同类
    // 限流做了顺序无关处理（sortAstNodes），词法路径必须补上同一件事。
    insertionSortBy(unresolvedList, { a, b =>
        if (a[0] != b[0]) { return a[0] < b[0] }
        if (a[1] != b[1]) { return a[1] < b[1] }
        return a[2] < b[2]
    })

    return CodeGraph(root, facts, importEdges, refEdges,
                     files.size >= Int64(GRAPH_MAX_FILES), skipped.value,
                     referencedNames, unresolvedList, unusedImports,
                     oversize.value)
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
