// graph/arch.cj — 技术架构图：模块聚合 + 分层判定 + 布局 + 四种渲染。
//
// 【参考了谁，没抄谁】
// pyreverse / madge / dependency-cruiser 的共同核心是
// 「目录/模块聚合依赖图 + 按语义分层」；archify（deepOrca 侧）验证了
// **单文件可交互 HTML** 是给人看的正确形态。我们没有照搬它的
// SVG + 手写布局，而是：
//   · 布局由引擎从事实**确定性计算**（分层列布局，同一仓库两次渲染逐像素一致）
//   · 渲染走 **Canvas 2D**（大量节点下平移/缩放比 SVG 重绘便宜得多）
//   · 零外部依赖：无字体 CDN、无 JS 库，双击离线可开
// agent 侧另有 mermaid / dot / json 三种静态出口（agent 点不了画布）。
//
// 【分层的诚实边界】层判定是**模块名的启发式**（util→基础、kernel→核心…），
// 不是依赖方向的拓扑论证。启发式判错的层不改变边的事实——
// 边才是事实，层是解读；两者在数据里分开存放。
package moongit.graph

import std.collection.*
import std.convert.*
import moongit.util.*

// MARK: - 分层

public let LAYER_COUNT: Int64 = 5

// MARK: - 泳道布局常量（引擎单一来源）
//
// 分层泳道布局的全部几何只允许写在这一处：layoutArch 摆卡片、archLaneRects
// 出泳道矩形（archJson 的 lanes / scene 的层框）都引用同一组常量——
// 任何一边改尺寸另两边不跟，画面就会「卡片出泳道」或「泳道框错位」，
// 且这种错位编译期发现不了（几何只在渲染时才可见）。
public let ARCH_CARD_W: Float64 = 220.0        // 模块卡片宽（固定，确定性）
public let ARCH_CARD_H: Float64 = 72.0         // 模块卡片高（名/统计/入出+不稳定条 三行）
public let ARCH_SLOT_W: Float64 = 266.0        // 卡片 + 水平间隙
public let ARCH_LANE_LABEL_W: Float64 = 150.0  // 泳道左端层标签区
public let ARCH_LANE_PAD_V: Float64 = 30.0     // 泳道上下留白（卡片上下各 30）
public let ARCH_LANE_GAP: Float64 = 16.0       // 相邻泳道间距
public let ARCH_MARGIN: Float64 = 36.0         // 画布外边距

public func layerName(layer: Int64, en: Bool): String {
    if (en) {
        match (layer) {
            case 0 => "Foundation"
            case 1 => "Core"
            case 2 => "Orchestration"
            case 3 => "Interface"
            case _ => "Other"
        }
    } else {
        match (layer) {
            case 0 => "基础层"
            case 1 => "核心层"
            case 2 => "编排层"
            case 3 => "接口层"
            case _ => "其他"
        }
    }
}

/// 包装目录：其下的第二段才是真正的模块名
func isWrapperDir(seg: String): Bool {
    let s = lowerAscii(seg)
    let names = ["src", "sources", "source", "lib", "libs", "pkg", "classes"]
    for (n in names) { if (s == n) { return true } }
    return false
}

/// 模块名 → 层（启发式词表；命中不了的进「其他」，不猜）
public func inferLayer(module: String): Int64 {
    let m = lowerAscii(module)
    let l0 = ["util", "utils", "common", "commons", "base", "foundation", "shared", "lib", "helper", "helpers"]
    let l1 = ["kernel", "core", "domain", "model", "models", "store", "storage", "engine", "graph", "entity", "entities"]
    let l2 = ["flow", "service", "services", "agent", "agents", "logic", "manager", "managers", "orchestrator", "worker", "workers", "usecase", "usecases"]
    let l3 = ["cli", "app", "ui", "api", "server", "mcp", "client", "web", "view", "views", "controller", "controllers", "cmd", "gateway", "entry", "main"]
    for (w in l0) { if (m == w) { return 0 } }
    for (w in l1) { if (m == w) { return 1 } }
    for (w in l2) { if (m == w) { return 2 } }
    for (w in l3) { if (m == w) { return 3 } }
    return 4
}

// MARK: - 职责分层（技术深度：入口/界面/服务/数据/存储/支撑）
//
// 【是什么】按**文件名职责词**把每个文件归入技术角色，聚出「职责视图」：
//   一个单包应用（所有文件在同一个目录模块里）在模块视图里只有一张卡、
//   零条边——那是一张目录结构图。职责视图回答的是技术架构问题：
//   入口在哪、界面几个、业务服务几个、数据/存储几层、谁依赖谁、
//   哪条依赖逆着分层方向走。
//
// 【边界，如实说】词法级近似：依据是文件名职责词，不是类型/语义分析。
//   归错的文件在卡片上看得见（panel 列出该角色全部文件），误归的代价是
//   「这张图上它站错了泳道」，不是数据损坏。规则表公开、可测试、可解释。
//
// 【确定性】纯函数：同路径 ⇒ 同角色。规则按优先级排序，先命中先归。

// 角色常量（泳道序 = 依赖健康方向：入口/界面在上、存储/支撑在下）
public const ROLE_ENTRY: Int64 = 0
public const ROLE_UI: Int64 = 1
public const ROLE_SERVICE: Int64 = 2
public const ROLE_MODEL: Int64 = 3
public const ROLE_STORAGE: Int64 = 4
public const ROLE_SUPPORT: Int64 = 5
public const ROLE_OTHER: Int64 = 6
public const ROLE_COUNT: Int64 = 7

public func roleName(role: Int64, en: Bool): String {
    if (en) {
        match (role) {
            case 0 => return "Entry"
            case 1 => return "Interface"
            case 2 => return "Service"
            case 3 => return "Model"
            case 4 => return "Storage"
            case 5 => return "Support"
            case _ => return "Other"
        }
    }
    match (role) {
        case 0 => return "入口"
        case 1 => return "界面"
        case 2 => return "服务"
        case 3 => return "数据"
        case 4 => return "存储"
        case 5 => return "支撑"
        case _ => return "其他"
    }
}

/// 角色的层秩（违规判据用）：入口 4 > 界面 3 > 服务 2 > 数据 1 > 存储/支撑 0。
/// 其他 = -1：不参与违规判定（与模块层 4 的「坐标系之外」同一纪律）。
public func roleRank(role: Int64): Int64 {
    match (role) {
        case 0 => return 4
        case 1 => return 3
        case 2 => return 2
        case 3 => return 1
        case 4 => return 0
        case 5 => return 0
        case _ => return -1
    }
}

/// 职责违规：低秩依赖高秩（数据 → 界面、存储 → 服务即逆流）。
/// 任一侧为「其他」不判（坐标系之外，同 isLayerViolation 的 M12 教训）。
public func isRoleViolation(fa: Int64, fb: Int64): Bool {
    let ra = roleRank(fa)
    let rb = roleRank(fb)
    if (ra < 0 || rb < 0) { return false }
    return ra < rb
}

func baseNameNoExt(relPath: String): String {
    let segs = relPath.split("/")
    let last = segs[segs.size - 1]
    // 只剥最后一个扩展名：按 '.' 切段重拼（含多段扩展名也只留主名前的部分）
    let parts = last.split(".")
    let base = if (parts.size > 1) {
        var sb = StringBuilder()
        var i = 0
        for (p in parts) {
            if (i >= parts.size - 1) { break }
            if (i > 0) { sb.append(".") }
            sb.append(p)
            i += 1
        }
        sb.toString()
    } else {
        last
    }
    return base.toAsciiLower()
}

