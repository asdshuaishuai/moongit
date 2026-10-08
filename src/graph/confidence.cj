// graph/confidence.cj — 代码置信度：结构性疑点的确定性度量。
//
// 【为什么需要它】AI 生成的代码最常见的不是「编译不过」，而是
// 一批**看起来对**的结构性疑点：孤立的符号（定义了没人用）、
// 空实现（函数体只有 pass/return nil）、吞掉错误的 catch、
// 魔法数字、TODO 残留。它们单看都不致命，合在一起就是
// 「这段代码到底可不可信」的答案缺失。
//
// 【AI 无关边界】引擎**不做 LLM 调用**（红线）。这里只产出：
//   ① 确定性信号（词法 + 语法树事实，逐条带 file:line 证据）
//   ② 一份预填的 LLM 复核提示词（llmPrompt），上层 agent 可拿去喂模型
// 分数 = 结构级信号的汇总，**不是正确性证明** —— 这个语义写进输出。
//
// 【语法树从哪来】不自造 parser：调用已装的开源 `ast-grep`
// （tree-sitter 内核，9 种语言）。不可用时**优雅降级**为纯词法度量，
// 并在 coverage 里如实披露降级（不许把降级说成全量）。
package moongit.graph

import std.collection.*
import std.convert.*
import moongit.util.*

// MARK: - 模型

/// 疑点类别。穷尽 match 的消费方：权重表、渲染、JSON、llmPrompt。
public enum FlawKind {
    | Orphan          // 孤儿符号：定义了，全仓无引用
    | StubBody        // 空体/占位实现（pass / return nil / 空 {}）
    | SwallowedError  // catch 里什么都不做（吞错误）
    | MagicNumber     // 函数体内的裸魔法数字
    | LongFunction    // 超长函数（阈值披露）
    | DeepNesting     // 深嵌套
    | TodoResidue     // TODO/FIXME/XXX 残留
    | SuspiciousName  // 可疑命名（tmp/foo/单字符/new+old 等 AI 习惯）
    | DuplicateBody   // 完全相同的函数体（复制粘贴，多处出现）
}

public func flawId(k: FlawKind): String {
    match (k) {
        case Orphan => "orphan"
        case StubBody => "stub-body"
        case SwallowedError => "swallowed-error"
        case MagicNumber => "magic-number"
        case LongFunction => "long-function"
        case DeepNesting => "deep-nesting"
        case TodoResidue => "todo-residue"
        case SuspiciousName => "suspicious-name"
        case DuplicateBody => "duplicate-body"
    }
}

public func flawLabel(k: FlawKind, en: Bool): String {
    if (en) {
        match (k) {
            case Orphan => "Orphan symbol"
            case StubBody => "Stub body"
            case SwallowedError => "Swallowed error"
            case MagicNumber => "Magic numbers"
            case LongFunction => "Long function"
            case DeepNesting => "Deep nesting"
            case TodoResidue => "TODO residue"
            case SuspiciousName => "Suspicious name"
            case DuplicateBody => "Duplicate body"
        }
    } else {
        match (k) {
            case Orphan => "孤儿符号"
            case StubBody => "占位实现"
            case SwallowedError => "错误被吞"
            case MagicNumber => "魔法数字"
            case LongFunction => "超长函数"
            case DeepNesting => "深嵌套"
            case TodoResidue => "TODO 残留"
            case SuspiciousName => "可疑命名"
            case DuplicateBody => "重复函数体"
        }
    }
}

/// 每类疑点的扣分权重。**表只有一个**（改分只改这里）。
/// 排序理由：孤儿与占位实现是「这段代码可能压根没在跑」；
/// 吞错误是「出错时你看不见」；重复体是「同一个 bug 有两份」。
/// 其余是维护性信号，扣分递减。
public func flawWeight(k: FlawKind): Int64 {
    match (k) {
        case Orphan => 12
        case StubBody => 12
        case SwallowedError => 10
        case DuplicateBody => 8
        case MagicNumber => 3
        case LongFunction => 4
        case DeepNesting => 4
        case TodoResidue => 2
        case SuspiciousName => 3
    }
}

/// 阈值。**全部集中在这里**，输出里逐条披露（不许隐藏口径）。
public let CONF_LONG_FUNCTION_LINES: Int64 = 80
public let CONF_DEEP_NESTING: Int64 = 5
/// 单文件里同一类疑点最多报几条（防噪声淹没；超出时计数汇总为一条）
public let CONF_MAX_PER_KIND_PER_FILE: Int64 = 6
/// 单次分析最多报多少条 findings（防止巨型仓库输出爆炸）
public let CONF_MAX_FINDINGS: Int64 = 400

/// 一条疑点：类别 + 位置 + 证据。证据必须自足（人不开编辑器就能判断）。
public struct Finding {
    public let kind: FlawKind
    public let file: String
    public let line: Int64
    public let symbol: String
    public let evidence: String

