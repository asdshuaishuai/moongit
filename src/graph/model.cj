// graph/model.cj — 代码图谱的数据模型。
//
// 【为什么是仓颉 ADT 而不是字符串枚举】
// 符号种类、边种类是整条流水线共享的**语义轴**：提取规则写它、
// 树渲染 match 它、JSON 序列化 match 它、影响面分析 match 它。
// 仓颉 enum（代数数据类型）+ 穷尽 match 让「加一种符号忘了配渲染」
// 变成**编译期**错误 —— 这正是仓颉 AI 原生设计的用武之地：
// 静态类型 + 模式匹配把「确定性事实」这件事做进语言里，
// agent 消费这些事实时不需要再猜字段含义。
//
// 【边界】本包只依赖 util（词法工具 + JSON + 路径），不碰 kernel/git ——
// 图谱是对**工作区文件**的确定性扫描，与进度库、注册表完全解耦。
package moongit.graph

import std.collection.*
import moongit.util.*

// MARK: - 符号种类（ADT）

/// 源码符号的语义种类。穷尽 match 的四个消费方：
/// extract.cj（规则表）、tree.cj（树渲染）、json（序列化）、arch.cj（统计）。
public enum SymKind {
    | Func        // 函数 / 方法 / fn / def / function
    | Class       // class（含 kotlin data class 的 name 归位）
    | Struct      // struct（含 go `type X struct`）
    | Interface   // interface / protocol / trait
    | Enum        // enum
    | Extension   // extension / impl（对既有类型的扩展）
    | TypeAlias   // typealias / type / typedef
}

/// 种类的稳定标识（进 JSON 契约，改名即破坏契约 —— 别动）。
public func symKindId(k: SymKind): String {
    match (k) {
        case Func => "func"
        case Class => "class"
        case Struct => "struct"
        case Interface => "interface"
        case Enum => "enum"
        case Extension => "extension"
        case TypeAlias => "typealias"
    }
}

/// 人类可读标签（zh）。
/// ⚠️ 当前**无调用方**：树/文本输出用的是 `symKindId`（语言中立的短标识，与 JSON 契约同名）。
/// 保留它只为 SymKind 的人读镜像 —— **不要**再写「树/文本输出用」这类没兑现的注释。
public func symKindLabel(k: SymKind): String {
    match (k) {
        case Func => "函数"
        case Class => "类"
        case Struct => "结构体"
        case Interface => "接口"
        case Enum => "枚举"
        case Extension => "扩展"
        case TypeAlias => "类型别名"
    }
}

// MARK: - 实体

/// 符号的稳定 id：`f:<relPath>:<line>:<name>`（与 HTML/SQLite 的节点键同一格式）。
///
/// 「稳定」的含义：同一份源码两次索引得到同一个 id（不含自增整数、不含迭代序），
/// 所以 agent 可以把 id 当句柄存下来回传（`index query <id>` / `index refs <id>`）。
/// 行号是 id 的一部分 ⇒ 符号上移/下移一行 id 就变——这是**如实**的：
/// 词法级索引无法给出跨编辑恒定的身份，宁可在 id 里带着可核验的坐标，
/// 也不编一个看起来恒定、实际会漂的哈希。
public func symId(file: String, line: Int64, name: String): String {
    return "f:" + file + ":" + line.toString() + ":" + name
}

/// 一处符号声明。
///
/// 【三参构造器保留】`SymDecl(kind, name, line)` 是既有调用形态，新字段全带默认值——
/// 只关心「叫什么、在哪一行」的旧消费方零改动。
///
/// 【成员级字段】owner/qual/endLine/col/sig/visibility/declOnly 让符号从
/// 「文件里出现过一个名字」升级为「哪个类型的哪个成员、占哪些行、长什么样」：
///   · owner     外层类型限定的**限定名**（"" = 顶层）。extension/extend/impl 体的
///               成员以被扩展类型为 owner；Go 接收者方法以接收者类型为 owner。
///   · qual      owner.name（顶层符号 qual == name）——同名成员的**消歧键**。
///   · endLine   声明的最后一行（花括号语言 = 闭括号行；Python = 缩进体末行；
///               无体声明 = 签名末行）；0 = 未知。
///   · col       声明名在 line 行**原始源码**里的 1 起字符列；0 = 未知。
///   · sig       签名文本（声明起点到函数体 `{` 之前，注释剥除、空白折叠），
///               至多 SIG_MAX_BYTES 字节；"" = 不可得。
///   · visibility public|private|protected|internal|package|""（未指明）。
///   · declOnly  只有声明没有体：C/C++ 原型、接口/抽象方法签名、TS 重载签名。
///               同一工程里另有同语言同 qual 的定义时，它作为该定义的「声明处」
///               呈现（defs[].decls），不再单独算一个定义。
public struct SymDecl {
    public let kind: SymKind
    public let name: String
    public let line: Int64
    public let owner: String
    public let qual: String
    public let endLine: Int64
    public let col: Int64
    public let sig: String
    public let visibility: String
    public let declOnly: Bool
    /// 同文件内「同一行、同一个名字」的第几个符号：1 = 首个，≥2 = 其后同名者。
    /// id 的唯一性靠它——同文件同 (line, name) 的第 2 个起在 id 后追加 `#2`/`#3`。
    /// 不进任何 JSON 出口。
    public let dup: Int64