/// 职责词表与判定。**顺序即优先级**：入口 → 界面 → 存储 → 服务 → 数据 → 支撑。
/// （SettingsSheet 命中界面而不是数据；SessionStore 命中存储而不是服务——
///  更具体的形态后缀先判。）
public func fileRole(relPath: String): Int64 {
    let base = baseNameNoExt(relPath)
    // ── 入口：语言约定的程序起点 ──
    if (base == "main" || base == "app" || base == "index"
        || base.endsWith("appdelegate") || base.endsWith("app")) {
        return ROLE_ENTRY
    }
    // ── 界面：视图/窗口/交互组件后缀 ──
    let uiWords = ["view", "window", "sheet", "page", "screen", "bar", "menu",
        "palette", "ruler", "controller", "panel", "card", "tab", "cell",
        "toast", "dialog", "popover", "sidebar", "toolbar", "hud", "overlay",
        "canvas", "button", "theme", "style"]
    for (w in uiWords) {
        if (base.endsWith(w)) { return ROLE_UI }
    }
    // ── 存储：持久化/缓存 ──
    let storageWords = ["store", "database", "persist", "cache", "realm", "sqlite"]
    for (w in storageWords) {
        if (base.contains(w)) { return ROLE_STORAGE }
    }
    // ── 服务：业务逻辑/外部通道 ──
    let serviceWords = ["service", "manager", "engine", "coordinator", "worker",
        "runner", "client", "provider", "gateway", "fetcher", "scheduler", "queue"]
    for (w in serviceWords) {
        if (base.contains(w)) { return ROLE_SERVICE }
    }
    // ── 数据：模型/配置/文档 ──
    let modelWords = ["model", "entity", "dto", "schema", "config", "settings",
        "preference", "types", "constants", "state", "document", "record",
        "response", "request", "language"]
    for (w in modelWords) {
        if (base.contains(w)) { return ROLE_MODEL }
    }
    // ── 支撑：工具/转换/扩展 ──
    let supportWords = ["util", "helper", "extension", "common", "shared",
        "format", "highlight", "convert", "wrapper"]
    for (w in supportWords) {
        if (base.contains(w)) { return ROLE_SUPPORT }
    }
    return ROLE_OTHER
}

/// 一个技术角色的聚合卡（职责视图的节点，字段与 ArchModule 对齐——
/// 渲染与 panel 复用同一形状，两套字段必然漂移）。
public class RoleGroup {
    public let role: Int64
    public var files: Int64 = 0
    public var symbols: Int64 = 0
    public var lines: Int64 = 0
    public var langs: ArrayList<String> = ArrayList<String>()
    /// 该角色的代表文件（按行数降序至多 8 个，panel 展示；空角色不展示）
    public var topFiles: ArrayList<String> = ArrayList<String>()
    public var fanIn: Int64 = 0
    public var fanOut: Int64 = 0
    public var instability: Int64 = 0
    public var x: Float64 = 0.0
    public var y: Float64 = 0.0
    public var w: Float64 = 0.0
    public var h: Float64 = 0.0

    public init(role: Int64) {
        this.role = role
    }
}

// MARK: - 聚合

/// 职责构成桶的零值（7 桶，0 占位）。属性默认值不能写字面量块
///（仓颉把它当 lambda 解析），收进函数。
func roleMixDefaults(): ArrayList<Int64> {
    let a = ArrayList<Int64>()
    var i: Int64 = 0
    while (i < ROLE_COUNT) { a.add(0); i += 1 }
    return a
}

public class ArchModule {
    public let id: String          // 目录名（root 文件 = "(root)"）
    public let layer: Int64
    public var files: Int64 = 0
    public var symbols: Int64 = 0
    public var lines: Int64 = 0
    public var langs: ArrayList<String> = ArrayList<String>()
    // 扇入/扇出/不稳定度（buildArch 在边聚合完成后计算，唯一口径 = 模块级
    // ArchEdge 的 weight 求和；JSON 出口与渲染共用，不许各算各的）：
    //   fanIn  = 指向本模块的边 weight 之和（被依赖 = 越核心）
    //   fanOut = 本模块出发的边 weight 之和（依赖别人 = 变化源头）
    //   instability = 0..100，round(100 * fanOut / (fanIn+fanOut))——
    //   越低越被依赖（稳定），越高越是「只出不进」的变化源头
    public var fanIn: Int64 = 0
    public var fanOut: Int64 = 0
    public var instability: Int64 = 0
    // 职责构成（ROLE_COUNT 桶计数，下标 = 角色）：模块卡上的构成条数据。
    // 恒发全 7 桶（0 也占位）——消费方按桶画比例，键集不随数据漂移。
    public var roleMix: ArrayList<Int64> = roleMixDefaults()
    // 入口文件名（role=入口 的文件 basename，升序）。空 = 该模块没有入口。
    public var entryFiles: ArrayList<String> = ArrayList<String>()
    // 布局（引擎算好，HTML 只负责画）
    public var x: Float64 = 0.0
    public var y: Float64 = 0.0
    public var w: Float64 = 0.0
    public var h: Float64 = 0.0

    public init(id: String, layer: Int64) {
        this.id = id
        this.layer = layer
    }
}

/// 下钻子图里的文件节点。外部模块以**单个虚拟节点**出现
/// （id 形如 "@module:util"）——跨模块依赖不消失，只降级成一个端口。
public struct DrillNode {
    public let id: String          // 文件 relPath，或 "@module:<模块名>"
    public let label: String       // 显示名（文件取 basename，外部取模块名）
    public let lang: String        // 虚拟节点 = "module"
    public let lines: Int64
    public let symbols: Int64
    public let external: Bool
    public var x: Float64 = 0.0
    public var y: Float64 = 0.0
    public var w: Float64 = 0.0
    public var h: Float64 = 0.0

    public init(id: String, label: String, lang: String, lines: Int64, symbols: Int64, external: Bool) {
        this.id = id
        this.label = label
        this.lang = lang
        this.lines = lines
        this.symbols = symbols
        this.external = external
    }
}

/// 一个模块的文件级子图。
public struct DrillGraph {
    public let moduleId: String
    public let nodes: ArrayList<DrillNode>
    public let edges: ArrayList<(String, String, Int64)>   // 文件(或虚拟) → 文件(或虚拟)

    public init(moduleId: String, nodes: ArrayList<DrillNode>, edges: ArrayList<(String, String, Int64)>) {
        this.moduleId = moduleId
        this.nodes = nodes
        this.edges = edges
    }
}

/// 模块依赖边（带治理信号）。
public struct ArchEdge {
    public let fromId: String
    public let toId: String
    public let weight: Int64
    /// 分层违规：低层依赖高层（基础层 ← 接口层方向为正；反向即违规）
    public let violation: Bool
    /// 该边处于某个模块依赖环上（a→b 且 b 可达 a）
    public let cycle: Bool

    public init(fromId: String, toId: String, weight: Int64, violation: Bool, cycle: Bool) {
        this.fromId = fromId
        this.toId = toId
        this.weight = weight
        this.violation = violation
        this.cycle = cycle
    }
}

