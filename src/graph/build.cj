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
import std.fs.*
import std.sort.*
import moongit.util.*

// MARK: - 上限与跳过规则

public let GRAPH_MAX_FILES: Int64 = 4000
public let GRAPH_MAX_FILE_BYTES: Int64 = 512 * 1024
/// 单符号的影响面文件数上限（防御超大仓库的爆炸输出）
public let IMPACT_MAX_FILES: Int64 = 200
/// 读不出来的目录的收集上限（契约A：超出部分丢弃，出口侧用
/// unreadableDirsTruncated 恒发披露「还有更多」）
public let GRAPH_MAX_UNREADABLE_DIRS: Int64 = 200

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

// MARK: - 源状态探针（SourceProbe）

/// 源状态探针：index 新鲜度判定的唯一输入。
/// {files, bytes, maxMtime} = 文件数 / 总字节 / 最大 mtime（毫秒）。
///
/// 【文件集判据与构建扫描同源】skipDirName + detectLang（见 walkSources /
/// probeWalk 的注释）；不读内容、不解析。上限（GRAPH_MAX_FILES / 超大文件
/// 剔除）**不进探针**——探针描述的是源状态本身，构建采到多少是另一件事，
/// 混在一起会让「调整上限」伪装成「源变化」。
public struct SourceProbe {
    public let files: Int64
    public let bytes: Int64
    public let maxMtime: Int64

    public init(files: Int64, bytes: Int64, maxMtime: Int64) {
        this.files = files
        this.bytes = bytes
        this.maxMtime = maxMtime
    }

    /// 持久化形态（store_meta.source_probe / index payload 的 probe 键）：
    /// {"files":N,"bytes":N,"maxMtime":N}——键恒发，构造即全量。
    public func toJson(): JsonValue {
        let o = Json.obj()
        Json.set(o, "files", Json.of(files))
        Json.set(o, "bytes", Json.of(bytes))
        Json.set(o, "maxMtime", Json.of(maxMtime))
        return o
    }
}

/// 探针相等判据（纯函数）：三个分量全等才算「源未变」。
/// 比对是「宁重建不误跳过」的方向——任何一项不同都判过期。
public func probeMatches(a: SourceProbe, b: SourceProbe): Bool {
    return a.files == b.files && a.bytes == b.bytes && a.maxMtime == b.maxMtime
}

/// 从 payload 的 probe 值解析。缺任一键 / 畸形 → None——
/// 「读不出来」不许被当成「源没变」（同 #195 的第三态纪律）。
public func sourceProbeFromJson(v: JsonValue): Option<SourceProbe> {
    if (!Json.has(v, "files") || !Json.has(v, "bytes") || !Json.has(v, "maxMtime")) {
        return None
    }
    let f = Json.asInt(Json.getOr(v, "files"))
    let b = Json.asInt(Json.getOr(v, "bytes"))
    let m = Json.asInt(Json.getOr(v, "maxMtime"))
    match (f) {
        case Some(fv) =>
            match (b) {
                case Some(bv) =>
                    match (m) {
                        case Some(mv) => return Some(SourceProbe(fv, bv, mv))
                        case None => return None
                    }
                case None => return None
            }
        case None => return None
    }
}

/// 从 store_meta 的 TEXT 值解析（JSON 原文）。
public func sourceProbeFromText(s: String): Option<SourceProbe> {
    match (Json.parse(s)) {
        case Some(j) => return sourceProbeFromJson(j)
        case None => return None
    }
}

/// 条目 mtime 的毫秒值；读不出来返回 0。
/// 0 不是任何真实 mtime 的合法值（1970 年的源码不在本引擎的服务范围），
/// 它与 gen 时的任何值都不等 ⇒ 判「有变化」→ 重建 —— 读不出时往安全侧倒。
/// （不变量 50：lastModificationTime 是会抛的系统调用，不许裸调。）
func entryMtimeMillis(info: FileInfo): Int64 {
    try {
        return info.lastModificationTime.toUnixTimeStamp().toMilliseconds()
    } catch (e: Exception) {
        return 0
    }
}

