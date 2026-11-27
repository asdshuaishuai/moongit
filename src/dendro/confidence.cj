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
package cambium.dendro

import std.collection.*
import std.convert.*
import cambium.util.*
import cambium.graph.*

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
            case UnresolvedCall => "Unresolved call (library API, typo, or hallucinated?)"
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
            case UnresolvedCall => "未解析调用"
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
        // 未解析的裸调用 = 「全仓没有该名字的定义」。实测精度接近 0（探针工程抽 20 条 0 真；
        // 引擎仓抽 6 条 0 真；deepDolphin 152 条里没有一条查实是编造）：几乎全是库 / 框架调用。
        // 按「提示去核对」的强度定权，不再与 duplicate-body / high-complexity 这些查实的事实同级——
        // 原先权重 8 时它在 deepDolphin 占列出罚分的 34%，整个分数被一类零命中的疑点带着走。
        case UnresolvedCall => 3
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
/// 魔法数字：函数体内裸数字字面量达到该数才报。AST 路径与词法路径
/// **共用这一个常量**（判据与证据文案都从它派生）——各写一份必然漂移，
/// 症状是同一函数在两条路径下一条报一条不报（G7）
public let CONF_MAGIC_NUMBERS: Int64 = 3
/// 注释掉的代码：一个文件里「长得像代码」的注释行达到该数才报
/// （单独一两行是正常注释，成片才是被禁用的代码残留）
public let CONF_COMMENTED_CODE_LINES: Int64 = 3
/// 圈复杂度阈值（McCabe 1976；超过即报）——决策路径爆炸的统计预测器
public let CONF_COMPLEXITY: Int64 = 10
/// 参数个数阈值：超过即报 God 签名（API 设计缺失的信号）
public let CONF_PARAMS: Int64 = 5
/// 混合职责：既有文件 I/O、又至少有这么多个决策点才报
/// （「含 for / match 就算计算逻辑」会把每个读文件的循环都报上——实测引擎仓 78 个文件报 77 条）
public let CONF_MIXED_DECISIONS: Int64 = 5
/// 近重复：归一化后的函数体至少这么长才比较（两行的 getter 天然相同，不是复制粘贴）
public let CONF_NEAR_DUP_MIN_BYTES: Int64 = 120
/// 重复体（AST 路径）：去注释 / 空白后的体至少这么长（原先是函数里的字面量 120）
public let CONF_DUP_BODY_BYTES: Int64 = 120

/// 一条疑点：类别 + 位置 + 证据。证据必须自足（人不开编辑器就能判断）。
///
/// 【符号键（阶段二 A）】symId / qual 让疑点能挂到索引里的符号上——置信度分析、
/// 热力图、codegraph.db 靠它说同一个符号：
///   · symId  稳定 id，与 nodes.sid 同一个键、同一个格式（model.cj 的 symId：
///            `f:<相对路径>:<行>:<名字>`）；定位不到给 ""。
///   · qual   限定名（`Owner.name`，顶层符号就是 name）；定位不到给 ""。
/// 挂靠规则见 attachSymbolKeys：先认「疑点位置上正好是同名声明」，否则认
/// 「疑点所在的最内层符号」（幻觉调用挂到调用它的函数上），都不是就留空——
/// 没有符号的疑点（文件级 import / 顶层 TODO）不编一个句柄。
public struct Finding {
    public let kind: FlawKind
    public let file: String
    public let line: Int64
    public let symbol: String
    public let evidence: String
    /// 挂靠符号的稳定 id（"" = 定位不到）。检测器不填，analyzeConfidence 统一挂。
    public let symId: String
    /// 挂靠符号的限定名（"" = 定位不到）。
    public let qual: String

    public init(kind: FlawKind, file: String, line: Int64, symbol: String, evidence: String) {
        this(kind, file, line, symbol, evidence, "", "")
    }