public class ArchData {
    public let modules: ArrayList<ArchModule>
    public let edges: ArrayList<ArchEdge>
    public let totalFiles: Int64
    public let totalSymbols: Int64
    public let totalLines: Int64
    public let truncated: Bool
    /// 每模块的文件级下钻子图（引擎算好布局，Canvas 只负责画）
    public let drilldown: ArrayList<DrillGraph>
    /// 治理信号（渲染与 JSON 出口共用）：违规边数 / 环上边数 / 违规对 / 环上模块
    public let violationCount: Int64
    public let cycleEdgeCount: Int64
    public let violationPairs: ArrayList<(String, String)>
    public let cycleModules: ArrayList<String>
    /// 职责视图：角色聚合卡（空角色也在列表里，files=0——面板按需隐藏）
    public let roles: ArrayList<RoleGroup>
    /// 角色间依赖边（文件级边按角色对聚合；不含角色内部边）
    public let roleEdges: ArrayList<ArchEdge>
    /// 职责违规边数（低秩依赖高秩，如数据 → 界面）
    public let roleViolationCount: Int64

    public init(modules: ArrayList<ArchModule>, edges: ArrayList<ArchEdge>,
                totalFiles: Int64, totalSymbols: Int64, totalLines: Int64, truncated: Bool,
                drilldown: ArrayList<DrillGraph>,
                violationCount: Int64, cycleEdgeCount: Int64,
                violationPairs: ArrayList<(String, String)>,
                cycleModules: ArrayList<String>,
                roles: ArrayList<RoleGroup>,
                roleEdges: ArrayList<ArchEdge>,
                roleViolationCount: Int64) {
        this.modules = modules
        this.edges = edges
        this.totalFiles = totalFiles
        this.totalSymbols = totalSymbols
        this.totalLines = totalLines
        this.truncated = truncated
        this.drilldown = drilldown
        this.violationCount = violationCount
        this.cycleEdgeCount = cycleEdgeCount
        this.violationPairs = violationPairs
        this.cycleModules = cycleModules
        this.roles = roles
        this.roleEdges = roleEdges
        this.roleViolationCount = roleViolationCount
    }
}

/// 模块 = 相对路径的首段目录（根文件聚成 "(root)"）。
/// 相对路径 → 模块名（buildArch 与边聚合**必须**共用这一个函数 ——
/// 各写各的，节点叫 util、边却聚到 src，图就变成一堆孤岛）。
public func moduleOfPath(relPath: String): String {
    let segs = relPath.split("/")
    if (segs.size >= 2) {
        if (isWrapperDir(segs[0]) && segs.size >= 3) { return segs[1] }
        return segs[0]
    }
    return "(root)"
}

/// drilldown 边端点 → 所属模块：`@module:<名>` 虚拟节点取 `<名>`，
/// 文件路径走 moduleOfPath（与 buildDrilldown 聚边同一映射）。
/// archJson 的 drilldown 边靠它把文件级端点收敛回模块对，再查模块级治理信号。
func drillEdgeModule(id: String): String {
    let prefix = "@module:"
    if (id.startsWith(prefix) && id.size > prefix.size) {
        return id[prefix.size..id.size]
    }
    return moduleOfPath(id)
}

/// 分层违规判定。**纯函数**。
///
/// M12：原来这里是裸的 `la < lb`，而未命中启发式词表的模块拿层 **4**
///（`inferLayer` 的兜底）⇒ 层 4 被当成「最高层」参与 `la < lb`：
/// 目录名不含词表词的模块（现实中极常见：docs、scripts、`(root)`——
/// `moduleOfPath("main.cj")` 即得层 4）的所有入边，从 util(0)/kernel(1)/
/// flow(2)/cli(3) 过来**全部**被记成违规。「其他」既不高于也不低于任何层，
/// 它压根不在这个坐标系里 —— 参与排序就是把它塞到最高层。
/// 判据：两侧都必须是已分层（<4）的模块，才算违规。
public func isLayerViolation(la: Int64, lb: Int64): Bool {
    if (la >= 4 || lb >= 4) {
        return false
    }
    return la < lb
}