    public init(kind: FlawKind, file: String, line: Int64, symbol: String, evidence: String) {
        this.kind = kind
        this.file = file
        this.line = line
        this.symbol = symbol
        this.evidence = evidence
    }
}

/// 语法树节点事实（ast-grep 的一条命中）。
public struct AstNode {
    public let file: String
    public let startLine: Int64   // 1-based
    public let endLine: Int64
    /// 节点种类（ast-grep ruleId：fn / class / method …）
    public let nodeRule: String
    public let text: String

    public init(file: String, startLine: Int64, endLine: Int64, nodeRule: String, text: String) {
        this.file = file
        this.startLine = startLine
        this.endLine = endLine
        this.nodeRule = nodeRule
        this.text = text
    }
}

/// 分析报告。
public class ConfidenceReport {
    public let root: String
    public let score: Int64            // 0..100（100 = 未发现结构性疑点）
    public let findings: ArrayList<Finding>
    public let astUsed: Bool           // 语法树是否真的用上了
    public let astNote: String         // 降级原因或覆盖说明
    public let filesAnalyzed: Int64
    public let byKind: ArrayList<(FlawKind, Int64)>

    public init(root: String, score: Int64, findings: ArrayList<Finding>,
                astUsed: Bool, astNote: String,
                filesAnalyzed: Int64,
                byKind: ArrayList<(FlawKind, Int64)>) {
        this.root = root
        this.score = score
        this.findings = findings
        this.astUsed = astUsed
        this.astNote = astNote
        this.filesAnalyzed = filesAnalyzed
        this.byKind = byKind
    }
}

// MARK: - 主流程

/// 分析入口。`useAst=false` 或 ast-grep 不可用时走纯词法。
public func analyzeConfidence(graph: CodeGraph, useAst: Bool): ConfidenceReport {
    let findings = ArrayList<Finding>()
    var astNodes = ArrayList<AstNode>()
    var astUsed = false
    var astNote = ""

    if (useAst) {
        match (runAstGrep(graph)) {
            case Some(nodes) =>
                astNodes = nodes
                astUsed = true
                // 覆盖度披露：多少文件真走了 AST、多少因语言降级
                var astFiles = Int64(0)
                var fallbackFiles = Int64(0)
                let fallbackLangs = ArrayList<String>()
                for (f in graph.files) {
                    if (astGrepLang(f.lang).isEmpty()) {
                        fallbackFiles += 1
                        if (!fallbackLangs.contains(f.lang)) { fallbackLangs.add(f.lang) }
                    } else {
                        astFiles += 1
                    }
                }
                astNote = "语法树：ast-grep (tree-sitter)，${astFiles} 文件走 AST、"
                    + "命中 ${Int64(nodes.size)} 个结构节点"
                if (fallbackFiles > 0) {
                    astNote += "；${fallbackFiles} 文件因语言无 tree-sitter 语法降级为词法级（"
                        + joinStrings(fallbackLangs, "、") + "）"
                }
            case None =>
                // 两种成因分开披露：工具没装 vs 装了但本次语言无语法覆盖。
                // 原版把两者混成一句「未安装，或…」，读者无法判断该不该去装工具。
                if (findAstGrep().isSome()) {
                    astNote = "语法树不可用：ast-grep 已安装，但本次全部文件的语言都无 tree-sitter 语法（如纯仓颉仓库）——"
                        + "已降级为词法级分析；函数粒度信号改由词法路径近似（长度/嵌套/魔法数/空体），"
                        + "吞错与重复体仍缺失"
                } else {
                    astNote = "语法树不可用：未安装 ast-grep（`brew install ast-grep` 可获得 tree-sitter 级覆盖）——"
                        + "已降级为词法级分析；函数粒度信号改由词法路径近似（长度/嵌套/魔法数/空体），"
                        + "吞错与重复体仍缺失"
                }
        }
    } else {
        astNote = "按调用方要求跳过语法树（--no-ast），仅词法级分析"
    }

    // ── ① 孤儿符号：定义了，全仓无引用（图数据直接支撑）──
    detectOrphans(graph, findings)
    // ── ② 命名可疑 ──
    detectSuspiciousNames(graph, findings)
    // ── ③ TODO 残留（按文件计数）──
    detectTodos(graph, findings)
    // ── ④ 函数粒度信号：AST 节点 + 词法近似 ──
    // AST 覆盖得到时用 AST；词法路径**始终**补跑 AST 覆盖不到的语言
    // （如纯仓颉仓库 / 混合仓库里的仓颉文件），否则这些语言只剩「超长函数」。
    if (astUsed) {
        detectFromAst(astNodes, findings)
    }
    detectLexicalFunctionSignals(graph, findings, astUsed)
    // ── ⑤ 重复函数体（同体哈希，需 AST 的准确边界）──
    if (astUsed) {
        detectDuplicateBodies(astNodes, findings)
    }

    // 排序：全序（见 sortFindings），确定性 + 重要的在前
    sortFindings(findings)
    // 总量截断（披露进 astNote，不静默）
    var truncatedNote = ""
    if (Int64(findings.size) > CONF_MAX_FINDINGS) {
        let extra = Int64(findings.size) - CONF_MAX_FINDINGS
        while (Int64(findings.size) > CONF_MAX_FINDINGS) {
            findings.remove(at: findings.size - 1)
        }
        truncatedNote = "；另有 ${extra} 条低权重疑点未列出（按权重截断）"
    }

    // 每类计数
    // enum 作 HashMap 键需要 Hashable 派生；这里用 id 字符串当键（零依赖）
    let counts = HashMap<String, Int64>()
    let kindById = HashMap<String, FlawKind>()
    for (f in findings) {
        let kid = flawId(f.kind)
        kindById[kid] = f.kind
        match (counts.get(kid)) {
            case Some(v) => counts[kid] = v + 1
            case None => counts[kid] = 1
        }
    }
    let byKind = ArrayList<(FlawKind, Int64)>()
    for ((kid, v) in counts) {
        match (kindById.get(kid)) {
            case Some(k) => byKind.add((k, v))
            case None => ()
        }
    }
    insertionSortBy(byKind, { a, b =>
        let ka = a[0]
        let kb = b[0]
        let wa = flawWeight(ka)
        let wb = flawWeight(kb)
        if (wa != wb) { return wa > wb }
        // 权重并列（如 MagicNumber=3 与 SuspiciousName=3）时按 id 兜底，
        // 否则顺序随 HashMap 迭代而变 ⇒ 违反逐字节一致
        return flawId(ka) < flawId(kb)
    })

    // 分数：由「惩罚总量」与「文件数」算的**密度分**（见 confidenceScore）。
    // ⚠️ 旧公式 `100 − 惩罚/√文件数` 与仓库规模相关：惩罚随文件数线性增长、
    // 而 √ 增长更慢 ⇒ 大仓库必然趋近 0（实测 276 文件的仓库、每文件仅 4.3 点却只得 28 分；
    // 而另一处每文件 15 点的仓库也是 0 —— 同一个分数说不出谁更差）。
    var penalty: Int64 = 0
    for (f in findings) { penalty += flawWeight(f.kind) }
    let nFiles = Int64(graph.files.size)
    let score = confidenceScore(penalty, nFiles)

    return ConfidenceReport(graph.root, score, findings, astUsed,
                            astNote + truncatedNote, nFiles, byKind)
}