    init(kind: FlawKind, file: String, line: Int64, symbol: String, evidence: String,
         symId: String, qual: String) {
        this.kind = kind
        this.file = file
        this.line = line
        this.symbol = symbol
        this.evidence = evidence
        this.symId = symId
        this.qual = qual
    }

    /// 挂到某个符号上（struct 字段不可变，返回新值）。五参构造的 finding 一律
    /// symId / qual 为空，由 analyzeConfidence 在检测器全部跑完后统一调用。
    public func at(id: String, qual: String): Finding {
        return Finding(this.kind, this.file, this.line, this.symbol, this.evidence, id, qual)
    }
}

/// finding JSON 的键集（恒发、顺序固定）。**只有这一份清单**：唯一构造点
/// findingJson 按它出键，只读快照的出口（confidence query）按它投影，键集测试
/// 引它——三处各抄必漂移。
///   id / qual   挂靠符号键（定位不到为 ""，键照样在）
///   file / line 疑点位置（相对路径 + 1 起行号）
///   kind / weight / dim / label   类别 / 权重 / 维度 / 类别标签（label 随语言）
///   symbol      检测器给出的符号名（各检测器口径不同：孤儿 = 被声明的名字，
///               幻觉调用 = 被调用的名字……要与索引对账用 id / qual）
///   evidence    自足证据
public let FINDING_JSON_KEYS: Array<String> = [
    "id", "qual", "file", "line", "kind", "weight", "dim", "label", "symbol", "evidence"
]

/// finding JSON 的**唯一构造点**。所有出口都调它：confidenceJson（graph confidence
/// --json / MCP codegraph_confidence）、confidenceEmbedJson（HTML 内嵌与持久化的
/// confidence.json）、functionGraphData 的符号节点内嵌、confidence.db 的 findings 表
/// （按 FINDING_JSON_KEYS 的键出列）。别在任何出口手拼第二个 finding 对象——
/// 形状抄到第三份必漂（里程碑条目连栽过三次）；源码守卫
/// __lintFindingJsonHasOneProducer 钉住这一点。
public func findingJson(f: Finding, en: Bool): JsonValue {
    let o = Json.obj()
    Json.set(o, "id", Json.of(f.symId))
    Json.set(o, "qual", Json.of(f.qual))
    Json.set(o, "file", Json.of(f.file))
    Json.set(o, "line", Json.of(f.line))
    Json.set(o, "kind", Json.of(flawId(f.kind)))
    Json.set(o, "weight", Json.of(flawWeight(f.kind)))
    Json.set(o, "dim", Json.of(dimensionId(flawDimension(f.kind))))
    Json.set(o, "label", Json.of(flawLabel(f.kind, en)))
    Json.set(o, "symbol", Json.of(f.symbol))
    Json.set(o, "evidence", Json.of(f.evidence))
    return o
}