    public init(kind: SymKind, name: String, line: Int64) {
        this(kind, name, line, "", 0, 0, "", "", false)
    }

    public init(kind: SymKind, name: String, line: Int64, owner: String,
                endLine: Int64, col: Int64, sig: String, visibility: String,
                declOnly: Bool) {
        this(kind, name, line, owner, endLine, col, sig, visibility, declOnly, 1)
    }

    init(kind: SymKind, name: String, line: Int64, owner: String,
         endLine: Int64, col: Int64, sig: String, visibility: String,
         declOnly: Bool, dup: Int64) {
        this.kind = kind
        this.name = name
        this.line = line
        this.owner = owner
        this.qual = if (owner.isEmpty()) { name } else { owner + "." + name }
        this.endLine = endLine
        this.col = col
        this.sig = sig
        this.visibility = visibility
        this.declOnly = declOnly
        this.dup = dup
    }

    /// 稳定 id（见 symId）。同文件同 (line, name) 的第 2 个起带 `#n` 后缀。
    public func id(file: String): String {
        let base = symId(file, this.line, this.name)
        if (this.dup <= 1) {
            return base
        }
        return base + "#" + this.dup.toString()
    }
}

/// 签名文本的字节上限（截断走 safeSlice，不切 UTF-8）。
public let SIG_MAX_BYTES: Int64 = 240

/// 一处调用点（scanSource 在**剥过注释与字符串**的代码上逐行采集）。
///
/// `receiver`：0 = 无接收者（自由调用 `name(`）；
///             1 = 实例接收者（`expr.name(` / `expr->name(` / `expr::name(`，接收者文本首字母小写）；
///             2 = 类型限定（`Type.name(` / `Type::name(`，接收者文本首字母大写）。
/// `receiverText`：紧邻分隔符之前的那个标识符（原样，不改写）。
/// `caller`：**内层被索引函数**在 `SourceFacts.symbols` 里的下标；-1 = 不在任何
///            被索引函数体内（属性初始化器、类体直接初始化、模块级代码）。
/// 内建的 `print(` / `println(` 这类**照记**——它们是不是内建由解析阶段按语言判定
/// （见 resolve.cj），扫描阶段不做名字白名单。
public struct CallSite {
    public let name: String
    public let line: Int64
    public let col: Int64
    public let receiver: Int64
    public let receiverText: String
    public let caller: Int64

    public init(name: String, line: Int64, col: Int64, receiver: Int64,
                receiverText: String, caller: Int64) {
        this.name = name
        this.line = line
        this.col = col
        this.receiver = receiver
        this.receiverText = receiverText
        this.caller = caller
    }
}

/// 一处调用点的**解析结果**（工程级解析之后；codegraph.db 的 sites 表每行一条）。
///
/// caller/dst 都是稳定 id（`f:…`），"" = 无：caller 为空 = 该调用点不在任何被
/// 索引函数体内；dst 为空 = 未解析（全工程没有该名字的定义，且不是内建）。
/// tier = direct | resolved | guessed（未解析为 ""）。
/// dstFile 是 dst 所在文件（depth 截断时判「被调方在不在数据域里」用；不进 JSON）。
public struct ResolvedSite {
    public let file: String
    public let line: Int64
    public let col: Int64
    public let receiver: Int64
    public let receiverText: String
    public let name: String
    public let caller: String
    public let dst: String
    public let tier: String
    public let dstFile: String

