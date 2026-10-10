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
    | UnresolvedCall  // 幻觉调用：调用全仓不存在的自由函数（AI 编造 API 的标志）
    | UnusedImport    // 未使用 import：解析到目标文件但符号从未出现
    | CommentedCode   // 注释掉的代码块（AI 生成后手动禁用的残留）
    | UnusedVariable  // 变量级：声明后函数体内未再出现（死变量）
    | GodClass        // 类型级：超大类（方法数/行数超阈）
    | EmptyType       // 类型级：空类/空结构体（只有声明没有成员）
    | PointerRisk     // 指针级：malloc/free 不配对、返回栈地址（C/C++）
    | GlobalMutable   // 并发级：顶层可变全局（无同步的共享状态起点）
    | LockImbalance   // 并发级：锁 acquire 后同函数无 release（泄漏/死锁风险）
    | LockUnknownCall // 并发级：锁持有区间内调用外部函数（死锁经典形态）
    // ── 语义层：可靠性/健壮性/设计哲学（AI 写的代码"可不可信"的关键信号）──
    | HighComplexity  // 圈复杂度 >10：决策路径爆炸 → 难测试/易藏 bug（AI 倾向过度分支）
    | ParameterAbuse  // 参数滥用：>5 参数或 Bool 标志参控制分支（God 签名，API 设计缺失）
    | DeadBranch      // 不可达代码：return/break/continue 之后同层级还有语句（AI 生成的残余）
    | MixedResponsibility // 混合职责：同函数内读盘+计算+写盘（不可组合/不可测试）
    | NearDuplicate   // 近重复：函数体归一化后与另一函数 >80% 相似（AI 复制粘贴微改的标志）
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
        case UnresolvedCall => "unresolved-call"
        case UnusedImport => "unused-import"
        case CommentedCode => "commented-code"
        case UnusedVariable => "unused-variable"
        case GodClass => "god-class"
        case EmptyType => "empty-type"
        case PointerRisk => "pointer-risk"
        case GlobalMutable => "global-mutable"
        case LockImbalance => "lock-imbalance"
        case LockUnknownCall => "lock-unknown-call"
        case HighComplexity => "high-complexity"
        case ParameterAbuse => "parameter-abuse"
        case DeadBranch => "dead-branch"
        case MixedResponsibility => "mixed-responsibility"
        case NearDuplicate => "near-duplicate"
        case HighComplexity => "high-complexity"
        case ParameterAbuse => "parameter-abuse"
        case DeadBranch => "dead-branch"
        case MixedResponsibility => "mixed-responsibility"
        case NearDuplicate => "near-duplicate"
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
            case UnresolvedCall => "Unresolved call (hallucinated API?)"
            case UnusedImport => "Unused import"
            case CommentedCode => "Commented-out code"
            case UnusedVariable => "Unused variable"
            case GodClass => "God class"
            case EmptyType => "Empty type"
            case PointerRisk => "Pointer risk"
            case GlobalMutable => "Global mutable state"
            case LockImbalance => "Lock imbalance"
            case LockUnknownCall => "Call while holding lock"
            case HighComplexity => "High cyclomatic complexity"
            case ParameterAbuse => "Parameter count/flag abuse"
            case DeadBranch => "Unreachable code after return"
            case MixedResponsibility => "Mixed I/O + computation responsibility"
            case NearDuplicate => "Near-duplicate function body"
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
            case UnresolvedCall => "幻觉调用"
            case UnusedImport => "未使用 import"
            case CommentedCode => "注释掉的代码"
            case UnusedVariable => "未使用变量"
            case GodClass => "上帝类"
            case EmptyType => "空类型"
            case PointerRisk => "指针风险"
            case GlobalMutable => "全局可变状态"
            case LockImbalance => "锁不平衡"
            case LockUnknownCall => "持锁调用"
            case HighComplexity => "圈复杂度过高"
            case ParameterAbuse => "参数滥用"
            case DeadBranch => "不可达代码"
            case MixedResponsibility => "混合职责"
            case NearDuplicate => "近重复函数体"
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
        case UnresolvedCall => 8
        case LockImbalance => 9
        case LockUnknownCall => 9
        case HighComplexity => 8
        case ParameterAbuse => 6
        case DeadBranch => 6
        case MixedResponsibility => 6
        case NearDuplicate => 5
        case GlobalMutable => 6
        case GodClass => 6
        case PointerRisk => 9
        case EmptyType => 3
        case UnusedVariable => 3
        case UnusedImport => 5
        case CommentedCode => 3
        case MagicNumber => 3
        case LongFunction => 4
        case DeepNesting => 4
        case TodoResidue => 2
        case SuspiciousName => 3
    }
}

