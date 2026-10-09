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

/// 一处符号声明。
public struct SymDecl {
    public let kind: SymKind
    public let name: String
    public let line: Int64

    public init(kind: SymKind, name: String, line: Int64) {
        this.kind = kind
        this.name = name
        this.line = line
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
    /// fileA 的 import 解析到 fileB
    public let importEdges: ArrayList<(String, String)>
    /// fileA 里有 fileB 所定义符号的标识符（weight = 命中的不同符号数）
    public let refEdges: ArrayList<(String, String, Int64)>
    /// 文件数超上限被截断（总量照数，样本截断 —— 与引擎其它披露同一纪律）
    public let truncated: Bool
    /// 因超限/无法读取而跳过的文件数
    public let skipped: Int64
    /// 被当作标识符用过（**非声明位置**）的符号名集合。**不进任何 JSON 出口**——
    /// 供符号级孤儿检测（confidence_detect.detectOrphans）使用。
    /// 同文件内的使用也算（私有 helper 只要在本文件被调用过就不算孤儿）。
    public let referencedNames: HashSet<String>
    /// 未解析调用（幻觉 API）：file → (函数名 → 首现行号)。
    /// 自由函数调用、名字全仓无定义、非内建、非接收者调用。
    public let unresolvedCalls: ArrayList<(String, String, Int64)>
    /// 未使用 import：(file, 模块名, import 行号)。
    public let unusedImports: ArrayList<(String, String, Int64)>

    public init(root: String, files: ArrayList<FileEntry>,
                importEdges: ArrayList<(String, String)>,
                refEdges: ArrayList<(String, String, Int64)>,
                truncated: Bool, skipped: Int64,
                referencedNames: HashSet<String>,
                unresolvedCalls: ArrayList<(String, String, Int64)>,
                unusedImports: ArrayList<(String, String, Int64)>) {
        this.root = root
        this.files = files
        this.importEdges = importEdges
        this.refEdges = refEdges
        this.truncated = truncated
        this.skipped = skipped
        this.referencedNames = referencedNames
        this.unresolvedCalls = unresolvedCalls
        this.unusedImports = unusedImports
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