    public init(file: String, line: Int64, col: Int64, receiver: Int64,
                receiverText: String, name: String, caller: String,
                dst: String, tier: String, dstFile!: String = "") {
        this.file = file
        this.line = line
        this.col = col
        this.receiver = receiver
        this.receiverText = receiverText
        this.name = name
        this.caller = caller
        this.dst = dst
        this.tier = tier
        this.dstFile = dstFile
    }
}

/// 单个源码文件的静态事实（一次读取全部得出）。
public struct FileEntry {
    /// 相对项目根的路径（图谱内的一切引用都用它当 id）
    public let relPath: String
    /// 语言标识：swift / cangjie / ts / python / go / rust / java / kotlin / c
    public let lang: String
    /// 总行数（架构图的规模注记用）
    public let lines: Int64
    public let symbols: ArrayList<SymDecl>
    /// import 的模块名（首段）：`import moongit.util` → `moongit`；
    /// `from x import y` → `x`；`use a::b` → `a`；go `import "a/b/c"` → `c`
    public let imports: ArrayList<String>
    /// 与 imports 平行的行号（未使用 import 的证据定位）
    public let importLines: ArrayList<Int64>

    public init(relPath: String, lang: String, lines: Int64,
                symbols: ArrayList<SymDecl>, imports: ArrayList<String>,
                importLines: ArrayList<Int64>) {
        this.relPath = relPath
        this.lang = lang
        this.lines = lines
        this.symbols = symbols
        this.imports = imports
        this.importLines = importLines
    }
}

// MARK: - 图

/// 代码图谱：文件事实 + 三类关系。
///
/// 【关系的三种粒度，如实说】
///   · contains  文件 → 符号：确定性（词法位置即事实）
///   · import    文件 → 文件：经模块名启发式解析（`import a.b` → 命中路径含 a 的文件）
///   · reference 文件 → 文件：**词法级**引用（标识符出现在别处），不是语义调用图。
///     零依赖约束下不做类型解析；粒度是文件级，agent 拿到的是「改这里会读到那里」
///     的候选集，不是编译器保证的调用闭包 —— 这个边界写进契约，不包装。
public class CodeGraph {
    public let root: String
    public let files: ArrayList<FileEntry>
    /// fileA 的 import 解析到 fileB。只收「剥后仍在」的 import 行——
    /// scanSource 的 import 检测用原始行（行锚定），字符串里的
    /// `from x import y` 会被当成真 import；行号不在剥后集合里的一律丢弃。
    public let importEdges: ArrayList<(String, String)>
    /// fileA 里有 fileB 所定义符号的标识符（weight = 命中的不同符号数）
    public let refEdges: ArrayList<(String, String, Int64)>
    /// 架构口径的引用边：**架构上可能成立的**词法引用（weight = 命中的不同符号数）。
    ///
    /// 【为什么要有两份——引用语义 vs 架构语义】
    /// refEdges 是「引用语义」：剥后标识符命中他文件定义即计，服务影响面、
    /// 孤儿检测辅助与 fullGraphJson/overview 的 referenceEdges（对外契约，维持现状）。
    /// 它的假边形态对架构聚合是灾难：引擎自身 9/9 模块对「全违规」，实测成因全部
    /// 是同名噪音而非真依赖（paths.cj 的 doc 注释提到 stripCode、strx.cj 每包
    /// 一份的合法重名 isBlank、泛型占位符 T 撞 lang.cj 的翻译函数 T、局部变量
    /// size/t 撞他包成员方法……）。archRefEdges 只认架构上可能成立的跨模块依赖：
    ///   ① 目标是**顶格且公开**的声明（cangjie/swift/ts/rust/java 的 public/open/
    ///      export/pub；go 的首字母大写导出；python 的非下划线前缀）——语言可见性
    ///      语义下跨包引用只能指向公开符号，私有/成员方法的「命中」100% 是撞名；
    ///   ② 定义分布在 **>1 个模块**的同名符号（跨模块歧义）不产生边——词法无法
    ///      分辨引用的是哪一份，宁可漏边不造假边（strx.cj 同族）；
    ///   ③ 接收者调用（a.b 的前导点）豁免——方法归属需要类型信息，词法不可判；
    ///   ④ 声明行的**泛型类型参数**（`func f<T>` 的 T）豁免——那是声明不是引用；
    ///   ⑤ **泛型实参位置**（前导 `<`，如 `Option<T>` / `wrapFn<Int64>`）豁免——
    ///      类型实参的归属同样需要类型信息；lock.cj 函数体内的 `Option<T>` 曾
    ///      因此残留 kernel→cli 假边。比较运算符 `a < b` 的 b 右侧是变量/
    ///      字面量，误豁免的代价是漏边不是假边。
    /// 剥注释+字符串的口径与 refEdges 同源（同一次扫描的 stripCode 文本）。
    /// **不进任何 JSON 出口**：仅 buildArch（模块聚合/治理信号/drilldown）消费。
    public let archRefEdges: ArrayList<(String, String, Int64)>
    /// 文件数超上限被截断（总量照数，样本截断 —— 与引擎其它披露同一纪律）
    public let truncated: Bool
    /// 因超限/无法读取而跳过的文件数
    public let skipped: Int64
    /// 被当作标识符用过（**非声明位置**）的符号名集合。**不进任何 JSON 出口**——
    /// 供符号级孤儿检测（confidence_detect.detectOrphans）使用。
    /// 同文件内的使用也算（私有 helper 只要在本文件被调用过就不算孤儿）。
    public let referencedNames: HashSet<String>
    /// 未解析调用（幻觉 API）：(file, 函数名, 首现行号)。
    /// **派生自解析后的调用点**（build.cj 的 unresolvedCallsFrom）：dst 为空的自由调用
    /// （没有同语言的定义、不是内建），且名字只在一个文件里出现。与 codegraph.db 的
    /// sites.dst = 0 同源；带接收者的未解析调用点留在 callSites 里，不进这份清单。
    public let unresolvedCalls: ArrayList<(String, String, Int64)>
    /// 未使用 import：(file, 模块名, import 行号)。
    public let unusedImports: ArrayList<(String, String, Int64)>
    /// 因超限被跳过的文件数（> GRAPH_MAX_FILE_BYTES）。**恒发**——「没扫描到」
    /// 与「这里没有文件」在响应里完全不同，缺这个键下游只能当成没有（M7）。
    public let oversizeSkipped: Int64
    /// 遍历时**读不出来**的目录（相对路径，根为空串；至多
    /// GRAPH_MAX_UNREADABLE_DIRS 条）。读不到的子树里的所有文件会静默
    /// 缺席——与「空目录」在图谱里完全同构（契约A：出口必须恒发
    /// unreadableDirs / unreadableDirsTruncated 披露这一事实）。
    public let unreadableDirs: ArrayList<String>
    /// 调用点的解析结果（工程级：扫描完全部文件后统一解析，见 resolve.cj）。
    /// 每 (调用点, 解析目标) 一条；未解析的调用点 dst 为 ""。
    /// 按全序排定（file ↑ → line ↑ → col ↑ → name ↑ → dst ↑），出口字节序确定。
    /// 函数级调用边（functionGraph.functionEdges / codegraph.db 的 edges 与 sites）
    /// 的**唯一数据源**——没有第二份「按行猜调用」的扫描。
    public let callSites: ArrayList<ResolvedSite>