/// 置信度的分析维度。评审要求的分层：变量 → 函数/对象 → 类型（类/实体/结构体）
/// → 指针 → 并发链路/并发细节 → 结构。每条 Finding 归属且仅归属一个维度，
/// 报告按维度出分（LLM 复核也按维度分节裁决）。
public enum ConfDimension {
    | DimVariable      // 变量级
    | DimFunction      // 函数/方法/对象级
    | DimType          // 类/结构体/接口/实体级
    | DimPointer       // 指针与内存（C/C++）
    | DimConcurrency   // 并发链路与并发细节
    | DimStructure     // 模块/文件级结构
}

public func dimensionId(d: ConfDimension): String {
    match (d) {
        case DimVariable => "variable"
        case DimFunction => "function"
        case DimType => "type"
        case DimPointer => "pointer"
        case DimConcurrency => "concurrency"
        case DimStructure => "structure"
    }
}

public func dimensionLabel(d: ConfDimension, en: Bool): String {
    if (en) {
        match (d) {
            case DimVariable => "Variables"
            case DimFunction => "Functions & objects"
            case DimType => "Types (class/entity/struct)"
            case DimPointer => "Pointers & memory"
            case DimConcurrency => "Concurrency"
            case DimStructure => "Structure"
        }
    } else {
        match (d) {
            case DimVariable => "变量级"
            case DimFunction => "函数/对象级"
            case DimType => "类型级（类/实体/结构体）"
            case DimPointer => "指针/内存级"
            case DimConcurrency => "并发链路/并发细节"
            case DimStructure => "结构级"
        }
    }
}

/// FlawKind → 维度（穷尽 match：新增疑点不配维度就编译红）。
public func flawDimension(k: FlawKind): ConfDimension {
    match (k) {
        case UnusedVariable => DimVariable
        case SuspiciousName => DimVariable
        case StubBody => DimFunction
        case LongFunction => DimFunction
        case DuplicateBody => DimFunction
        case UnresolvedCall => DimFunction
        case MagicNumber => DimFunction
        case GodClass => DimType
        case EmptyType => DimType
        case PointerRisk => DimPointer
        case GlobalMutable => DimConcurrency
        case LockImbalance => DimConcurrency
        case LockUnknownCall => DimConcurrency
        case HighComplexity => DimFunction
        case ParameterAbuse => DimFunction
        case DeadBranch => DimFunction
        case MixedResponsibility => DimStructure
        case NearDuplicate => DimFunction
        case Orphan => DimStructure
        case UnusedImport => DimStructure
        case CommentedCode => DimStructure
        case DeepNesting => DimStructure
        case TodoResidue => DimStructure
        case SwallowedError => DimConcurrency   // 吞错误归并发/可靠性：出错时无人知晓
    }
}

