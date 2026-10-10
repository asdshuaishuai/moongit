// graph/patchconf.cj — 补丁级代码置信度（三层架构的 Layer 1：算法层）。
//
// 【三层分工（评审设计）】
//   Layer 1（本文件）：解析 patch + 抽关系 + 算 S1..S10 信号 + 分出
//     certain（算法已定，Agent 不用管）/ uncertain（送 Layer 2 的待办清单）
//   Layer 2：Agent 读 algorithm.json 的 uncertain，按 skill 文件用工具查代码，
//     输出 agent.json（skill 文本由 patchconf_skill() 提供）
//   Layer 3：合并器（patchconf_merge）—— 简单规则，不做概率推理
//
// 【词法边界，如实标注】S2/S7 依赖类型信息，词法层只能近似或置空（null 信号
// 不进均值，diagnostics 披露）；S6 用括号配平作控制流代理。AST 可用时 S7
// 用 type 节点提升，但 v1 先词法——诚实披露比装懂强。
package moongit.graph

import std.collection.*
import std.convert.*
import moongit.util.*

// MARK: - patch 解析

/// 一行 patch：kind 0=上下文 1=新增 2=删除
public struct PatchLine {
    public let kind: Int64
    public let text: String
    public let newNo: Int64   // 新文件行号；删除/无对应行为 0

    public init(kind: Int64, text: String, newNo: Int64) {
        this.kind = kind
        this.text = text
        this.newNo = newNo
    }
}

/// 一个文件的补丁段
public struct PatchFile {
    public let newPath: String
    public let lines: ArrayList<PatchLine>

    public init(newPath: String, lines: ArrayList<PatchLine>) {
        this.newPath = newPath
        this.lines = lines
    }
}

/// 解析 unified diff。容忍 git 的 a/ b/ 前缀与 \ No newline 尾注；
/// 识别不了的段（二进制/重命名无 hunk）静默跳过并在 parseErrors 计数。
public func parseUnifiedDiff(text: String): (ArrayList<PatchFile>, Int64) {
    let files = ArrayList<PatchFile>()
    var errors: Int64 = 0
    var curPath = ""
    var curLines = ArrayList<PatchLine>()
    var newNo: Int64 = 0
    for (raw in text.lazySplit("\n")) {
        if (raw.startsWith("+++ ")) {
            // 收尾上一个文件
            if (!curPath.isEmpty()) {
                files.add(PatchFile(curPath, curLines))
            }
            curPath = stripAbPrefix(raw[4..].trimAscii())
            curLines = ArrayList<PatchLine>()
            continue
        }
        if (raw.startsWith("@@")) {
            // @@ -l,c +l,c @@ —— 取 + 段起始行
            let plusIdx = findChar(raw, 43u8)   // '+'
            if (plusIdx.isSome()) {
                var i = plusIdx.getOrThrow() + 1
                let b = raw.toArray()
                var num: Int64 = 0
                var hasNum = false
                while (i < Int64(b.size) && b[i] >= 48 && b[i] <= 57) {
                    num = num * 10 + Int64(b[i] - 48)
                    hasNum = true
                    i += 1
                }
                newNo = if (hasNum) { num } else { 1 }
            }
            continue
        }
        if (curPath.isEmpty()) { continue }
        if (raw.startsWith("\\")) { continue }   // \ No newline
        if (raw.startsWith("+")) {
            curLines.add(PatchLine(1, raw[1..], newNo))
            newNo += 1
        } else if (raw.startsWith("-")) {
            curLines.add(PatchLine(2, raw[1..], 0))
        } else {
            let ctxText = if (raw.size > 0) { raw[1..] } else { raw }
            curLines.add(PatchLine(0, ctxText, newNo))
            if (newNo > 0) { newNo += 1 }
        }
    }
    if (!curPath.isEmpty()) {
        files.add(PatchFile(curPath, curLines))
    }
    return (files, errors)
}

func stripAbPrefix(p: String): String {
    if (p.startsWith("a/")) { return p[2..] }
    if (p.startsWith("b/")) { return p[2..] }
    return p
}

func findChar(s: String, c: UInt8): Option<Int64> {
    let b = s.toArray()
    var i: Int64 = 0
    while (i < Int64(b.size)) {
        if (b[i] == c) { return Some(i) }
        i += 1
    }
    return None
}