    public init(root: String, files: ArrayList<FileEntry>,
                importEdges: ArrayList<(String, String)>,
                refEdges: ArrayList<(String, String, Int64)>,
                truncated: Bool, skipped: Int64,
                referencedNames: HashSet<String>,
                unresolvedCalls: ArrayList<(String, String, Int64)>,
                unusedImports: ArrayList<(String, String, Int64)>,
                oversizeSkipped: Int64,
                unreadableDirs: ArrayList<String>,
                archRefEdges: ArrayList<(String, String, Int64)>,
                callSites!: ArrayList<ResolvedSite> = ArrayList<ResolvedSite>()) {
        this.root = root
        this.files = files
        this.importEdges = importEdges
        this.refEdges = refEdges
        this.archRefEdges = archRefEdges
        this.truncated = truncated
        this.skipped = skipped
        this.referencedNames = referencedNames
        this.unresolvedCalls = unresolvedCalls
        this.unusedImports = unusedImports
        this.oversizeSkipped = oversizeSkipped
        this.unreadableDirs = unreadableDirs
        this.callSites = callSites
    }

    /// 符号名 → 定义处列表（同名符号可能多处定义，全部列出，不装作唯一）。
    public func symbolIndex(): HashMap<String, ArrayList<(String, SymDecl)>> {
        let idx = HashMap<String, ArrayList<(String, SymDecl)>>()
        for (f in files) {
            for (s in f.symbols) {
                match (idx.get(s.name)) {
                    case Some(list) =>
                        list.add((f.relPath, s))
                    case None =>
                        let list = ArrayList<(String, SymDecl)>()
                        list.add((f.relPath, s))
                        idx[s.name] = list
                }
            }
        }
        return idx
    }
}