/// 阈值。**全部集中在这里**，输出里逐条披露（不许隐藏口径）。
public let CONF_LONG_FUNCTION_LINES: Int64 = 80
public let CONF_DEEP_NESTING: Int64 = 5
/// 单文件里同一类疑点最多报几条（防噪声淹没；超出时计数汇总为一条）
public let CONF_MAX_PER_KIND_PER_FILE: Int64 = 6
/// 单次分析最多报多少条 findings（防止巨型仓库输出爆炸）
public let CONF_MAX_FINDINGS: Int64 = 400
/// 上帝类：类型节点行数或方法数超过即报
public let CONF_GOD_CLASS_LINES: Int64 = 400
public let CONF_GOD_CLASS_METHODS: Int64 = 30

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
    /// 按文件聚合的罚分表（罚分降序）——「哪个文件不可信」的直接答案
    public let files: ArrayList<(String, Int64)>
    /// 按维度的 (罚分, 条数, 0..100 维度分)——评审要求的「评分细节」：
    /// 总分之外每个维度单独可读，LLM 复核按此分节。
    public let dimensions: ArrayList<(ConfDimension, Int64, Int64, Int64)>

    public init(root: String, score: Int64, findings: ArrayList<Finding>,
                astUsed: Bool, astNote: String,
                filesAnalyzed: Int64,
                byKind: ArrayList<(FlawKind, Int64)>,
                files: ArrayList<(String, Int64)>,
                dimensions: ArrayList<(ConfDimension, Int64, Int64, Int64)>) {
        this.root = root
        this.score = score
        this.findings = findings
        this.astUsed = astUsed
        this.astNote = astNote
        this.filesAnalyzed = filesAnalyzed
        this.byKind = byKind
        this.files = files
        this.dimensions = dimensions
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
                // 复审 M2 残留：部分批失败必须进报告（原先只进日志——读报告
                // 的人无从分辨「AST 覆盖不完整」与「没有疑点」）
                if (AST_FAILED_BATCHES > 0) {
                    astNote += "；⚠ ast-grep ${AST_FAILED_BATCHES}/${AST_TOTAL_BATCHES} 个批次失败，这些文件的 AST 信号缺失"
                }
            case None =>
                // 三种成因分开披露：工具没装 / 装了但语言无覆盖 / 工具跑了但
                // 批次全败。原版把后两种混成一句「语言无语法覆盖」——全批失败
                // （规则/环境异常）被说成覆盖边界，读者会误以为一切正常。
                if (findAstGrep().isSome()) {
                    if (AST_TOTAL_BATCHES > 0) {
                        astNote = "语法树不可用：ast-grep 已运行，但全部 ${AST_TOTAL_BATCHES} 个批次失败（规则或环境异常）——"
                            + "已降级为词法级分析；函数粒度信号改由词法路径近似（长度/嵌套/魔法数/空体），"
                            + "吞错与重复体仍缺失"
                    } else {
                        astNote = "语法树不可用：ast-grep 已安装，但本次全部文件的语言都无 tree-sitter 语法（如纯仓颉仓库）——"
                            + "已降级为词法级分析；函数粒度信号改由词法路径近似（长度/嵌套/魔法数/空体），"
                            + "吞错与重复体仍缺失"
                    }
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
    // ── ⑥ 幻觉调用 / ⑦ 未使用 import / ⑧ 注释掉的代码 ──
    // 图数据直接支撑：unresolvedCalls / unusedImports 在 buildGraph 两遍扫描时产出
    detectUnresolvedCalls(graph, findings)
    detectUnusedImports(graph, findings)
    detectCommentedCode(graph, findings)
    // ── ⑨ 变量级（未使用变量，需 AST 函数边界）──
    if (astUsed) {
        detectUnusedVariables(astNodes, findings)
    }
    // ── ⑩ 类型级（空类型 / 上帝类，需 AST type 节点）──
    if (astUsed) {
        detectTypeSignals(astNodes, findings)
    }
    // ── 语义层检测（圈复杂度/参数滥用/不可达代码/混合职责/近重复）──
    // ⚠️ 不放在 if (astUsed) 内——纯仓颉仓 astUsed=false，但这些检测全走词法
    try {
        detectSemanticIssues(graph, findings)
    } catch (e: Exception) {
        Log.warn("语义层检测异常（已跳过）: ${e.message}")
    }
    // ── ⑪ 指针风险（C/C++：malloc/free 配对、返回栈地址）──
    detectPointerRisks(graph, findings)
    // ── ⑫ 并发链路/细节（全局可变、锁不平衡、持锁调用）──
    detectConcurrencyRisks(graph, astNodes, astUsed, findings)

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

    // 按文件罚分表（「哪个文件不可信」的直接答案；罚分降序，tie 按 path）
    let byFile = HashMap<String, Int64>()
    for (f in findings) {
        match (byFile.get(f.file)) {
            case Some(v) => byFile[f.file] = v + flawWeight(f.kind)
            case None => byFile[f.file] = flawWeight(f.kind)
        }
    }
    let files = ArrayList<(String, Int64)>()
    for ((fp, pen) in byFile) { files.add((fp, pen)) }
    insertionSortBy(files, { a, b =>
        if (a[1] != b[1]) { return a[1] > b[1] }
        return a[0] < b[0]
    })

    // 按维度 (罚分, 条数, 维度分)。维度分复用密度分标度——但分母用「该维度
    // 相关文件数」不可得（一个文件可属多维度），改用总文件数：维度间的
    // 相对可比性保持，绝对读数与总分同标度。
    let dimPen = HashMap<String, Int64>()
    let dimCount = HashMap<String, Int64>()
    let dimById = HashMap<String, ConfDimension>()
    for (f in findings) {
        let d = flawDimension(f.kind)
        let did = dimensionId(d)
        dimById[did] = d
        match (dimPen.get(did)) {
            case Some(v) => dimPen[did] = v + flawWeight(f.kind)
            case None => dimPen[did] = flawWeight(f.kind)
        }
        match (dimCount.get(did)) {
            case Some(v) => dimCount[did] = v + 1
            case None => dimCount[did] = 1
        }
    }
    let nFilesDim = Int64(graph.files.size)
    let dims = ArrayList<(ConfDimension, Int64, Int64, Int64)>()
    for ((did, pen) in dimPen) {
        match (dimById.get(did)) {
            case Some(d) =>
                var cnt: Int64 = 0
                match (dimCount.get(did)) {
                    case Some(v) => cnt = v
                    case None => ()
                }
                dims.add((d, pen, cnt, confidenceScore(pen, nFilesDim)))
            case None => ()
        }
    }
    insertionSortBy(dims, { a, b =>
        if (a[1] != b[1]) { return a[1] > b[1] }
        return dimensionId(a[0]) < dimensionId(b[0])
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
                            astNote + truncatedNote, nFiles, byKind, files, dims)
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