/// walkSources / probeWalk 顺带采集的累加器。跨递归累加必须用引用类型
///（同 ReferVar 的存在理由：仓颉闭包/参数捕获是值语义）。
public class ProbeAcc {
    public var files: Int64 = 0
    public var bytes: Int64 = 0
    public var maxMtime: Int64 = 0

    public init() {}

    /// 计入一个文件条目（size 走 lstat，断链也拿得到；mtime 读不出按 0）。
    public func observe(info: FileInfo): Unit {
        files += 1
        let sz = entrySize(info)
        if (sz > 0) {
            bytes += sz
        }
        let mt = entryMtimeMillis(info)
        if (mt > maxMtime) {
            maxMtime = mt
        }
    }

    public func snapshot(): SourceProbe {
        return SourceProbe(files, bytes, maxMtime)
    }
}

/// 轻探针：只 stat 的快速行走（毫秒级），**不读内容、不解析**——
/// update / overview / query / render 在动真格重建之前的新鲜度比对全靠它快。
/// 判据与构建扫描同源：skipDirName + detectLang + listDirChecked
///（读不到的目录这次就看不到 ⇒ 探针分量变化 ⇒ 判过期重建，安全侧）。
public func sourceProbeNow(root: String): SourceProbe {
    let acc = ProbeAcc()
    probeWalk(root, "", acc)
    return acc.snapshot()
}

func probeWalk(dir: String, rel: String, acc: ProbeAcc): Unit {
    let (entries, readable) = listDirChecked(dir)
    if (!readable) {
        return
    }
    let dirs = ArrayList<String>()
    for (info in entries) {
        if (skipDirName(info.name)) { continue }
        let full = if (rel.isEmpty()) { info.name } else { "${rel}/${info.name}" }
        // 目录判定走 classifyEntry（info 已在手，不多花 stat）；
        // 非目录（含读不出/其他）一律按文件候选处理——与 walkSources 的
        // isDirectoryPath 判定同口径：isDirectory 读不出时也走文件分支。
        var isDir = false
        match (classifyEntry(info)) {
            case EntryKind.Dir => isDir = true
            case _ => ()
        }
        if (isDir) {
            dirs.add(full)
        } else if (!detectLang(full).isEmpty()) {
            acc.observe(info)
        }
    }
    insertionSort(dirs)
    for (d in dirs) {
        probeWalk("${dir}/${lastSeg(d)}", d, acc)
    }
}

// MARK: - 遍历与构建