public func buildArch(graph: CodeGraph): ArchData {
    let mods = HashMap<String, ArchModule>()
    func modOf(dir: String): ArchModule {
        match (mods.get(dir)) {
            case Some(m) => return m
            case None =>
                let m = ArchModule(dir, inferLayer(dir))
                mods[dir] = m
                return m
        }
    }
    // 职责聚合的中间态（与模块聚合同一趟循环——同一文件只走一遍）
    let roleFiles = HashMap<String, Int64>()
    let roleSymbols = HashMap<String, Int64>()
    let roleLines = HashMap<String, Int64>()
    let fileListByRole = HashMap<String, ArrayList<(String, Int64)>>()   // role → [(relPath, lines)]
    let roleOf = HashMap<String, Int64>()                                // relPath → role（边聚合用）
    for (f in graph.files) {
        let m = modOf(moduleOfPath(f.relPath))
        m.files += 1
        m.symbols += Int64(f.symbols.size)
        m.lines += f.lines
        if (!m.langs.contains(f.lang)) { m.langs.add(f.lang) }
        // 职责
        let role = fileRole(f.relPath)
        roleOf[f.relPath] = role
        let rk = role.toString()
        match (roleFiles.get(rk)) {
            case Some(v) => roleFiles[rk] = v + 1
            case None => roleFiles[rk] = 1
        }
        match (roleSymbols.get(rk)) {
            case Some(v) => roleSymbols[rk] = v + Int64(f.symbols.size)
            case None => roleSymbols[rk] = Int64(f.symbols.size)
        }
        match (roleLines.get(rk)) {
            case Some(v) => roleLines[rk] = v + f.lines
            case None => roleLines[rk] = f.lines
        }
        match (fileListByRole.get(rk)) {
            case Some(l) => l.add((f.relPath, f.lines))
            case None =>
                let l = ArrayList<(String, Int64)>()
                l.add((f.relPath, f.lines))
                fileListByRole[rk] = l
        }
        let mi = role
        m.roleMix[mi] = m.roleMix[mi] + 1
        if (role == ROLE_ENTRY) {
            let segs = f.relPath.split("/")
            m.entryFiles.add(segs[segs.size - 1])
        }
    }
    // 边：文件级（import + reference）按模块对聚合求和。
    // moduleOfPath 的 split 结果缓存（每条边两端各一次 ⇒ 2E 次 split → 每文件一次）
    let modCache = HashMap<String, String>()
    func modAt2(relPath: String): String {
        match (modCache.get(relPath)) {
            case Some(m) => return m
            case None =>
                let m = moduleOfPath(relPath)
                modCache[relPath] = m
                return m
        }
    }
    let weight = HashMap<String, Int64>()
    let roleWeight = HashMap<String, (Int64, Int64, Int64)>()
    func bump(a: String, b: String, w: Int64): Unit {
        let da = modAt2(a)
        let db = modAt2(b)
        if (da == db) { return }
        let key = "${da}|${db}"
        match (weight.get(key)) {
            case Some(v) => weight[key] = v + w
            case None => weight[key] = w
        }
    }
    // 角色对聚合（职责视图专用，与模块聚合**分开一个循环**）：
    // 数据源 = refEdges（引用口径）+ importEdges（显式导入）——不能用
    // archRefEdges：那是「跨模块才成立」的架构口径，单包应用恒空，
    // 而职责分层恰恰是为单包应用准备的深度（实测 d2note 首版恒空）。
    // 去噪：词法引用要求 **≥2 个不同符号**（w>=2）才算角色依赖——
    // 单符号命中里同名噪音占比最高；显式 import 行无豁免必要（行锚定，
    // 剥后仍在才算，本身就是强信号）。同角色内部的边不算角色依赖。
    func roleBump(a: String, b: String, w: Int64, strong: Bool): Unit {
        if (!strong && w < 2) { return }
        match (roleOf.get(a)) {
            case Some(ra) =>
                match (roleOf.get(b)) {
                    case Some(rb) =>
                        if (ra != rb) {
                            let rk = "${ra}|${rb}"
                            match (roleWeight.get(rk)) {
                                case Some(v) => roleWeight[rk] = (ra, rb, v[2] + w)
                                case None => roleWeight[rk] = (ra, rb, w)
                            }
                        }
                    case None => ()
                }
            case None => ()
        }
    }
    for ((from, to) in graph.importEdges) {
        bump(from, to, 1)
        roleBump(from, to, 1, true)   // 显式 import = 强信号
    }
    for ((from, to, w) in graph.refEdges) {
        roleBump(from, to, w, false)  // 词法引用：≥2 个符号才算
    }
    // 架构聚合用 archRefEdges（架构口径），不是 refEdges（引用口径）——
    // 引用口径对架构聚合是满屏假违规：引擎自身 9/9 模块对「全违规」，实测
    // 成因全是同名噪音（doc 注释提及他包符号、strx.cj 每包一份的合法重名、
    // 泛型占位符 T 撞翻译函数 T、局部变量撞成员方法），没有一条是真依赖。
    // 两份边集的判据差异见 model.cj 的 archRefEdges 字段注释。
    for ((from, to, w) in graph.archRefEdges) { bump(from, to, w) }

    // 先装配模块列表（治理信号需要每模块的层）
    var totalFiles: Int64 = 0
    var totalSymbols: Int64 = 0
    var totalLines: Int64 = 0
    let list = ArrayList<ArchModule>()
    for ((_, m) in mods) { list.add(m) }
    insertionSortBy(list, { a, b => a.id < b.id })
    for (m in list) {
        totalFiles += m.files
        totalSymbols += m.symbols
        totalLines += m.lines
    }

    // ── 边装配 + 治理信号（一个循环内完成）──
    // 分层违规 = 低层依赖高层（如 util → cli）；环 = b 可达 a 的边。
    // ⚠️ 仓颉坑：字段名不能用 `from`（保留字）；命名实参前缀同样不能用 ——
    // reaches 的调用一律位置传参。
    let layerOf = HashMap<String, Int64>()
    for (m in list) { layerOf[m.id] = m.layer }
    let rawPairs = ArrayList<(String, String, Int64)>()
    for ((key, w) in weight) {
        let segs = key.split("|")
        if (segs.size == 2) { rawPairs.add((segs[0], segs[1], w)) }
    }
    // M11 残留：出口确定性。rawPairs 物化自 weight（HashMap）的迭代序，而
    // edges / violationPairs / cycleModules / archJson / mermaid / dot 全部
    // 按该序输出——字节序不能依赖语言未定义的 HashMap 迭代序，物化后立即
    // 按全序排定（a↑ → b↑ → w↑，与 refEdges / unresolvedList 同一纪律）。
    insertionSortBy(rawPairs, { a, b =>
        if (a[0] != b[0]) { return a[0] < b[0] }
        if (a[1] != b[1]) { return a[1] < b[1] }
        return a[2] < b[2]
    })
    let adj = HashMap<String, ArrayList<String>>()
    for ((a, b, _) in rawPairs) {
        match (adj.get(a)) {
            case Some(l) => l.add(b)
            case None =>
                let l = ArrayList<String>()
                l.add(b)
                adj[a] = l
        }
    }
    func reaches(startNode: String, goalNode: String): Bool {
        let seenL = HashSet<String>()
        let stack = ArrayList<String>()
        stack.add(startNode)
        while (stack.size > 0) {
            let cur = stack[stack.size - 1]
            stack.remove(at: stack.size - 1)
            match (adj.get(cur)) {
                case Some(nexts) =>
                    for (nx in nexts) {
                        if (nx == goalNode) { return true }
                        if (!seenL.contains(nx)) {
                            seenL.add(nx)
                            stack.add(nx)
                        }
                    }
                case None => ()
            }
        }
        return false
    }
    let edges = ArrayList<ArchEdge>()
    var violationCount: Int64 = 0
    var cycleEdgeCount: Int64 = 0
    let violationPairs = ArrayList<(String, String)>()
    let cycleModules = ArrayList<String>()
    for ((a, b, w) in rawPairs) {
        let la = match (layerOf.get(a)) {
            case Some(v) => v
            case None => 4
        }
        let lb = match (layerOf.get(b)) {
            case Some(v) => v
            case None => 4
        }
        let isViol = isLayerViolation(la, lb)
        let isCycle = reaches(b, a)
        if (isViol) {
            violationCount += 1
            violationPairs.add((a, b))
        }
        if (isCycle) {
            cycleEdgeCount += 1
            if (!cycleModules.contains(a)) { cycleModules.add(a) }
            if (!cycleModules.contains(b)) { cycleModules.add(b) }
        }
        edges.add(ArchEdge(a, b, w, isViol, isCycle))
    }

    // ── 扇入 / 扇出 / 不稳定度（边聚合完成后计算，口径 = 模块级 ArchEdge）──
    // ArchModule 是 class（引用语义），直接累加即可。不稳定度用**纯整数**
    // 四舍五入：(200*fanOut + total) / (2*total) —— round(100*f/t) 的整数形式，
    // 不引入浮点（同值同结果，跨平台确定性）。
    for (e in edges) {
        match (mods.get(e.fromId)) {
            case Some(m) => m.fanOut += e.weight
            case None => ()
        }
        match (mods.get(e.toId)) {
            case Some(m) => m.fanIn += e.weight
            case None => ()
        }
    }
    for (m in list) {
        let total = m.fanIn + m.fanOut
        m.instability = if (total == 0) { 0 } else { (200 * m.fanOut + total) / (2 * total) }
    }

    let drill = buildDrilldown(graph, list)

    // ── 职责视图装配（角色卡 + 角色边 + 治理信号）──
    let roles = ArrayList<RoleGroup>()
    var ri: Int64 = 0
    while (ri < ROLE_COUNT) {
        let g = RoleGroup(ri)
        let rk = ri.toString()
        match (roleFiles.get(rk)) {
            case Some(v) => g.files = v
            case None => ()
        }
        match (roleSymbols.get(rk)) {
            case Some(v) => g.symbols = v
            case None => ()
        }
        match (roleLines.get(rk)) {
            case Some(v) => g.lines = v
            case None => ()
        }
        match (fileListByRole.get(rk)) {
            case Some(l) =>
                // 代表文件：行数降序，平局按路径升序（确定性），至多 8 个
                insertionSortBy(l, { a, b =>
                    if (a[1] != b[1]) { return a[1] > b[1] }
                    return a[0] < b[0]
                })
                var k = 0
                for (item in l) {
                    if (k >= 8) { break }
                    g.topFiles.add(item[0])
                    k += 1
                }
            case None => ()
        }
        roles.add(g)
        ri += 1
    }
    // 角色边：物化 + 全序排定（HashMap 迭代序不可依赖——M11 同一纪律）
    let rawRolePairs = ArrayList<(Int64, Int64, Int64)>()
    for ((_, trio) in roleWeight) {
        rawRolePairs.add(trio)
    }
    insertionSortBy(rawRolePairs, { a, b =>
        if (a[0] != b[0]) { return a[0] < b[0] }
        if (a[1] != b[1]) { return a[1] < b[1] }
        return a[2] < b[2]
    })
    let roleEdges = ArrayList<ArchEdge>()
    var roleViolationCount: Int64 = 0
    let roleFan = HashMap<String, Int64>()
    for ((ra, rb, w) in rawRolePairs) {
        let isViol = isRoleViolation(ra, rb)
        if (isViol) { roleViolationCount += 1 }
        roleEdges.add(ArchEdge(ra.toString(), rb.toString(), w, isViol, false))
        match (roleFan.get("out:${ra}")) {
            case Some(v) => roleFan["out:${ra}"] = v + w
            case None => roleFan["out:${ra}"] = w
        }
        match (roleFan.get("in:${rb}")) {
            case Some(v) => roleFan["in:${rb}"] = v + w
            case None => roleFan["in:${rb}"] = w
        }
    }
    for (g in roles) {
        match (roleFan.get("in:${g.role}")) {
            case Some(v) => g.fanIn = v
            case None => ()
        }
        match (roleFan.get("out:${g.role}")) {
            case Some(v) => g.fanOut = v
            case None => ()
        }
        let total = g.fanIn + g.fanOut
        g.instability = if (total == 0) { 0 } else { (200 * g.fanOut + total) / (2 * total) }
    }
    layoutRoles(roles)

    return ArchData(list, edges, totalFiles, totalSymbols, totalLines, graph.truncated, drill,
                    violationCount, cycleEdgeCount, violationPairs, cycleModules,
                    roles, roleEdges, roleViolationCount)
}