// MARK: - 未决项

/// uncertain 的问题类型（Layer 2 的待办分类）
public enum UncKind {
    | UAmbiguousCall
    | UUnresolvedCall
    | UUnresolvedImport
    | UUseBeforeDef
    | UUnbalancedBraces
}

func uncId(k: UncKind): String {
    match (k) {
        case UAmbiguousCall => "ambiguous_call"
        case UUnresolvedCall => "unresolved_call"
        case UUnresolvedImport => "unresolved_import"
        case UUseBeforeDef => "use_before_def"
        case UUnbalancedBraces => "unbalanced_braces"
    }
}

/// 一条未决项：Agent 的最小工作单元
public struct UncertainItem {
    public let id: String          // file@line:name 形态
    public let kind: UncKind
    public let detail: String
    public let candidates: ArrayList<String>
    public let file: String
    public let line: Int64

    public init(id: String, kind: UncKind, detail: String,
                candidates: ArrayList<String>, file: String, line: Int64) {
        this.id = id
        this.kind = kind
        this.detail = detail
        this.candidates = candidates
        this.file = file
        this.line = line
    }
}

// MARK: - 实体（certain）

/// patch 新增的一个声明及其关系
public struct PatchEntity {
    public let id: String          // name@file:newNo
    public let name: String
    public let kind: String        // func / class / ...
    public let confidence: Float64
    public let relations: ArrayList<(String, String, Float64)>   // (type, target, conf)
    public let file: String
    public let line: Int64

    public init(id: String, name: String, kind: String, confidence: Float64,
                relations: ArrayList<(String, String, Float64)>, file: String, line: Int64) {
        this.id = id
        this.name = name
        this.kind = kind
        this.confidence = confidence
        this.relations = relations
        this.file = file
        this.line = line
    }
}

// MARK: - 分析结果

public class PatchConfidence {
    public let overall: Float64
    /// S1..S10；值域 0..1；nullSignals 里的是词法层算不了的（不进均值）
    public let signals: ArrayList<(String, Float64)>
    public let nullSignals: ArrayList<String>
    public let entities: ArrayList<PatchEntity>
    public let uncertain: ArrayList<UncertainItem>
    public let totalEntities: Int64
    public let totalRelations: Int64
    public let parseErrors: Int64
    public let patchFiles: Int64
    public let addedLines: Int64

    public init(overall: Float64, signals: ArrayList<(String, Float64)>,
                nullSignals: ArrayList<String>,
                entities: ArrayList<PatchEntity>, uncertain: ArrayList<UncertainItem>,
                totalEntities: Int64, totalRelations: Int64, parseErrors: Int64,
                patchFiles: Int64, addedLines: Int64) {
        this.overall = overall
        this.signals = signals
        this.nullSignals = nullSignals
        this.entities = entities
        this.uncertain = uncertain
        this.totalEntities = totalEntities
        this.totalRelations = totalRelations
        this.parseErrors = parseErrors
        this.patchFiles = patchFiles
        this.addedLines = addedLines
    }
}

// MARK: - Layer 1 主流程