/// 给每条 finding 挂符号键（symId / qual）。检测器全部跑完后调一次。
///
/// 规则（先严后宽，都不中就留空）：
///   ① 疑点位置上正好是**同名声明**：file 相同、line 相同、name == finding.symbol
///      —— 孤儿 / 可疑命名 / 函数粒度信号 / 类型级信号都是这一类，挂到它自己；
///   ② 否则挂到**疑点所在的最内层符号**：声明行 ≤ 疑点行 ≤ 声明末行，取声明行
///      最靠后的那个（嵌套时最内层）。幻觉调用挂到调用它的函数上、未使用变量挂到
///      声明它的函数上——这样 `id` 可以直接拿去查索引：`index refs <id>`、
///      `SELECT … FROM sites WHERE src = (SELECT id FROM nodes WHERE sid = ?)`。
///   末行未知（endLine == 0）的符号不参与 ②：没有边界就不能说「在它里面」。
///
/// 与索引对得上是因为同源：两侧的符号都出自同一次 scanSource，id 由 SymDecl.id
/// 按同一个公式生成（confidence gen 先让 indexEnsureFresh 重建过期索引，所以两边
/// 看到的是同一份源码的同一版索引）。
func attachSymbolKeys(graph: CodeGraph, findings: ArrayList<Finding>): Unit {
    let byFile = HashMap<String, ArrayList<SymDecl>>()
    for (fe in graph.files) { byFile[fe.relPath] = fe.symbols }
    for (i in 0..findings.size) {
        let f = findings[i]
        var syms = ArrayList<SymDecl>()
        match (byFile.get(f.file)) {
            case Some(list) => syms = list
            case None => ()
        }
        var hit: Option<SymDecl> = None<SymDecl>
        // ① 同名声明
        for (s in syms) {
            if (s.line == f.line && s.name == f.symbol) {
                hit = Some(s)
                break
            }
        }
        // ② 最内层包含
        if (hit.isNone()) {
            var bestLine: Int64 = 0
            for (s in syms) {
                if (s.line <= f.line && s.endLine >= f.line && s.endLine > 0 && s.line >= bestLine) {
                    hit = Some(s)
                    bestLine = s.line
                }
            }
        }
        if (hit.isNone()) { continue }
        let s = hit.getOrThrow()
        findings[i] = f.at(s.id(f.file), s.qual)
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
    /// 有 finding 因「每文件每类上限」（CONF_MAX_PER_KIND_PER_FILE 及各检测器的
    /// 同族限流）被丢弃。真值来自**丢弃发生的判定点**（CapDropCounter），
    /// 不是拿截断后的结果集反推——「恰好 6 条」与「第 7 条被丢弃」在结果集里
    /// 同形，反推会把恰好达限误报成「超出已汇总」。
    public let cappedKind: Bool
    /// 有 finding 因总量上限（CONF_MAX_FINDINGS）被丢弃（同上：判定点置位）。
    public let cappedTotal: Bool
    /// 一共检出多少条（列出 + 总量截断 + 每文件每类上限丢弃）——findings.size 只是列出的那部分。
    public let findingsTotal: Int64
    /// 总罚分（全部检出的条目，含被上限丢弃的）；score 由它算，不由列出的条目算。
    public let penaltyTotal: Int64
    /// 分析覆盖面（走语法树的文件数、降级为词法的文件数、批失败、被剔除 / 丢弃的节点）。
    public let coverage: Coverage

    public init(root: String, score: Int64, findings: ArrayList<Finding>,
                astUsed: Bool, astNote: String,
                filesAnalyzed: Int64,
                byKind: ArrayList<(FlawKind, Int64)>,
                files: ArrayList<(String, Int64)>,
                dimensions: ArrayList<(ConfDimension, Int64, Int64, Int64)>,
                cappedKind!: Bool = false, cappedTotal!: Bool = false,
                findingsTotal!: Int64 = -1, penaltyTotal!: Int64 = -1,
                coverage!: Coverage = Coverage()) {
        this.root = root
        this.score = score
        this.findings = findings
        this.astUsed = astUsed
        this.astNote = astNote
        this.filesAnalyzed = filesAnalyzed
        this.byKind = byKind
        this.files = files
        this.dimensions = dimensions
        this.cappedKind = cappedKind
        this.cappedTotal = cappedTotal
        // -1 = 调用方没给（测试夹具直接构造报告）：按「列出的就是全部」理解
        this.findingsTotal = if (findingsTotal < 0) { Int64(findings.size) } else { findingsTotal }
        var pen: Int64 = 0
        if (penaltyTotal < 0) {
            for (f in findings) { pen += flawWeight(f.kind) }
        } else {
            pen = penaltyTotal
        }
        this.penaltyTotal = pen
        this.coverage = coverage
    }
}

/// 分析覆盖面。astNote 里那段话文字版给读报告的人，这一份结构化的给程序（客户端不必解析散文）。
/// 全部字段恒发；引擎没说清的用 -1 / 空表，**不回落成 0**（0 的含义是「确实没有」）。
public class Coverage {
    /// 走语法树的文件数；astUsed=false 时为 0
    public let astFiles: Int64
    /// 因语言没有 tree-sitter 语法而降级为词法级的文件数
    public let lexicalFiles: Int64
    /// ast-grep 跑了几批（0 = 没跑）
    public let astBatchesTotal: Int64
    /// 其中失败的批数
    public let astBatchesFailed: Int64
    /// 本版 ast-grep 不认、已从规则里剔除的节点种类（"swift.struct_declaration"）
    public let kindsDropped: ArrayList<String>
    /// 签名不成其为签名、已丢弃的函数节点数（tree-sitter 错误恢复的产物）
    public let nodesDropped: Int64
    /// 语法树可用时才有的信号里，本次没有产出的类别（降级时词法路径给不出的那 7 类）
    public let kindsUnavailable: ArrayList<String>

    public init(astFiles: Int64, lexicalFiles: Int64, astBatchesTotal: Int64, astBatchesFailed: Int64,
                kindsDropped: ArrayList<String>, nodesDropped: Int64,
                kindsUnavailable: ArrayList<String>) {
        this.astFiles = astFiles
        this.lexicalFiles = lexicalFiles
        this.astBatchesTotal = astBatchesTotal
        this.astBatchesFailed = astBatchesFailed
        this.kindsDropped = kindsDropped
        this.nodesDropped = nodesDropped
        this.kindsUnavailable = kindsUnavailable
    }

    public init() {
        this(0, 0, 0, 0, ArrayList<String>(), 0, ArrayList<String>())
    }
}

/// 只有语法树可用时才产出的信号类别（词法路径给不出的）。降级 / 批失败时这些类别整类缺失——
/// 原来的降级说明只提「吞错与重复体」，把另外 5 类漏掉了：读报告的人以为那些类别「没有疑点」。
func astOnlyKindsUnavailable(partial: Bool): ArrayList<String> {
    let out = ArrayList<String>()
    for (k in [SwallowedError, DuplicateBody, UnusedVariable, EmptyType, GodClass, LockImbalance, LockUnknownCall]) {
        out.add(flawId(k))
    }
    return out
}

func copyStrings(src: ArrayList<String>): ArrayList<String> {
    let out = ArrayList<String>()
    for (x in src) { out.add(x) }
    return out
}

/// 每文件每类限流的**丢弃计数器**——ConfidenceReport.cappedKind 的唯一真值来源。
/// analyzeConfidence 创建一份传给所有带限流的检测器；检测器只在
/// 「这一条因超限被丢弃」的判定行递增，绝不拿截断后的 findings 反推。
/// （跨函数累积可变状态的既有通道先例：build.cj 的 ReferVar。）
public class CapDropCounter {
    public var kindDrops: Int64
    /// 被每文件每类上限丢弃的（类别, 文件）与罚分合计——丢弃发生点逐条累计。
    /// 【为什么要记】上限只管「列不列出」，不管「罚多少分」。原实现只记个数，
    /// 分数在截断之后按列出的条目求和：一个文件里第 7 条孤儿起不罚分（文件越烂越不扣），
    /// 全量 400 条之后的也全部不罚（仓库越大、疑点越多，分数反而越稳）。
    public let droppedKinds: ArrayList<FlawKind>
    public let droppedFiles: ArrayList<String>
    public var droppedWeight: Int64
    public init() {
        kindDrops = 0
        droppedKinds = ArrayList<FlawKind>()
        droppedFiles = ArrayList<String>()
        droppedWeight = 0
    }

    /// 丢弃发生点的唯一入口（所有带每文件上限的检测器都走这里）。
    public func drop(kind: FlawKind, file: String): Unit {
        kindDrops += 1
        droppedKinds.add(kind)
        droppedFiles.add(file)
        droppedWeight += flawWeight(kind)
    }
}

// MARK: - 主流程

/// 分析入口。`useAst=false` 或 ast-grep 不可用时走纯词法。
public func analyzeConfidence(graph: CodeGraph, useAst: Bool): ConfidenceReport {
    let findings = ArrayList<Finding>()
    var astNodes = ArrayList<AstNode>()
    var astUsed = false
    var astNote = ""
    // 覆盖面（结构化披露，见 Coverage）
    var cov = Coverage()

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
                // 本版 ast-grep 不认的节点种类：已剔除（否则整份规则被拒），覆盖面少了哪几种节点要说清
                if (AST_DROPPED_KINDS.size > 0) {
                    astNote += "；本版 ast-grep 不认的节点种类已剔除：" + joinStrings(AST_DROPPED_KINDS.toArray(), "、")
                }
                // 解析异常揉出来的假函数节点：已丢弃（通常是缺分号的宏），丢弃了几条要说清
                if (AST_DROPPED_NODES > 0) {
                    astNote += "；${AST_DROPPED_NODES} 个签名不成其为签名的函数节点已丢弃（tree-sitter 错误恢复的产物）"
                }
                // 有文件没走成语法树（批失败 / 语言没有语法）⇒ 那些文件的 AST 独有信号整类缺失，逐类说清；
                // 全部文件都走成了就什么都不缺——不能把「7 类」挂在一份没有降级的报告上
                let missing = if (AST_FAILED_BATCHES > 0 || fallbackFiles > 0) {
                    astOnlyKindsUnavailable(true)
                } else {
                    ArrayList<String>()
                }
                if (missing.size > 0) {
                    astNote += "；受影响的文件上这些类别的信号缺失：" + joinStrings(missing, "、")
                }
                cov = Coverage(astFiles, fallbackFiles, AST_TOTAL_BATCHES, AST_FAILED_BATCHES,
                    copyStrings(AST_DROPPED_KINDS), AST_DROPPED_NODES, missing)
            case None =>
                // 三种成因分开披露：工具没装 / 装了但语言无覆盖 / 工具跑了但
                // 批次全败。原版把后两种混成一句「语言无语法覆盖」——全批失败
                // （规则/环境异常）被说成覆盖边界，读者会误以为一切正常。
                // 缺失的类别逐类列全（原先只说「吞错与重复体」，另外 5 类没提——
                // 读报告的人会以为那些类别「没有疑点」）。
                var degradedWhy = "未安装 ast-grep（`brew install ast-grep` 可获得 tree-sitter 级覆盖）"
                if (findAstGrep().isSome()) {
                    if (AST_TOTAL_BATCHES > 0) {
                        degradedWhy = "ast-grep 已运行，但全部 ${AST_TOTAL_BATCHES} 个批次失败（规则或环境异常）"
                        cov = Coverage(0, Int64(graph.files.size), AST_TOTAL_BATCHES, AST_TOTAL_BATCHES,
                            ArrayList<String>(), AST_DROPPED_NODES, astOnlyKindsUnavailable(true))
                    } else {
                        degradedWhy = "ast-grep 已安装，但本次全部文件的语言都无 tree-sitter 语法（如纯仓颉仓库）"
                        cov = Coverage(0, Int64(graph.files.size), 0, 0,
                            ArrayList<String>(), 0, astOnlyKindsUnavailable(true))
                    }
                } else {
                    cov = Coverage(0, Int64(graph.files.size), 0, 0,
                        ArrayList<String>(), 0, astOnlyKindsUnavailable(true))
                }
                astNote = "语法树不可用：" + degradedWhy + "——"
                    + "已降级为词法级分析；函数粒度信号改由词法路径近似（长度/嵌套/魔法数/空体），"
                    + "以下 " + cov.kindsUnavailable.size.toString() + " 类信号整类缺失："
                    + joinStrings(cov.kindsUnavailable.toArray(), "、")
        }
    } else {
        cov = Coverage(0, Int64(graph.files.size), 0, 0, ArrayList<String>(), 0, astOnlyKindsUnavailable(true))
        astNote = "按调用方要求跳过语法树（--no-ast），仅词法级分析；以下 "
            + cov.kindsUnavailable.size.toString() + " 类信号整类缺失："
            + joinStrings(cov.kindsUnavailable.toArray(), "、")
    }

    // ── ① 孤儿符号：定义了，全仓无引用（图数据直接支撑）──
    // kindCap：每文件每类限流的丢弃计数（cappedKind 真值来源），传入所有
    // 带限流的检测器——只在丢弃发生的判定行递增（见 CapDropCounter 注释）。
    let kindCap = CapDropCounter()
    detectOrphans(graph, findings, kindCap)
    // ── ② 命名可疑 ──
    detectSuspiciousNames(graph, findings, kindCap)
    // ── ③ TODO 残留（按文件计数）──
    detectTodos(graph, findings)
    // ── ④ 函数粒度信号：AST 节点 + 词法近似 ──
    // AST 覆盖得到时用 AST；词法路径**始终**补跑 AST 覆盖不到的语言
    // （如纯仓颉仓库 / 混合仓库里的仓颉文件），否则这些语言只剩「超长函数」。
    if (astUsed) {
        detectFromAst(astNodes, findings, kindCap)
    }
    detectLexicalFunctionSignals(graph, findings, astUsed, kindCap)
    // ── ⑤ 重复函数体（同体哈希，需 AST 的准确边界）──
    if (astUsed) {
        detectDuplicateBodies(astNodes, findings)
    }
    // ── ⑥ 幻觉调用 / ⑦ 未使用 import / ⑧ 注释掉的代码 ──
    // 图数据直接支撑：unresolvedCalls / unusedImports 在 buildGraph 两遍扫描时产出
    detectUnresolvedCalls(graph, findings, kindCap)
    detectUnusedImports(graph, findings, kindCap)
    detectCommentedCode(graph, findings)
    // ── ⑨ 变量级（未使用变量，需 AST 函数边界）──
    if (astUsed) {
        detectUnusedVariables(astNodes, findings, kindCap)
    }
    // ── ⑩ 类型级（空类型 / 上帝类，需 AST type 节点）──
    if (astUsed) {
        detectTypeSignals(astNodes, findings)
    }
    // ── 语义层检测（圈复杂度/参数滥用/不可达代码/混合职责/近重复）──
    // ⚠️ 不放在 if (astUsed) 内——纯仓颉仓 astUsed=false，但这些检测全走词法
    try {
        // 近重复：语法树可用时由 duplicate-body 报（同一件事不罚两次）
        detectSemanticIssues(graph, findings, kindCap, nearDup: !astUsed)
    } catch (e: Exception) {
        Log.warn("语义层检测异常（已跳过）: ${e.message}")
    }
    // ── ⑪ 指针风险（C/C++：malloc/free 配对、返回栈地址）──
    detectPointerRisks(graph, findings)
    // ── ⑫ 并发链路/细节（全局可变、锁不平衡、持锁调用）──
    detectConcurrencyRisks(graph, astNodes, astUsed, findings, kindCap)

    // 挂符号键：全部检测器跑完后统一做一次（检测器只管产出 finding 的五元组，
    // 符号键的挂靠规则只有 attachSymbolKeys 一份）。在排序之前——全序的最后一维
    // 要用到 id。
    attachSymbolKeys(graph, findings)
    // 排序：全序（见 sortFindings），确定性 + 重要的在前
    sortFindings(findings)

    // ── 总量与各聚合表：在**任何截断之前**算。上限只管「列不列出」，不管「罚多少分」——
    // 分数、按类别 / 按文件 / 按维度的计数都吃全部检出的条目（列出的 + 总量截断掉的 +
    // 每文件每类上限丢弃的）。原先全在截断之后算：deepDolphin 检出 1746 条只按 400 条求和，
    // byKind 里连 low-weight 类别都看不见。
    let all = ArrayList<Finding>()
    for (f in findings) { all.add(f) }
    var di: Int64 = 0
    while (di < Int64(kindCap.droppedKinds.size)) {
        all.add(Finding(kindCap.droppedKinds[di], kindCap.droppedFiles[di], 0, "", ""))
        di += 1
    }
    let findingsTotal = Int64(all.size)
    var penaltyTotal: Int64 = 0
    for (f in all) { penaltyTotal += flawWeight(f.kind) }

    // 每类计数
    // enum 作 HashMap 键需要 Hashable 派生；这里用 id 字符串当键（零依赖）
    let counts = HashMap<String, Int64>()
    let kindById = HashMap<String, FlawKind>()
    for (f in all) {
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
    for (f in all) {
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
    for (f in all) {
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

    // ── 总量截断：只影响「列不列出」，披露进 astNote，不静默
    var truncatedNote = ""
    // ⚠️ cappedTotal 在**丢弃发生的位置**置位——不是拿 findings.size >= 上限反推：
    // 恰好 400 条产出时并不发生截断，反推会把「刚好达限」误报成「已截断」。
    var cappedTotal = false
    if (Int64(findings.size) > CONF_MAX_FINDINGS) {
        let extra = Int64(findings.size) - CONF_MAX_FINDINGS
        while (Int64(findings.size) > CONF_MAX_FINDINGS) {
            findings.remove(at: findings.size - 1)
        }
        truncatedNote = "；共检出 ${findingsTotal} 条，另有 ${extra} 条低权重疑点未列出（按权重截断；罚分已计入总分）"
        cappedTotal = true
    }
    if (kindCap.kindDrops > 0) {
        truncatedNote += "；每文件每类上限丢弃 ${kindCap.kindDrops} 条（罚分 ${kindCap.droppedWeight}，已计入总分）"
    }

    // 分数：由「惩罚总量」与「文件数」算的**密度分**（见 confidenceScore）。
    // ⚠️ 旧公式 `100 − 惩罚/√文件数` 与仓库规模相关：惩罚随文件数线性增长、
    // 而 √ 增长更慢 ⇒ 大仓库必然趋近 0（实测 276 文件的仓库、每文件仅 4.3 点却只得 28 分；
    // 而另一处每文件 15 点的仓库也是 0 —— 同一个分数说不出谁更差）。
    let nFiles = Int64(graph.files.size)
    let score = confidenceScore(penaltyTotal, nFiles)

    return ConfidenceReport(graph.root, score, findings, astUsed,
                            astNote + truncatedNote, nFiles, byKind, files, dims,
                            cappedKind: kindCap.kindDrops > 0, cappedTotal: cappedTotal,
                            findingsTotal: findingsTotal, penaltyTotal: penaltyTotal,
                            coverage: cov)
}

/// findings 的**全序**排序（`AGENTS.md` 契约：同一仓库两次运行逐字节一致）。
/// ⚠️ 原比较器只按 (权重, file, line)：权重并列且 file:line 相同时判等，
/// 于是依赖**输入顺序** —— 而输入来自 `runAstGrep` 里按语言分组的 HashMap 迭代，
/// 顺序不确定。实测 Canopy 两次运行 findings 的 (long-function, deep-nesting)
/// 对在同一函数首行翻转（两者权重都是 4）。补足全序：
/// 权重↓ → file↑ → line↑ → flawId↑ → symbol↑ → id↑。
/// 最后一维是符号键：同一位置上两个同名声明（重载各挂各的 id）不许再判等。
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
    if (a.symbol != b.symbol) { return a.symbol < b.symbol }
    return a.symId < b.symId
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