// MARK: - 下钻子图（模块 → 文件级）

/// 为每个模块构建文件级子图：
///   节点 = 模块内文件 + 有依赖往来的外部模块（虚拟节点）
///   边   = 文件级 import + 架构口径 reference（archRefEdges，跨模块的指向
///          虚拟节点）——与 buildArch 的模块聚合同源，子图不会画出模块级
///          图上不存在的依赖
/// 布局：内部文件按目录聚类网格排列，外部虚拟节点靠右一列——确定性，可对账。
func buildDrilldown(graph: CodeGraph, modules: ArrayList<ArchModule>): ArrayList<DrillGraph> {
    // ⚠️ 性能审查：moduleOfPath 内部要 split 路径；原实现对
    // 「每模块 × 全量引用边 × 两端」逐次调用（M×2E 次 split，实测 6 模块
    // ×11000 边 = 13 万次）。先一次性算好 relPath → 模块的映射，之后纯查表。
    let modOf = HashMap<String, String>()
    for (f in graph.files) { modOf[f.relPath] = moduleOfPath(f.relPath) }
    func modAt(relPath: String): String {
        match (modOf.get(relPath)) {
            case Some(m) => return m
            case None =>
                let m = moduleOfPath(relPath)
                modOf[relPath] = m
                return m
        }
    }
    let out = ArrayList<DrillGraph>()
    for (m in modules) {
        let nodes = ArrayList<DrillNode>()
        let byId = HashMap<String, DrillNode>()
        // 内部文件
        for (f in graph.files) {
            if (modAt(f.relPath) != m.id) { continue }
            let segs = f.relPath.split("/")
            let base = segs[segs.size - 1]
            let n = DrillNode(f.relPath, base, f.lang, f.lines, Int64(f.symbols.size), false)
            nodes.add(n)
            byId[f.relPath] = n
        }
        // 外部往来模块 → 虚拟节点（架构口径 archRefEdges，与 buildArch 聚合
        // 同源——引用口径的同名噪音会把毫不相干的模块拖进子图）
        let extMods = ArrayList<String>()
        for ((from, to, _) in graph.archRefEdges) {
            let fa = modAt(from)
            let fb = modAt(to)
            if (fa == m.id && fb != m.id && !extMods.contains(fb)) { extMods.add(fb) }
            if (fb == m.id && fa != m.id && !extMods.contains(fa)) { extMods.add(fa) }
        }
        for ((from, to) in graph.importEdges) {
            let fa = modAt(from)
            let fb = modAt(to)
            if (fa == m.id && fb != m.id && !extMods.contains(fb)) { extMods.add(fb) }
            if (fb == m.id && fa != m.id && !extMods.contains(fa)) { extMods.add(fa) }
        }
        insertionSortBy(extMods, { a, b => a < b })
        for (x in extMods) {
            let n = DrillNode("@module:${x}", x, "module", 0, 0, true)
            nodes.add(n)
            byId[n.id] = n
        }
        // 边：文件级，两端都在子图节点集里（跨模块的落在外部虚拟节点上）；
        // 与 extMods 同用架构口径（archRefEdges）——子图内的边必须与模块级
        // 聚合的边同源，否则下钻子图会画出模块级图上不存在的依赖
        let edges = ArrayList<(String, String, Int64)>()
        for ((from, to, w) in graph.archRefEdges) {
            let fa = modAt(from)
            let fb = modAt(to)
            if (fa != m.id && fb != m.id) { continue }
            var a = from
            var b = to
            if (fa != m.id) { a = "@module:${fa}" }
            if (fb != m.id) { b = "@module:${fb}" }
            if (byId.get(a).isSome() && byId.get(b).isSome() && a != b) {
                edges.add((a, b, w))
            }
        }
        for ((from, to) in graph.importEdges) {
            let fa = modAt(from)
            let fb = modAt(to)
            if (fa != m.id && fb != m.id) { continue }
            var a = from
            var b = to
            if (fa != m.id) { a = "@module:${fa}" }
            if (fb != m.id) { b = "@module:${fb}" }
            if (byId.get(a).isSome() && byId.get(b).isSome() && a != b) {
                edges.add((a, b, 1))
            }
        }
        layoutDrill(nodes, m.id)
        out.add(DrillGraph(m.id, nodes, edges))
    }
    return out
}

/// 文件子图布局：目录聚类 → 列网格；外部虚拟节点靠右独立列。
/// 确定性：行/列序都来自排序后的 id。
func layoutDrill(nodes: ArrayList<DrillNode>, moduleId: String): Unit {
    let w: Float64 = 208.0
    let h: Float64 = 46.0
    let gx: Float64 = 26.0
    let gy: Float64 = 22.0
    let margin: Float64 = 56.0
    let internalNodes = ArrayList<DrillNode>()
    let externalNodes = ArrayList<DrillNode>()
    for (n in nodes) {
        if (n.external) { externalNodes.add(n) } else { internalNodes.add(n) }
    }
    insertionSortBy(internalNodes, { a, b => a.id < b.id })
    insertionSortBy(externalNodes, { a, b => a.id < b.id })
    // 网格 4 列（列数随规模自适应：≤8 个单列居中排）
    var cols: Int64 = 4
    if (Int64(internalNodes.size) <= 8) { cols = 2 }
    if (Int64(internalNodes.size) <= 3) { cols = 1 }
    var row: Float64 = 0.0
    var col: Int64 = 0
    // struct 是值类型：下标取出 → 改 → 写回
    var i: Int64 = 0
    while (i < Int64(internalNodes.size)) {
        var n = internalNodes[i]
        n.w = w
        n.h = h
        n.x = margin + Float64(col) * (w + gx)
        n.y = margin + row * (h + gy)
        internalNodes[i] = n
        col += 1
        if (col >= cols) {
            col = 0
            row += 1.0
        }
        i += 1
    }
    // 外部列：与内部区同顶部
    var extX = margin + Float64(cols) * (w + gx) + 60.0
    var ey: Float64 = margin
    i = 0
    while (i < Int64(externalNodes.size)) {
        var n = externalNodes[i]
        n.w = w
        n.h = h
        n.x = extX
        n.y = ey
        externalNodes[i] = n
        ey += h + gy
        i += 1
    }
    // 布局写回总表（nodes 里的元素同样按 id 回填）
    var k: Int64 = 0
    while (k < Int64(nodes.size)) {
        var n = nodes[k]
        match (byIdLike(internalNodes, n.id)) {
            case Some(fixed) => n = fixed
            case None => ()
        }
        match (byIdLike(externalNodes, n.id)) {
            case Some(fixed) => n = fixed
            case None => ()
        }
        nodes[k] = n
        k += 1
    }
}