/// 分析入口：repo 的图谱 + patch 文本 → 信号 + certain/uncertain 分层。
public func analyzePatchConfidence(graph: CodeGraph, patchText: String): PatchConfidence {
    let (pfiles, parseErrors) = parseUnifiedDiff(patchText)

    // ── 符号表（repo 侧）──
    let defFiles = HashMap<String, ArrayList<String>>()   // 名 → 定义文件列表
    for (f in graph.files) {
        for (s in f.symbols) {
            match (defFiles.get(s.name)) {
                case Some(list) => if (!list.contains(f.relPath)) { list.add(f.relPath) }
                case None =>
                    let list = ArrayList<String>()
                    list.add(f.relPath)
                    defFiles[s.name] = list
            }
        }
    }

    // ── patch 新增行收集（代码态）+ 新增声明 + 引用统计 ──
    let uncertain = ArrayList<UncertainItem>()
    let entities = ArrayList<PatchEntity>()
    var totalRefs: Int64 = 0
    var resolvedRefs: Int64 = 0
    var totalCalls: Int64 = 0
    var callScore: Float64 = 0.0
    var totalImports: Int64 = 0
    var resolvedImports: Int64 = 0
    var addedLines: Int64 = 0
    var anotDecls: Int64 = 0
    var totalDecls: Int64 = 0
    // S8：patch 新增调用的参数个数 vs 定义行参数个数
    var compatCalls: Int64 = 0
    var totalCrossCalls: Int64 = 0
    // S5/S6 原料
    var braceDepth: Int64 = 0
    var braceNeg: Int64 = 0
    // patch 内新声明的符号（「扫到第 N 行时已知」的那一份：引用解析用）
    let patchDecls = HashMap<String, (String, Int64)>()   // 名 → (file, newNo)
    // patch 内**全部**新声明（use-before-def 判定用）。
    // ⚠️ 必须与 patchDecls 分成两份：边扫边填的 patchDecls 里只有行号 ≤ N 的
    // 声明，`n2 > pl.newNo` 于是永假 ⇒ UUseBeforeDef 一条也不产生、S5 恒为
    // 1.0 虚抬 overall 约 1/10 标度（审查 H2）。use-before-def 问的是「这次
    // 补丁里有没有先用后声明」，答案需要全量表，不能问「到目前为止」。
    let allPatchDecls = HashMap<String, (String, Int64)>()
    for (pf0 in pfiles) {
        for (pl0 in pf0.lines) {
            if (pl0.kind != 1) { continue }
            let (t0, _) = stripCode(pl0.text, 0)
            if (blankLine(t0)) { continue }
            match (scanDeclLine(tokenize(t0))) {
                case Some((_, name0)) =>
                    allPatchDecls[name0] = (pf0.newPath, pl0.newNo)
                case None =>
                    match (cStyleFuncName(t0, detectLang(pf0.newPath))) {
                        case Some(name0) => allPatchDecls[name0] = (pf0.newPath, pl0.newNo)
                        case None => ()
                    }
            }
        }
    }

    for (pf in pfiles) {
        // 文件在 repo 中的模块（S4 用）：能被 moduleIndex 命中即可
        var addedInFile: Int64 = 0
        for (pl in pf.lines) {
            if (pl.kind != 1) { continue }
            addedLines += 1
            addedInFile += 1
            let (t, _) = stripCode(pl.text, 0)
            if (blankLine(t)) { continue }
            // 新增声明 → entity + patchDecls
            match (scanDeclLine(tokenize(t))) {
                case Some((kind, name)) =>
                    patchDecls[name] = (pf.newPath, pl.newNo)
                    // 类型标注（S2）：swift/cangjie/rust/ts 的 `x: T`；go 的 `x T`
                    totalDecls += 1
                    if (hasTypeAnnotation(t)) { anotDecls += 1 }
                    // entity 关系 = 该声明体内（到下一个声明前的新增行）的调用
                    // v1 简化：本行 + 后续 15 行新增行的调用归入（词法近似）
                    //
                    // ⚠️ 这里**只收集关系**，绝不再累计 totalRefs/totalCalls/
                    // resolvedRefs/callScore，也不在这里加 uncertain：这些行随后
                    // 会被主循环的 `case None` 分支逐行统计一遍，双算的后果是
                    // ① 同一 id 的 entity 每个前窥行生成一个（原缺陷 H1：
                    //    entities.add 落在 while 体内）② unresolved 的 uncertain
                    //    被加两遍，而合并器（patchconf_render.cj 的
                    //    mergePatchConfidence）逐条把 uncertain 计入 conf 均值
                    //    ⇒ 整体被重复计入。声明后紧跟另一声明行时首轮即 break，
                    //    原实现连一条 entity 都不生成——现在 add 在 while 之外。
                    let rels = ArrayList<(String, String, Float64)>()
                    var relScore: Float64 = 0.0
                    var relCount: Int64 = 0
                    var li = indexOfLine(pf.lines, pl)
                    var look = 0
                    while (look < 15 && li + look + 1 < Int64(pf.lines.size)) {
                        let nl = pf.lines[li + look + 1]
                        look += 1
                        if (nl.kind != 1) { continue }
                        let (nt, _) = stripCode(nl.text, 0)
                        if (blankLine(nt)) { continue }
                        // 到下一个声明为止
                        if (scanDeclLine(tokenize(nt)).isSome()) { break }
                        for ((cname, _) in freeCallsIn(nt)) {
                            match (defFiles.get(cname)) {
                                case Some(list) =>
                                    let c = Float64(Int64(list.size))
                                    relScore += 1.0 / c
                                    relCount += 1
                                    if (Int64(list.size) == 1) {
                                        rels.add(("calls", "${cname}@${list[0]}", 1.0))
                                    } else if (Int64(list.size) <= 4) {
                                        rels.add(("calls", "${cname}@${list[0]}", 1.0 / c))
                                    }
                                case None => ()
                            }
                        }
                    }
                    let conf = if (relCount == 0) { 0.9 } else { relScore / Float64(relCount) }
                    entities.add(PatchEntity("${name}@${pf.newPath}:${pl.newNo}", name,
                        symKindId(kind), conf, rels, pf.newPath, pl.newNo))
                case None =>
                    match (cStyleFuncName(t, detectLang(pf.newPath))) {
                        case Some(name) =>
                            patchDecls[name] = (pf.newPath, pl.newNo)
                            totalDecls += 1
                            if (hasTypeAnnotation(t)) { anotDecls += 1 }
                            entities.add(PatchEntity("${name}@${pf.newPath}:${pl.newNo}", name,
                                "func", 0.9, ArrayList<(String, String, Float64)>(), pf.newPath, pl.newNo))
                        case None => ()
                    }
                    // 非声明行：引用统计
                    for ((cname, argCount) in freeCallsIn(t)) {
                        totalRefs += 1
                        totalCalls += 1
                        match (defFiles.get(cname)) {
                            case Some(list) =>
                                resolvedRefs += 1
                                let c = Float64(Int64(list.size))
                                callScore += 1.0 / c
                                totalCrossCalls += 1
                                if (defArgCount(graph, list[0], cname) == argCount) {
                                    compatCalls += 1
                                }
                                if (Int64(list.size) >= 2 && Int64(list.size) <= 4) {
                                    let cands = ArrayList<String>()
                                    for (fp in list) { cands.add("${cname}@${fp}") }
                                    uncertain.add(UncertainItem(
                                        "${pf.newPath}@${pl.newNo}:${cname}",
                                        UAmbiguousCall,
                                        "${cname} matches ${Int64(list.size)} definitions",
                                        cands, pf.newPath, pl.newNo))
                                }
                            case None =>
                                match (patchDecls.get(cname)) {
                                    case Some(_) => resolvedRefs += 1
                                    case None =>
                                        // 补丁内**后文**声明的符号不算 unresolved：
                                        // use-before-def 扫描（下方 S5）会按同一引用
                                        // 记一次 UUseBeforeDef，这里再加 UUnresolvedCall
                                        // 就是同一处双罚 + 给 Layer 2 留一条答案
                                        // 显而易见的待办（复审 2026-10-10 新问题 1）。
                                        match (allPatchDecls.get(cname)) {
                                            case Some(_) => resolvedRefs += 1
                                            case None =>
                                                uncertain.add(UncertainItem(
                                                    "${pf.newPath}@${pl.newNo}:${cname}",
                                                    UUnresolvedCall,
                                                    "call to ${cname}(…) not found in repo or patch",
                                                    ArrayList<String>(), pf.newPath, pl.newNo))
                                        }
                                }
                        }
                    // import（S4）
                    let imp = scanImportLine(t.trimAscii())
                    if (!imp.isEmpty()) {
                        totalImports += 1
                        // repo 里任一文件路径含该模块段即视为解析
                        var hit = false
                        for (g in graph.files) {
                            if (pathContainsSeg(g.relPath, imp)) { hit = true; break }
                        }
                        if (!hit) {
                            match (patchDecls.get(imp)) {
                                case Some(_) => hit = true
                                case None =>
                                    uncertain.add(UncertainItem(
                                        "${pf.newPath}@${pl.newNo}:${imp}",
                                        UUnresolvedImport,
                                        "import ${imp} resolves to nothing in repo",
                                        ArrayList<String>(), pf.newPath, pl.newNo))
                            }
                        }
                        if (hit) { resolvedImports += 1 }
                    }
                    // 花括号配平（S6）
                    for (b in t) {
                        if (b == 123) { braceDepth += 1 }
                        if (b == 125) {
                            braceDepth -= 1
                            if (braceDepth < 0) { braceNeg += 1; braceDepth = 0 }
                        }
                    }
                    // use-before-def（S5）：本行引用 patchDecls 中声明在后的符号。
                    // 手写 token 扫描（lambda 不能写捕获容器）。
                    let tb = t.toArray()
                    let tn = Int64(tb.size)
                    var ti: Int64 = 0
                    while (ti < tn) {
                        if (isIdentByte(tb[ti])) {
                            let st2 = ti
                            while (ti < tn && isIdentByte(tb[ti])) { ti += 1 }
                            let tok = fromUtf8Lossy(tb[st2..ti])
                            match (allPatchDecls.get(tok)) {
                                case Some((f2, n2)) =>
                                    if (pf.newPath == f2 && n2 > pl.newNo && pl.newNo > 0) {
                                        uncertain.add(UncertainItem(
                                            "${pf.newPath}@${pl.newNo}:${tok}",
                                            UUseBeforeDef,
                                            "${tok} used at L${pl.newNo} but declared at L${n2}",
                                            ArrayList<String>(), pf.newPath, pl.newNo))
                                    }
                                case None => ()
                            }
                        } else {
                            ti += 1
                        }
                    }
                }
            }
        }
    }

    // ── 信号计算（分母为 0 的置 null）──
    let signals = ArrayList<(String, Float64)>()
    let nulls = ArrayList<String>()
    // 仓颉 lambda 不能写捕获容器——push 展开为宏式手写（4 处分母判定）
    if (totalRefs > 0) {
        signals.add(("S1", Float64(resolvedRefs) / Float64(totalRefs)))
    } else { nulls.add("S1") }
    if (totalDecls > 0) {
        signals.add(("S2", Float64(anotDecls) / Float64(totalDecls)))
    } else { nulls.add("S2") }
    if (totalCalls > 0) {
        signals.add(("S3", callScore / Float64(totalCalls)))
    } else { nulls.add("S3") }
    if (totalImports > 0) {
        signals.add(("S4", Float64(resolvedImports) / Float64(totalImports)))
    } else { nulls.add("S4") }
    var ubd: Int64 = 0
    for (u in uncertain) {
        if (uncId(u.kind) == "use_before_def") { ubd += 1 }
    }
    if (totalRefs > 0) {
        signals.add(("S5", 1.0 - Float64(ubd) / Float64(totalRefs)))
    } else { nulls.add("S5") }
    signals.add(("S6", if (braceNeg == 0 && braceDepth == 0) { 1.0 } else { 0.0 }))
    nulls.add("S7")   // 契约一致率需要接口实现对照——词法层置空（如实披露）
    if (totalCrossCalls > 0) {
        signals.add(("S8", Float64(compatCalls) / Float64(totalCrossCalls)))
    } else { nulls.add("S8") }
    // S9 结构正常率：patch 涉及文件的模块的环/违规惩罚（复用图治理信号）
    let arch = buildArch(graph)
    var s9 = 1.0
    if (arch.cycleEdgeCount > 0) {
        s9 -= Float64(arch.cycleEdgeCount) * 0.05
    }
    if (arch.violationCount > 0) {
        s9 -= Float64(arch.violationCount) * 0.05
    }
    if (s9 < 0.0) { s9 = 0.0 }
    signals.add(("S9", s9))
    // S10 patch 内自洽（v1 与 S1 同口径：引用可解析占比）
    if (totalRefs > 0) {
        signals.add(("S10", Float64(resolvedRefs) / Float64(totalRefs)))
    } else { nulls.add("S10") }

    // overall = 有效信号均值
    var sum: Float64 = 0.0
    var n: Int64 = 0
    for ((_, v) in signals) {
        sum += v
        n += 1
    }
    let overall = if (n > 0) { sum / Float64(n) } else { 0.0 }

    return PatchConfidence(overall, signals, nulls, entities, uncertain,
        Int64(entities.size), Int64(totalRefs), parseErrors,
        Int64(pfiles.size), addedLines)
}