/// findings 的**全序**排序（`AGENTS.md` 契约：同一仓库两次运行逐字节一致）。
/// ⚠️ 原比较器只按 (权重, file, line)：权重并列且 file:line 相同时判等，
/// 于是依赖**输入顺序** —— 而输入来自 `runAstGrep` 里按语言分组的 HashMap 迭代，
/// 顺序不确定。实测 deepDolphin 两次运行 findings 的 (long-function, deep-nesting)
/// 对在同一函数首行翻转（两者权重都是 4）。补足全序：
/// 权重↓ → file↑ → line↑ → flawId↑ → symbol↑。
public func sortFindings(findings: ArrayList<Finding>): Unit {
    insertionSortBy(findings, { a, b => findingLess(a, b) })
}

func findingLess(a: Finding, b: Finding): Bool {
    let wa = flawWeight(a.kind)
    let wb = flawWeight(b.kind)
    if (wa != wb) { return wa > wb }
    if (a.file != b.file) { return a.file < b.file }
    if (a.line != b.line) { return a.line < b.line }
    let ia = flawId(a.kind)
    let ib = flawId(b.kind)
    if (ia != ib) { return ia < ib }
    return a.symbol < b.symbol
}

/// 分数标度。`density = 惩罚 / 文件数`（平均每文件的疑点权重），
/// `score = 100 · S / (S + density)`：density=S 时得 50 分。
/// **与仓库规模无关**是刻意设计（旧的 `100 − 惩罚/√文件数` 在文件多时必然压到 0）。
public let CONF_SCORE_SCALE: Float64 = 20.0

/// 由「惩罚总量」与「文件数」算 0..100 的置信度分数。
/// 抽成**纯函数**是为了让「规模不变性」可被单测（见 graph_test）——
/// 内联在 analyzeConfidence 里就只能靠端到端样本，而样本很难覆盖规模轴。
public func confidenceScore(penalty: Int64, files: Int64): Int64 {
    let n = if (files < 1) { 1 } else { files }
    let density = Float64(penalty) / Float64(n)
    let s = CONF_SCORE_SCALE
    var score = Int64(100.0 * s / (s + density))
    if (score > 100) { score = 100 }
    if (score < 0) { score = 0 }
    return score
}