func byIdLike(list: ArrayList<DrillNode>, id: String): Option<DrillNode> {
    var i: Int64 = 0
    while (i < Int64(list.size)) {
        if (list[i].id == id) { return Some(list[i]) }
        i += 1
    }
    return None
}

// MARK: - 布局（分层泳道：层为水平泳道，L4/L3 在最上、L0 在最下）
//
// 【方向语义】画布 y 向下 ⇒ 行号 = LAYER_COUNT-1-layer：接口层(L3) 在最上、
// 基础层(L0) 在最下，**依赖健康方向 = 箭头向下**；违规边（低层依赖高层）
// 逆流向上，一眼可见。层 4（未分层，不参与违规判定）位于最顶端、与坐标系
// 区隔——它的「最高」是「坐标系之外」，不是「比接口层更高」。
// 【确定性】泳道宽 = LABEL_W + 全图最大槽数 × SLOT_W（各层同宽，对齐）；
// 层内模块按 id 升序均匀排布；同一层所有卡片 y 相同。零随机、零浮点歧义。

public func layoutArch(data: ArchData): Unit {
    // 先按层收集（id 升序——上游已排，这里显式再排，布局不依赖上游纪律）
    var laneMods = HashMap<Int64, ArrayList<ArchModule>>()
    var maxSlots: Int64 = 1
    var layer: Int64 = 0
    while (layer < LAYER_COUNT) {
        let list = ArrayList<ArchModule>()
        for (m in data.modules) {
            if (m.layer == layer) { list.add(m) }
        }
        insertionSortBy(list, { a, b => a.id < b.id })
        if (Int64(list.size) > maxSlots) { maxSlots = Int64(list.size) }
        laneMods[layer] = list
        layer += 1
    }
    let laneH = ARCH_CARD_H + ARCH_LANE_PAD_V * 2.0
    let innerW = Float64(maxSlots) * ARCH_SLOT_W
    layer = 0
    while (layer < LAYER_COUNT) {
        var list: ArrayList<ArchModule>
        match (laneMods.get(layer)) {
            case Some(l) => list = l
            case None => list = ArrayList<ArchModule>()
        }
        if (list.size > 0) {
            let row = LAYER_COUNT - 1 - layer
            let cardY = ARCH_MARGIN + Float64(row) * (laneH + ARCH_LANE_GAP) + ARCH_LANE_PAD_V
            // 均匀排布：槽距 = 泳道内宽 / 本层模块数，卡片在槽内居中
            let sp = innerW / Float64(list.size)
            var i: Int64 = 0
            for (m in list) {
                m.w = ARCH_CARD_W
                m.h = ARCH_CARD_H
                m.x = ARCH_MARGIN + ARCH_LANE_LABEL_W + Float64(i) * sp + (sp - ARCH_CARD_W) / 2.0
                m.y = cardY
                i += 1
            }
        }
        layer += 1
    }
}

/// 泳道矩形清单（archJson 的 `lanes` 与 scene 层框的**唯一来源**）。
/// 只依赖布局常量与各层模块数（与 layoutArch 完全同式），不要求先跑
/// layoutArch。顺序 = 绘制序：layer 4→0 自上而下，确定性。
public func archLaneRects(data: ArchData, en: Bool): ArrayList<JsonValue> {
    var maxSlots: Int64 = 1
    var countByLayer = HashMap<Int64, Int64>()
    var layer: Int64 = 0
    while (layer < LAYER_COUNT) {
        var count: Int64 = 0
        for (m in data.modules) { if (m.layer == layer) { count += 1 } }
        if (count > maxSlots) { maxSlots = count }
        countByLayer[layer] = count
        layer += 1
    }
    let laneH = ARCH_CARD_H + ARCH_LANE_PAD_V * 2.0
    let laneW = ARCH_LANE_LABEL_W + Float64(maxSlots) * ARCH_SLOT_W
    let out = ArrayList<JsonValue>()
    var row: Int64 = 0
    layer = LAYER_COUNT - 1
    while (layer >= 0) {
        var count: Int64 = 0
        match (countByLayer.get(layer)) {
            case Some(c) => count = c
            case None => ()
        }
        if (count > 0) {
            let o = Json.obj()
            Json.set(o, "layer", Json.of(layer))
            Json.set(o, "name", Json.of(layerName(layer, en)))
            Json.set(o, "x", Json.of(ARCH_MARGIN))
            Json.set(o, "y", Json.of(ARCH_MARGIN + Float64(row) * (laneH + ARCH_LANE_GAP)))
            Json.set(o, "w", Json.of(laneW))
            Json.set(o, "h", Json.of(laneH))
            Json.set(o, "modules", Json.of(count))
            out.add(o)
        }
        row += 1
        layer -= 1
    }
    return out
}


// MARK: - 职责视图布局（角色泳道：入口/界面在上、存储/支撑在下）
//
// 与 layoutArch 同一几何（同一组常量、同一排布式）——两份代码不是漂移：
// 一个排 ArchModule（模块层泳道），一个排 RoleGroup（角色泳道），数据类型
// 不同无法共用；几何常量是共享的（编译期同一来源）。
//
// 泳道顺序（上→下）= 依赖健康方向：入口(4) 界面(3) 服务(2) 数据(1)
// 存储(0) 支撑(0) 其他(-1，坐标系之外，压底）。同秩（存储/支撑）按角色 id。

/// 泳道序：角色 id 的绘制顺序（上→下）。确定性：显式列表，不靠排序推。
func roleLaneOrder(): ArrayList<Int64> {
    let l = ArrayList<Int64>()
    l.add(ROLE_ENTRY)
    l.add(ROLE_UI)
    l.add(ROLE_SERVICE)
    l.add(ROLE_MODEL)
    l.add(ROLE_STORAGE)
    l.add(ROLE_SUPPORT)
    l.add(ROLE_OTHER)
    return l
}

public func layoutRoles(roles: ArrayList<RoleGroup>): Unit {
    let order = roleLaneOrder()
    var maxSlots: Int64 = 1
    var countByRole = HashMap<Int64, Int64>()
    for (r in order) {
        var count: Int64 = 0
        for (g in roles) { if (g.role == r && g.files > 0) { count += 1 } }
        if (count > maxSlots) { maxSlots = count }
        countByRole[r] = count
    }
    let laneH = ARCH_CARD_H + ARCH_LANE_PAD_V * 2.0
    let innerW = Float64(maxSlots) * ARCH_SLOT_W
    var row: Int64 = 0
    for (r in order) {
        var count: Int64 = 0
        match (countByRole.get(r)) {
            case Some(c) => count = c
            case None => ()
        }
        if (count > 0) {
            let members = ArrayList<RoleGroup>()
            for (g in roles) { if (g.role == r && g.files > 0) { members.add(g) } }
            let sp = innerW / Float64(members.size)
            let cardY = ARCH_MARGIN + Float64(row) * (laneH + ARCH_LANE_GAP) + ARCH_LANE_PAD_V
            var i: Int64 = 0
            for (g in members) {
                g.w = ARCH_CARD_W
                g.h = ARCH_CARD_H
                g.x = ARCH_MARGIN + ARCH_LANE_LABEL_W + Float64(i) * sp + (sp - ARCH_CARD_W) / 2.0
                g.y = cardY
                i += 1
            }
            row += 1
        }
    }
}