// ── 小工具 ──

func indexOfLine(lines: ArrayList<PatchLine>, target: PatchLine): Int64 {
    var i: Int64 = 0
    while (i < Int64(lines.size)) {
        if (lines[i].newNo == target.newNo && lines[i].kind == target.kind
            && lines[i].text == target.text) { return i }
        i += 1
    }
    return -1
}

/// 行内自由调用（name + 实参个数）。返回列表而非回调——仓颉 lambda
/// 不能写捕获环境，调用方需要在外层累计统计。
func freeCallsIn(line: String): ArrayList<(String, Int64)> {
    let out = ArrayList<(String, Int64)>()
    let b = line.toArray()
    let n = Int64(b.size)
    var i: Int64 = 0
    var prevDot = false
    while (i < n) {
        let ch = b[i]
        if (isIdentByte(ch)) {
            let st = i
            while (i < n && isIdentByte(b[i])) { i += 1 }
            let isCall = i < n && b[i] == 40   // '('
            if (isCall && !prevDot) {
                let name = fromUtf8Lossy(b[st..i])
                var depth: Int64 = 0
                var commas: Int64 = 0
                var j = i
                var closed = false
                while (j < n) {
                    let c2 = b[j]
                    if (c2 == 40) { depth += 1 }
                    if (c2 == 41) {
                        depth -= 1
                        if (depth == 0) { closed = true; break }
                    }
                    if (c2 == 44 && depth == 1) { commas += 1 }
                    j += 1
                }
                let argc = if (closed) { commas + 1 } else { 0 }
                out.add((name, argc))
                i = j + 1
                continue
            }
            prevDot = false
        } else {
            prevDot = (ch == 46)
            i += 1
        }
    }
    return out
}