// ⚠️ 探针采集与构建共用同一遍历：probe 参数是「顺带采集」的累加器，
// 判据（skipDirName + detectLang）与文件集完全同源——独立第二份行走
// 迟早和构建扫描各说各话，那正是 index update「已最新」谎报的形状。
// 只想要探针（不建图）的轻路径见 sourceProbeNow：它复用同一对判定函数，
// 但必须保持只 stat（毫秒级），不许在这里读文件内容。
func walkSources(dir: String, rel: String, files: ArrayList<(String, String)>,
                 skippedRef: ReferVar, unreadableDirs: ArrayList<String>,
                 probe: ProbeAcc): Unit {
    let (entries, readable) = listDirChecked(dir)
    // ⚠️ G6（#179 同族）：读不出来的目录原先被丢弃 readable 标志后与
    // 空目录完全同构——「看不到」被编码成「没有」，其下所有文件静默
    // 缺席且零披露（root 读不到时产物是全清空图谱）。收集相对路径
    // （与 relPath 同口径；root 为空串），上限 GRAPH_MAX_UNREADABLE_DIRS。
    if (!readable) {
        if (Int64(unreadableDirs.size) < GRAPH_MAX_UNREADABLE_DIRS) {
            unreadableDirs.add(rel)
        }
        return
    }
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
            // 探针顺带采集：文件集判据 = skip + 语言识别（与构建扫描一致；
            // 不受 GRAPH_MAX_FILES 上限影响——探针描述的是源状态，
            // 不是「构建采到了多少」，上限变了不该伪装成源变了）
            if (!detectLang(full).isEmpty()) {
                probe.observe(info)
            }
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
        walkSources("${dir}/${lastSeg(d)}", d, files, skippedRef, unreadableDirs, probe)
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

// MARK: - 架构口径（archRefEdges）的声明侧

/// 架构口径的「公开符号」判据：跨模块引用在语言语义上只能指向导出符号
/// （archRefEdges 判据①）。cangjie/swift/ts/rust/java/kotlin：声明行带
/// public/open/export/pub 关键词；go：标识符首字母大写（Go 的导出规则就是
/// 大小写本身）；python：无关键词机制，按社区约定非下划线前缀即公开。
/// C 系没有可见性关键词，头文件声明形态判据超出词法范围 —— 保守缺边
/// （漏边不是假边，架构口径宁缺勿滥；kotlin 默认公开的规则同理暂未接）。
func archExportLike(lang: String, toks: ArrayList<String>, name: String): Bool {
    if (lang == "go") {
        let bs = name.toArray()
        return bs.size > 0 && bs[0] >= 65 && bs[0] <= 90
    }
    if (lang == "python") {
        let bs = name.toArray()
        return bs.size > 0 && bs[0] != 95   // '_' 前缀约定为私有
    }
    for (t in toks) {
        if (t == "public" || t == "open" || t == "export" || t == "pub") { return true }
    }
    return false
}

/// 声明行里紧跟声明名后的 `<...>` 内的标识符 = 泛型类型参数（archRefEdges
/// 判据④：声明不是引用）。`func withLock<T>(body: () -> T): T` 收 {T}——
/// 豁免按「行 + 名字」生效，该行所有 T（含 `-> T` / `: T` 位置的）一并豁免：
/// 单字母参数名与同名类型实参在声明行上不可能是两种语义。
func genericParamsOf(name: String, stripped: String): HashSet<String> {
    let out = HashSet<String>()
    // 「name 后跳空白紧跟 '<'」才认；findSubstr 取第一次出现 —— 声明行上
    // 声明名的首次出现就是声明处。
    let idx = findSubstr(stripped, name)
    if (idx.isNone()) { return out }
    let sb = stripped.toArray()
    let n = Int64(sb.size)
    var k = idx.getOrThrow() + Int64(name.size)
    while (k < n && (sb[k] == 32 || sb[k] == 9)) { k += 1 }
    if (k >= n || sb[k] != 60) { return out }   // '<'
    var depth: Int64 = 0
    var cur = ArrayList<UInt8>()
    while (k < n) {
        let b = sb[k]
        if (b == 60) { depth += 1; k += 1; continue }
        if (b == 62) {
            depth -= 1
            if (depth <= 0) { break }
            k += 1
            continue
        }
        if (isIdentByte(b)) {
            cur.add(b)
        } else if (cur.size > 0) {
            out.add(fromUtf8Lossy(cur.toArray()))
            cur = ArrayList<UInt8>()
        }
        k += 1
    }
    if (cur.size > 0) { out.add(fromUtf8Lossy(cur.toArray())) }
    return out
}

/// 架构口径（archRefEdges）的声明侧收集：从同一次读到的源码文本里找
/// 「顶格且公开」的顶层声明（= 跨模块可达符号集，进 archDefFiles）、
/// 声明行的泛型参数名（进 genericAtLine），以及「剥后仍在」的 import 行号
/// （进 archImportLines——scanSource 的 import 检测用原始行，字符串里的
/// `from x import y` 会被当成真 import 拖进 importEdges；行首处于字符串/
/// 块注释态的行不收。特例：`#include` 被 stripCode 的 `#` 注释词头剥空，
/// 但它是 C 的 import 形态，按原始行词头收）。
/// 顶格判定看原始行首字节——缩进的成员方法不可能以自由标识符形态被
/// 跨包调用（util 撞 kernel 的 `func size()` 这类假边在这里被挡掉）。
func collectArchDecls(relPath: String, lang: String, text: String,
                      archDefFiles: HashMap<String, ArrayList<String>>,
                      genericAtLine: HashMap<String, HashMap<Int64, HashSet<String>>>,
                      archImportLines: HashMap<String, HashSet<Int64>>): Unit {
    var ln: Int64 = 0
    var st: Int64 = 0
    for (raw in text.lazySplit("\n")) {
        ln += 1
        let stIn = st
        let (ct, nst) = stripCode(raw, st)
        st = nst
        // ── import 行收集（剥后口径）——词头与 extract.scanImportLine 一致 ──
        if (stIn == 0) {
            let trimmed = ct.trimAscii()
            var isImportLine = trimmed.startsWith("import ") || trimmed.startsWith("from ")
                || trimmed.startsWith("use ") || trimmed.startsWith("#include")
            if (!isImportLine && blankLine(ct)) {
                // 剥空但原始行以 #include 开头：# 是 stripCode 的注释词头，
                // C 预处理行被误剥——不是字符串泄漏，按 import 收
                let rawTrim = raw.trimAscii()
                if (rawTrim.startsWith("#include")) { isImportLine = true }
            }
            if (isImportLine) {
                match (archImportLines.get(relPath)) {
                    case Some(lines) => lines.add(ln)
                    case None =>
                        let lines = HashSet<Int64>()
                        lines.add(ln)
                        archImportLines[relPath] = lines
                }
            }
        }
        if (blankLine(ct)) { continue }
        if (raw.size == 0) { continue }
        let b0 = raw[0]
        if (b0 == 32 || b0 == 9) { continue }   // 缩进行 = 成员/嵌套声明，不是顶层
        // go 带接收者的方法声明必须先于 scanDeclLine 特判（G1 同款）：否则
        // 接收者变量名被当成符号名收进集合（Area 被漏、r 被收）。
        if (lang == "go") {
            match (goReceiverMethodName(ct)) {
                case Some(name) =>
                    if (archExportLike(lang, tokenize(ct), name)) {
                        archDefAdd(archDefFiles, name, relPath)
                    }
                    continue
                case None => ()
            }
        }
        // 声明关键词前置过滤：绝大多数顶格代码行（赋值/调用/闭包）免 tokenize
        if (!mayDeclare(ct)) { continue }
        let toks = tokenize(ct)
        match (scanDeclLine(toks)) {
            case Some((_, name)) =>
                if (archExportLike(lang, toks, name)) {
                    archDefAdd(archDefFiles, name, relPath)
                }
                let gens = genericParamsOf(name, ct)
                if (gens.size > 0) {
                    match (genericAtLine.get(relPath)) {
                        case Some(m) => m[ln] = gens
                        case None =>
                            let m = HashMap<Int64, HashSet<String>>()
                            m[ln] = gens
                            genericAtLine[relPath] = m
                    }
                }
            case None => ()
        }
    }
}

func archDefAdd(archDefFiles: HashMap<String, ArrayList<String>>,
                name: String, relPath: String): Unit {
    match (archDefFiles.get(name)) {
        case Some(list) =>
            if (!list.contains(relPath)) { list.add(relPath) }
        case None =>
            let list = ArrayList<String>()
            list.add(relPath)
            archDefFiles[name] = list
    }
}

/// 构建代码图谱（带探针版）：walkSources 同一次行走顺带采集源状态探针，
/// 返回 (图谱, 探针)。index gen 用它——探针与图谱来自**同一次扫描**，
/// 不存在「图是 10:00 的、探针是 10:01 的」这种自相矛盾的快照。
public func buildGraphProbed(root: String): (CodeGraph, SourceProbe) {
    let files = ArrayList<(String, String)>()   // (绝对目录, 相对路径)
    let skipped = ReferVar(0)
    let unreadableDirs = ArrayList<String>()
    let probeAcc = ProbeAcc()
    walkSources(root, "", files, skipped, unreadableDirs, probeAcc)

    // ── 第一遍：声明事实 ──
    let facts = ArrayList<FileEntry>()
    // 架构口径（archRefEdges）的声明侧容器：跨模块可达符号集（名字 → 定义文件）
    // 与各文件声明行的泛型参数名（文件 → 行号 → 参数名集）。判据语义见
    // model.cj 的 archRefEdges 字段注释；收集在第一遍循环内完成（text 在手）。
    let archDefFiles = HashMap<String, ArrayList<String>>()
    let genericAtLine = HashMap<String, HashMap<Int64, HashSet<String>>>()
    // 各文件「剥后仍在」的 import 行号（相对根的文件路径 → 行号集）——
    // 过滤 scanSource 原始行检测混进 importEdges 的字符串假 import
    let archImportLines = HashMap<String, HashSet<Int64>>()
    // ⚠️ M7：超大文件原来是 `continue` 且**不计数**，任何出口都看不出它被跳过了
    // （对比：文件数上限有 truncated + skipped 双字段并输出 ⚠，scene 边截断
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
                // 架构口径的声明侧收集（archRefEdges 判据①④，语义见 model.cj
                // 的字段注释）：顶格公开的顶层声明 = 跨模块可达符号集；声明行的
                // 泛型参数名 = 声明不是引用；剥后仍在的 import 行号。用同一次
                // 读到的 text，不重读文件。
                collectArchDecls(rel, lang, text, archDefFiles, genericAtLine,
                                 archImportLines)
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
        var impIdx = 0
        for (mod in f.imports) {
            // ⚠️ 字符串里的 import 不是 import：scanSource 的 import 检测用
            // 原始行（行锚定，extract.cj 的设计取舍），不看字符串状态——
            // 夹具/示例字符串里的 `from x import y` 会被当成真 import 拖进
            // importEdges 并在架构图上捏造模块依赖（引擎自身 graph→flow 的
            // 残留违规正源于此）。行号不在「剥后仍在」集合里的一律丢弃。
            let impLine = if (impIdx < Int64(f.importLines.size)) { f.importLines[impIdx] } else { 1 }
            impIdx += 1
            var keepImport = false
            match (archImportLines.get(f.relPath)) {
                case Some(lines) => keepImport = lines.contains(impLine)
                case None => keepImport = false
            }
            if (!keepImport) { continue }
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
    // 架构口径的引用计数（与 refCount 同构：from 文件 → to 文件 → 命中的
    // 不同符号名个数）。判据见 model.cj 的 archRefEdges 字段注释。
    let archRefCount = HashMap<String, HashMap<String, Int64>>()
    // 名字 → 定义模块集合（判据②跨模块歧义剔除用；从 archDefFiles 一次折叠，
    // 第二遍纯查表，不在逐 token 循环里反复算模块）
    let archDefMods = HashMap<String, HashSet<String>>()
    for ((name, list) in archDefFiles) {
        let ms = HashSet<String>()
        for (p in list) { ms.add(moduleOfPath(p)) }
        archDefMods[name] = ms
    }
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
                // 架构口径的逐文件缓存：已计边符号（同 refCount 的 seen 语义：
                // 每 (文件, 符号) 只计一次）+ 本文件的泛型参数行表
                let archSeen = HashSet<String>()
                let lineGen = genericAtLine.get(f.relPath)
                // 未解析调用（幻觉 API）检测的逐文件缓存
                let seenUnresolved = HashSet<String>()
                // 每行 token 缓冲（复用容量；带前导点标志，供接收者调用豁免；
                // 带前导 < 标志，供泛型实参豁免——archRef 判据⑤）
                let tokBuf = ArrayList<String>()
                let dotBuf = ArrayList<Bool>()
                let ltBuf = ArrayList<Bool>()
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
                    // 名字既不在全仓定义里，也不是语言内建/常见类型、不是语言
                    // 关键词（KEYWORDS 表——`if(x)` / `for(` / `while(` 是控制流
                    // 不是调用）。接收者调用（a.b()）豁免——方法可能定义在别的
                    // 仓库/库里。
                    // ⚠️ 位置感知扫描：tokenize 会丢掉括号，无法判断「后面是不是 (」。
                    // ⚠️ G2：扫描对象必须是**剥过注释/字符串**的 t（跨行状态由
                    // 上面的 strState 携带）——原实现扫原始行，与本循环开头那句
                    // 「注释与字符串内的标识符都不算引用」相反：注释里的 `call(`
                    // 与字符串里的 `call(` 都被指控为幻觉 API。
                    tokBuf.clear()
                    dotBuf.clear()
                    ltBuf.clear()
                    parenBuf.clear()
                    let lb = t.toArray()
                    let ln2 = Int64(lb.size)
                    var i2: Int64 = 0
                    var prevDot = false
                    var prevLt = false
                    while (i2 < ln2) {
                        let b = lb[i2]
                        if (isIdentByte(b)) {
                            let st = i2
                            while (i2 < ln2 && isIdentByte(lb[i2])) { i2 += 1 }
                            tokBuf.add(fromUtf8Lossy(lb[st..i2]))
                            dotBuf.add(prevDot)
                            ltBuf.add(prevLt)
                            parenBuf.add(i2 < ln2 && lb[i2] == 40)   // '('
                            prevDot = false
                            prevLt = false
                        } else {
                            prevDot = (b == 46)   // '.'
                            prevLt = (b == 60)   // '<'
                            i2 += 1
                        }
                    }
                    var ti: Int64 = 0
                    while (ti < Int64(tokBuf.size)) {
                        let tok = tokBuf[ti]
                        let isCall = parenBuf[ti]
                        let prevDotTok = if (ti > 0) { dotBuf[ti - 1] } else { false }
                        if (isCall && !prevDotTok && !isBuiltinName(tok)
                            && !KEYWORDS.contains(tok)
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

                    // ── 架构口径引用边（archRefEdges，判据见 model.cj 字段注释）──
                    // 复用本行 tokBuf/dotBuf/ltBuf 的 token 流（与未解析调用
                    // 同源同序），不再跑一遍字节扫描。每 (文件, 符号) 只计一次。
                    var ai: Int64 = 0
                    while (ai < Int64(tokBuf.size)) {
                        let tok = tokBuf[ai]
                        if (!archSeen.contains(tok)) {
                            // 判据③：接收者调用（a.b）豁免——方法归属要类型信息。
                            // 判据⑤：泛型实参位置（Option<T> / wrapFn<Int64> 的
                            // < 前导）豁免——类型实参的归属同样要类型信息；比较
                            // 运算符 `a < b` 的 b 右侧是变量/字面量，误豁免的代价
                            // 是漏边不是假边。
                            // ⚠️ 下标必须是 **ai 自己**：dotBuf/ltBuf 与 tokBuf
                            // 平行填充，dotBuf[ai] 是当前 token 的前导标志。
                            // 曾误写 ai-1（那是前一个 token 的标志）——Option<T>
                            // 的 T 前一个 token 是 Option（前导 :），判据⑤就此
                            // 整体失效，lock.cj 的 `var result: Option<T> = None`
                            // 残留 kernel→cli 假边（迷你仓二分实证）。
                            let prevDotTok = dotBuf[ai]
                            let prevLtTok = ltBuf[ai]
                            var skip = prevDotTok || prevLtTok
                            // 判据④：本行的泛型类型参数是声明不是引用
                            if (!skip) {
                                match (lineGen) {
                                    case Some(m) =>
                                        match (m.get(lineNo)) {
                                            case Some(gs) => skip = gs.contains(tok)
                                            case None => ()
                                        }
                                    case None => ()
                                }
                            }
                            if (!skip) {
                                match (archDefFiles.get(tok)) {
                                    case Some(list) =>
                                        // 判据②：定义分布在 >1 个模块的同名符号 =
                                        // 词法歧义（strx.cj 每包一份的同族），不计
                                        var ambiguous = false
                                        match (archDefMods.get(tok)) {
                                            case Some(ms) => ambiguous = Int64(ms.size) > 1
                                            case None => ()
                                        }
                                        if (!ambiguous) {
                                            archSeen.add(tok)
                                            for (defFile in list) {
                                                if (defFile == f.relPath) { continue }
                                                match (archRefCount.get(f.relPath)) {
                                                    case Some(inner) =>
                                                        match (inner.get(defFile)) {
                                                            case Some(v) => inner[defFile] = v + 1
                                                            case None => inner[defFile] = 1
                                                        }
                                                    case None =>
                                                        let inner = HashMap<String, Int64>()
                                                        inner[defFile] = 1
                                                        archRefCount[f.relPath] = inner
                                                }
                                            }
                                        }
                                    case None => ()
                                }
                            }
                        }
                        ai += 1
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

    // ── 架构口径物化：与 refEdges 同一纪律（H3/M11）——archRefCount 是两层
    // HashMap，迭代序不定，物化后立即按全序排定（from↑ → to↑ → count↑），
    // buildArch 的边装配/mermaid/dot/scene 出口字节序才确定。
    let archRefEdges = ArrayList<(String, String, Int64)>()
    for ((from, inner) in archRefCount) {
        for ((to, count) in inner) {
            archRefEdges.add((from, to, count))
        }
    }
    insertionSortBy(archRefEdges, { a, b =>
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

    return (CodeGraph(root, facts, importEdges, refEdges,
                     files.size >= Int64(GRAPH_MAX_FILES), skipped.value,
                     referencedNames, unresolvedList, unusedImports,
                     oversize.value, unreadableDirs, archRefEdges),
            probeAcc.snapshot())
}

/// 构建代码图谱。root 必须是已存在的目录。旧签名零破坏：
/// 图谱消费方（render/arch/confidence/MCP/既有测试）全部照旧。
public func buildGraph(root: String): CodeGraph {
    let r = buildGraphProbed(root)
    return r[0]
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
    /// 引用文件数达上限被截断（契约B：出口恒发该键——「还有更多没列出」
    /// 与「只有这些」对读者是两个事实；原先静默截断）
    public let refFilesCapped: Bool
    /// 波及符号数达上限被截断（契约B：出口恒发该键）
    public let impactedCapped: Bool

    public init(name: String, defs: ArrayList<(String, SymDecl)>,
                refFiles: ArrayList<String>,
                impactedSymbols: ArrayList<(String, SymDecl)>,
                refFilesCapped: Bool, impactedCapped: Bool) {
        this.name = name
        this.defs = defs
        this.refFiles = refFiles
        this.impactedSymbols = impactedSymbols
        this.refFilesCapped = refFilesCapped
        this.impactedCapped = impactedCapped
    }
}

public func impactOf(graph: CodeGraph, name: String): Option<ImpactResult> {
    return impactOf(graph, name, IMPACT_MAX_FILES)
}

/// 带可注入上限的重载（默认 IMPACT_MAX_FILES；小上限供行为测试验证
/// 截断披露——契约B 的两个 capped 标志在 collect 循环三处 break 时置位）。
public func impactOf(graph: CodeGraph, name: String, maxFiles: Int64): Option<ImpactResult> {
    let idx = graph.symbolIndex()
    match (idx.get(name)) {
        case Some(defs) =>
            let defSet = HashSet<String>()
            for ((f, _) in defs) { defSet.add(f) }
            let refFiles = ArrayList<String>()
            var refCapped = false
            for ((from, to, _) in graph.refEdges) {
                if (defSet.contains(to) && !defSet.contains(from) && !refFiles.contains(from)) {
                    refFiles.add(from)
                    if (Int64(refFiles.size) >= maxFiles) {
                        refCapped = true
                        break
                    }
                }
            }
            let impacted = ArrayList<(String, SymDecl)>()
            var impCapped = false
            for (f in factsOf(graph)) {
                if (!refFiles.contains(f.relPath)) { continue }
                for (s in f.symbols) {
                    impacted.add((f.relPath, s))
                    if (Int64(impacted.size) >= maxFiles) {
                        impCapped = true
                        break
                    }
                }
                if (Int64(impacted.size) >= maxFiles) {
                    impCapped = true
                    break
                }
            }
            return Some(ImpactResult(name, defs, refFiles, impacted, refCapped, impCapped))
        case None => return None
    }
}

func factsOf(graph: CodeGraph): ArrayList<FileEntry> {
    return graph.files
}