/// 职责泳道矩形（archJson 的 roleLanes 唯一来源；与 archLaneRects 同式）。
public func archRoleLaneRects(data: ArchData, en: Bool): ArrayList<JsonValue> {
    let order = roleLaneOrder()
    var maxSlots: Int64 = 1
    var countByRole = HashMap<Int64, Int64>()
    for (r in order) {
        var count: Int64 = 0
        for (g in data.roles) { if (g.role == r && g.files > 0) { count += 1 } }
        if (count > maxSlots) { maxSlots = count }
        countByRole[r] = count
    }
    let laneH = ARCH_CARD_H + ARCH_LANE_PAD_V * 2.0
    let laneW = ARCH_LANE_LABEL_W + Float64(maxSlots) * ARCH_SLOT_W
    let out = ArrayList<JsonValue>()
    var row: Int64 = 0
    for (r in order) {
        var count: Int64 = 0
        match (countByRole.get(r)) {
            case Some(c) => count = c
            case None => ()
        }
        if (count > 0) {
            let o = Json.obj()
            Json.set(o, "role", Json.of(r))
            Json.set(o, "name", Json.of(roleName(r, en)))
            Json.set(o, "x", Json.of(ARCH_MARGIN))
            Json.set(o, "y", Json.of(ARCH_MARGIN + Float64(row) * (laneH + ARCH_LANE_GAP)))
            Json.set(o, "w", Json.of(laneW))
            Json.set(o, "h", Json.of(laneH))
            Json.set(o, "groups", Json.of(count))
            out.add(o)
        }
        row += 1
    }
    return out
}

// MARK: - JSON

public func archJson(data: ArchData, en: Bool): JsonValue {
    let layerList = ArrayList<JsonValue>()
    var i: Int64 = 0
    while (i < LAYER_COUNT) {
        var count: Int64 = 0
        for (m in data.modules) { if (m.layer == i) { count += 1 } }
        let l = Json.obj()
        Json.set(l, "index", Json.of(i))
        Json.set(l, "name", Json.of(layerName(i, en)))
        Json.set(l, "modules", Json.of(count))
        layerList.add(l)
        i += 1
    }
    let ms = ArrayList<JsonValue>()
    for (m in data.modules) {
        let o = Json.obj()
        Json.set(o, "id", Json.of(m.id))
        Json.set(o, "layer", Json.of(m.layer))
        Json.set(o, "files", Json.of(m.files))
        Json.set(o, "symbols", Json.of(m.symbols))
        Json.set(o, "lines", Json.of(m.lines))
        Json.set(o, "langs", Json.strArray(m.langs.toArray()))
        // 治理四键**恒发**（0 也发）：扇入/扇出/不稳定度/层名。缺键会被消费方
        // 读成「旧版本没有这个字段」（恒发纪律同 violation/cycle / truncated），
        // 而「入 N / 出 M」徽标与不稳定度条正是本图区别于普通流转图的实质信息。
        Json.set(o, "fanIn", Json.of(m.fanIn))
        Json.set(o, "fanOut", Json.of(m.fanOut))
        Json.set(o, "instability", Json.of(m.instability))
        Json.set(o, "layerName", Json.of(layerName(m.layer, en)))
        // 职责构成（7 桶恒发，0 也占位）：模块卡的构成条数据。空数组 =
        // 「旧版本没有这个键」，消费方分不出来——恒发纪律同 violation/cycle。
        let mixArr = ArrayList<JsonValue>()
        for (c in m.roleMix) { mixArr.add(Json.of(c)) }
        Json.set(o, "roleMix", JArr(mixArr))
        Json.set(o, "entryFiles", Json.strArray(m.entryFiles.toArray()))
        Json.set(o, "x", Json.of(m.x))
        Json.set(o, "y", Json.of(m.y))
        Json.set(o, "w", Json.of(m.w))
        Json.set(o, "h", Json.of(m.h))
        ms.add(o)
    }
    let es = ArrayList<JsonValue>()
    for (e in data.edges) {
        let o = Json.obj()
        Json.set(o, "from", Json.of(e.fromId))
        Json.set(o, "to", Json.of(e.toId))
        Json.set(o, "weight", Json.of(e.weight))
        // 治理两键**恒发**（false 也发）：原先只在 true 时写键，键集随数据漂移 ——
        // 消费方只能靠「有没有这个键」反推违规（无文档耦合），且缺键会被读成
        // 旧版本没有该字段（恒发纪律同 depth / depthOmitted）。
        Json.set(o, "violation", Json.of(e.violation))
        Json.set(o, "cycle", Json.of(e.cycle))
        es.add(o)
    }
    let warns = Json.obj()
    Json.set(warns, "violations", Json.of(data.violationCount))
    Json.set(warns, "cycleEdges", Json.of(data.cycleEdgeCount))
    let vps = ArrayList<JsonValue>()
    for (p in data.violationPairs) {
        let po = Json.obj()
        Json.set(po, "from", Json.of(p[0]))
        Json.set(po, "to", Json.of(p[1]))
        vps.add(po)
    }
    Json.set(warns, "violationPairs", JArr(vps))
    Json.set(warns, "cycleModules", Json.strArray(data.cycleModules.toArray()))
    // 治理信号的唯一真相是模块级 ArchEdge；drilldown 的文件级边按「两端所属
    // 模块对」查这张表取同一信号（同模块内部边没有模块级对应 → 恒 false）。
    // 同一份 JSON 里两种边必须同形状（violation/cycle 都有）——否则消费方
    // 得写两套解码分支，缺键那一套会把「没信号」读成「没有」。
    let govOf = HashMap<String, (Bool, Bool)>()
    for (e in data.edges) {
        govOf["${e.fromId}|${e.toId}"] = (e.violation, e.cycle)
    }
    let dd = Json.obj()
    for (dg in data.drilldown) {
        let sub = Json.obj()
        let ns = ArrayList<JsonValue>()
        for (n in dg.nodes) {
            let no = Json.obj()
            Json.set(no, "id", Json.of(n.id))
            Json.set(no, "label", Json.of(n.label))
            Json.set(no, "lang", Json.of(n.lang))
            Json.set(no, "lines", Json.of(n.lines))
            Json.set(no, "symbols", Json.of(n.symbols))
            Json.set(no, "external", Json.of(n.external))
            Json.set(no, "x", Json.of(n.x))
            Json.set(no, "y", Json.of(n.y))
            Json.set(no, "w", Json.of(n.w))
            Json.set(no, "h", Json.of(n.h))
            ns.add(no)
        }
        Json.set(sub, "nodes", JArr(ns))
        let es2 = ArrayList<JsonValue>()
        for ((a, b, w) in dg.edges) {
            let eo = Json.obj()
            Json.set(eo, "from", Json.of(a))
            Json.set(eo, "to", Json.of(b))
            Json.set(eo, "weight", Json.of(w))
            // 与模块级边同两键、同恒发纪律：按端点所属模块对查治理信号。
            // 文件级边自己算不出违规/环（那是模块级判定），取的是它所跨的
            // 模块对的信号 —— 同一份 JSON 两种边一个语义。
            var ev = false
            var ec = false
            match (govOf.get("${drillEdgeModule(a)}|${drillEdgeModule(b)}")) {
                case Some((bv, bc)) => ev = bv; ec = bc
                case None => ()
            }
            Json.set(eo, "violation", Json.of(ev))
            Json.set(eo, "cycle", Json.of(ec))
            es2.add(eo)
        }
        Json.set(sub, "edges", JArr(es2))
        Json.set(dd, dg.moduleId, sub)
    }
    let o = Json.obj()
    Json.set(o, "modules", JArr(ms))
    Json.set(o, "edges", JArr(es))
    Json.set(o, "layers", JArr(layerList))
    // 泳道矩形（恒发；空仓库给空数组）：分层泳道的几何唯一来源，
    // 驱动按它画淡底泳道与左端层标签，不许从模块坐标反推（那是第二份布局）。
    Json.set(o, "lanes", JArr(archLaneRects(data, en)))
    // ── 职责视图（技术深度）：角色卡 / 角色泳道 / 角色边 / 职责违规数。
    // 恒发（空仓库给空数组）——驱动按数据画，缺席键会被读成旧版本。
    let roleArr = ArrayList<JsonValue>()
    for (g in data.roles) {
        if (g.files <= 0) { continue }   // 空角色不进数据（泳道也不画）
        let ro = Json.obj()
        // id = 角色号字符串：驱动的 findNode/依赖面板按 id 找节点（与模块 id 同一约定），
        // 没有 id 的节点，边端点解析全部落空（首测职责边一条都没画出来）。
        Json.set(ro, "id", Json.of(g.role.toString()))
        Json.set(ro, "role", Json.of(g.role))
        Json.set(ro, "name", Json.of(roleName(g.role, en)))
        Json.set(ro, "files", Json.of(g.files))
        Json.set(ro, "symbols", Json.of(g.symbols))
        Json.set(ro, "lines", Json.of(g.lines))
        Json.set(ro, "fanIn", Json.of(g.fanIn))
        Json.set(ro, "fanOut", Json.of(g.fanOut))
        Json.set(ro, "instability", Json.of(g.instability))
        Json.set(ro, "x", Json.of(g.x))
        Json.set(ro, "y", Json.of(g.y))
        Json.set(ro, "w", Json.of(g.w))
        Json.set(ro, "h", Json.of(g.h))
        Json.set(ro, "topFiles", Json.strArray(g.topFiles.toArray()))
        roleArr.add(ro)
    }
    Json.set(o, "roles", JArr(roleArr))
    Json.set(o, "roleLanes", JArr(archRoleLaneRects(data, en)))
    let reArr = ArrayList<JsonValue>()
    for (e in data.roleEdges) {
        let eo = Json.obj()
        Json.set(eo, "from", Json.of(e.fromId))
        Json.set(eo, "to", Json.of(e.toId))
        Json.set(eo, "weight", Json.of(e.weight))
        Json.set(eo, "violation", Json.of(e.violation))
        reArr.add(eo)
    }
    Json.set(o, "roleEdges", JArr(reArr))
    Json.set(o, "roleViolations", Json.of(data.roleViolationCount))
    Json.set(o, "warnings", warns)
    Json.set(o, "drilldown", dd)
    Json.set(o, "totalFiles", Json.of(data.totalFiles))
    Json.set(o, "totalSymbols", Json.of(data.totalSymbols))
    Json.set(o, "totalLines", Json.of(data.totalLines))
    Json.set(o, "truncated", Json.of(data.truncated))
    return o
}