/// 声明行是否带类型标注（swift/cangjie/rust/ts 的 `: T`；java 的 `T x`；
/// go 的 `x T` 词法难分——只认 `:` 形态，go 未标注会计入未标注，如实近似）
func hasTypeAnnotation(line: String): Bool {
    return line.contains(": ")
}

/// repo 中某文件里符号定义行的实参个数（顶层逗号）；找不到返回 -1
func defArgCount(graph: CodeGraph, relFile: String, name: String): Int64 {
    for (f in graph.files) {
        if (f.relPath != relFile) { continue }
        for (s in f.symbols) {
            if (s.name != name) { continue }
            let content = readFileText("${graph.root}/${f.relPath}")
            match (content) {
                case Some(text) =>
                    var lineNo: Int64 = 0
                    for (line in text.lazySplit("\n")) {
                        lineNo += 1
                        if (lineNo != s.line) { continue }
                        // 手写扫描首个调用的实参个数（lambda 不能写捕获变量）
                        let b2 = line.toArray()
                        let n2 = Int64(b2.size)
                        var i2: Int64 = 0
                        var prevDot2 = false
                        while (i2 < n2) {
                            let ch2 = b2[i2]
                            if (isIdentByte(ch2)) {
                                let st2 = i2
                                while (i2 < n2 && isIdentByte(b2[i2])) { i2 += 1 }
                                if (i2 < n2 && b2[i2] == 40 && !prevDot2) {
                                    var depth2: Int64 = 0
                                    var commas2: Int64 = 0
                                    var j2 = i2
                                    var closed2 = false
                                    while (j2 < n2) {
                                        let c3 = b2[j2]
                                        if (c3 == 40) { depth2 += 1 }
                                        if (c3 == 41) {
                                            depth2 -= 1
                                            if (depth2 == 0) { closed2 = true; break }
                                        }
                                        if (c3 == 44 && depth2 == 1) { commas2 += 1 }
                                        j2 += 1
                                    }
                                    return if (closed2) { commas2 + 1 } else { -1 }
                                }
                                prevDot2 = false
                            } else {
                                prevDot2 = (ch2 == 46)
                                i2 += 1
                            }
                        }
                        return -1
                    }
                case None => ()
            }
        }
    }
    return -1
}

func pathContainsSeg(relPath: String, seg: String): Bool {
    for (s in relPath.split("/")) {
        if (s == seg) { return true }
    }
    return false
}