// MARK: - Mermaid / DOT（agent 出口）

/// 模块 id → 图节点 id 的**唯一映射**（`M0` / `M1` …，按模块名排序）。
/// ⚠️ 不用「把非法字符替换成 `_`」：那会把**不同模块折叠成同一个节点**
/// （`a-b` 与 `a_b` 都 → `a_b`），于是两个模块在图上合并成一个、依赖边也糊在一起，
/// 而且**不报错**。模块名仍出现在节点标签里，可读性不丢。
func archNodeIds(data: ArchData): HashMap<String, String> {
    let sorted = ArrayList<ArchModule>()
    for (m in data.modules) { sorted.add(m) }
    insertionSortBy(sorted, { a, b => a.id < b.id })
    let map = HashMap<String, String>()
    var i: Int64 = 0
    for (m in sorted) {
        map[m.id] = "M${i}"
        i += 1
    }
    return map
}

func mermaidNodeId(ids: HashMap<String, String>, moduleId: String): String {
    match (ids.get(moduleId)) {
        case Some(v) => return v
        case None => return "M?"   // 理论上不会发生（边两端都来自 data.modules）
    }
}

public func archMermaid(data: ArchData, en: Bool): String {
    let ids = archNodeIds(data)
    let sb = StringBuilder()
    sb.append("flowchart LR\n")
    var i: Int64 = 0
    while (i < LAYER_COUNT) {
        let colMods = ArrayList<ArchModule>()
        for (m in data.modules) { if (m.layer == i) { colMods.add(m) } }
        insertionSortBy(colMods, { a, b => a.id < b.id })
        if (colMods.size > 0) {
            sb.append("  subgraph L${i}[\"${layerName(i, en)}\"]\n")
            for (m in colMods) {
                sb.append("    ${mermaidNodeId(ids, m.id)}[\"${m.id} · ${m.files}f/${m.symbols}s\"]\n")
            }
            sb.append("  end\n")
        }
        i += 1
    }
    // ⚠️ L5：治理标签原先硬编码中文（`⚠违规` / `环`）—— mermaid/dot 也接了
    // `en` 参数，英文模式下这两个字照样中文，输出成半英半中的图。文案只有一处
    // 来源（ArchUi），这里按 en 取。
    let violWord = if (en) { "violation" } else { "违规" }
    let cycleWord = if (en) { "cycle" } else { "环" }
    for (e in data.edges) {
        if (e.violation) {
            sb.append("  ${mermaidNodeId(ids, e.fromId)} -.->|⚠${violWord} ${e.weight}| ${mermaidNodeId(ids, e.toId)}\n")
        } else if (e.cycle) {
            sb.append("  ${mermaidNodeId(ids, e.fromId)} -->|${cycleWord} ${e.weight}| ${mermaidNodeId(ids, e.toId)}\n")
        } else {
            sb.append("  ${mermaidNodeId(ids, e.fromId)} -->|${e.weight}| ${mermaidNodeId(ids, e.toId)}\n")
        }
    }
    return sb.toString()
}

public func archDot(data: ArchData, en: Bool): String {
    let sb = StringBuilder()
    sb.append("digraph architecture {\n  rankdir=LR;\n  node [shape=box, style=\"rounded,filled\", fillcolor=\"#eef2ff\", color=\"#6366f1\", fontname=\"Helvetica\"];\n")
    // L5：dot 的节点标签原先反向硬编码英文 "files / symbols"（mermaid 那边是
    // 中文「文件/符号」）。同一张图两种语言的结果是半中半英 —— 文案只有一处
    // 来源（ArchUi），这里按 en 取。
    let nodeWordF = if (en) { "files" } else { "文件" }
    let nodeWordS = if (en) { "symbols" } else { "符号" }
    let violWord2 = if (en) { "violation" } else { "违规" }
    let cycleWord2 = if (en) { "cycle" } else { "环" }
    for (m in data.modules) {
        let label = "${m.id}\\n${m.files} ${nodeWordF} / ${m.symbols} ${nodeWordS}"
        sb.append("  \"${m.id}\" [label=\"${label}\", group=\"L${m.layer}\"];\n")
    }
    for (e in data.edges) {
        if (e.violation) {
            sb.append("  \"${e.fromId}\" -> \"${e.toId}\" [label=\"⚠${violWord2} ${e.weight}\", color=red, style=dashed];\n")
        } else if (e.cycle) {
            sb.append("  \"${e.fromId}\" -> \"${e.toId}\" [label=\"${cycleWord2} ${e.weight}\", color=orange];\n")
        } else {
            sb.append("  \"${e.fromId}\" -> \"${e.toId}\" [label=\"${e.weight}\", penwidth=${if (e.weight > 8) { 3 } else { if (e.weight > 3) { 2 } else { 1 } }}];\n")
        }
    }
    sb.append("}\n")
    return sb.toString()
}
