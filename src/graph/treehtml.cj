// graph/treehtml.cj — 代码图谱 HTML 交付物（单一画布，两级缩放）。
//
// 【形态】一张「代码图谱」画布承载全部信息，右侧详情侧栏。热力呈现不是
// 独立视图，而是代码图谱本身的着色系统：
//   · 模块层（layered 项目的入口）= 模块卡片（模块名 / F 文件 · S 符号 /
//     置信度指数大号数字 + 疑点 findings 小标），卡片底色 = 置信度色阶
//     （scoreHex(confIndex) 半透明填充）——模块层本身就是「模块热力图 +
//     流转」一体：跨模块引用边（宽 ∝ 权重）叠画在卡片之上。模块划分与
//     架构图共用 moduleOfPath 单一口径；指数 = confidenceScore(模块罚分,
//     模块文件数)，引擎算好随数据下发，页面不重算第二份。布局 = 按 id
//     排序的确定性网格，零随机零模拟。点卡片 → 下钻到该模块的代码层。
//   · 代码层 = 文件热力块 + 调用边合一：squarified treemap（确定性算法）
//     文件为叶子格（面积 ∝ 行数，颜色 = scoreHex(confidenceScore(该文件
//     罚分, 1))——confidence.cj 公开公式的「单文件视角」，驱动侧 confScore
//     是它的唯一实现），大格内再按符号行距细分符号格（色 = 疑点档位
//     tierHex——「代码本身的置信度」）；文件间调用边叠画在热力块之上，
//     宽 ∝ 权重、箭头指调用方向，hover 高亮该边与两端块。layered 下只画
//     当前模块的文件与两端都在本模块的边（引擎 archRefEdges 架构口径）；
//     compact 直接画全仓文件与全部边。符号调用树画布已退役：关系全量
//     在详情「关系」tab，符号级置信度在「源码」tab 的疑点行高亮，搜索 /
//     jumpTo 定位文件块并打开详情。
//   · 分级（projectTier）决定入口：layered（大项目，文件/符号任一超阈值）
//     进模块层；compact（小项目）直接代码层。顶栏 chip 披露当前分级与
//     触发阈值（如「分级：模块级（54 文件 > 30）」）——阈值不披露，用户
//     就无法解释自己为什么落在模块级。面包屑「← 模块层 · 模块名」往返两级。
//
// 【堆叠纪律】布局块 = 顶栏 + 主行（stage + 详情侧栏）+ 图例脚注；绝对定位
// 浮层只有两个：画布 tooltip 与窄屏（<880px）覆盖式详情侧栏。独立滚动区
// 只有详情侧栏一处；主画布不平铺滚动（代码层 treemap 按画布尺寸整幅铺排）。
//
// 【Canvas 纪律】一切绘制走平台 Canvas API 的公共子集（export.cj 的
// CANVAS2D_SUBSET）：HTML 驱动只调子集内方法，同一渲染逻辑才能逐项映射到
// SwiftUI GraphicsContext / Qt QPainter / 仓颉 Canvas——渲染器不绑定任何
// 具体实现，按平台自动适配。子集外方法（二次曲线 / measureText / clearRect /
// save/restore 等）一律不用，契约测试负向断言钉死。
//
// 【详情侧栏】源码（引擎契约截 40 行 + 四类着色）/ 置信度（按维度分节）/
// 关系（调用方/被调**全量**可扫读清单，点击定位到对方的文件块）三个文字
// tab——文字内容保持 DOM（可扫读、可键盘、可复制），不属于「绘制」范畴。
//
// 【数据】`graph tree --json` 契约 + functionGraphData（函数/调用边带 tier/
// 实码，服务详情侧栏与定位）+ confidence（分数/astNote 降级说明/按文件罚分
// 表/平铺 findings 带证据与维度）+ 模块层三块：graphModules（按模块聚合的
// files/symbols/lines/penalty/findings/confIndex，键恒发）、graphModuleEdges
// （archRefEdges 架构可信口径按模块对聚合的权重，禁用 refEdges 反推）、
// fileModules（引擎算好的逐文件模块归属——驱动的下钻与代码层过滤查表，不做
// 第二份划分实现）+ archRefEdges 文件级三元组（代码层调用边叠画的唯一数据源，
// 与模块边同一架构判据）。引擎单独跑或被 agent 驱动时只产出本 HTML，
// 无其他渲染通道。
package moongit.graph

import std.collection.*
import moongit.util.*

// MARK: - 分级阈值（treehtml 顶部：三视图的默认落点由它们决定）

/// 代码级（compact）阈值：文件数与符号数**都不超**阈值 → 小项目，默认直接进
/// 代码级（符号调用树）；任一严格超限 → 模块级（layered），默认先看模块卡片。
/// 两个常量随 payload 恒发（compactMaxFiles / compactMaxSymbols），页面把
/// 「当前分级 + 阈值」披露给用户——阈值不披露，用户无法解释自己为什么落在
/// 模块级（恒发纪律同 depth/depthOmitted：缺键会被读成旧版本没有该字段）。
public let COMPACT_MAX_FILES: Int64 = 30
public let COMPACT_MAX_SYMBOLS: Int64 = 600

/// 分级纯函数。边界归属：恰好等于阈值 = 不超 = compact（「超」是严格大于）。
public func tierOf(files: Int64, symbols: Int64): String {
    if (files <= COMPACT_MAX_FILES && symbols <= COMPACT_MAX_SYMBOLS) { return "compact" }
    return "layered"
}

// MARK: - 函数级图谱数据（代码图谱 × 置信度的结合点）

/// 函数级节点/调用边/异常实码。边 = 「函数体 → 被调函数」（词法近似：
/// 函数体内自由调用按名匹配全局定义）；置信度 findings 按所在函数聚合，
/// 异常函数内嵌实码片段（截 40 行，页面点击即看）。
///
/// 每条边自带确信度分层 tier（codereviewgraph 的 edge confidence 概念）：
///   direct   = 调用方所在文件就有该名字的定义（词法上看得见，最确定）
///   resolved = 跨文件且候选集中该名字只有一个定义（唯一命中）
///   guessed  = 无同文件定义且候选集中有多个同名定义，按序取了首个
///              （词法近似的固有不确定）
/// 同文件可见定义**优先于**全库重名判定：全库别处还有同名定义不否定
/// 「本文件里看得见的那一份」——否则同文件调用被画成虚线、边目标指向
/// 任意另一处定义，与 direct 的语义自述矛盾。页面把 guessed 画成虚线——
/// 不确定的关系必须看起来不确定。
public func functionGraphData(graph: CodeGraph, findings: ConfidenceReport, en: Bool): JsonValue {
    // 对外签名恒为全量（depth 0）——cli.cj / mcp.cj 的既有调用面零改动（契约D）
    return functionGraphDataD(graph, findings, en, 0)
}

/// 带目录深度上限的函数域构造（契约D）。maxDepth<=0 = 不截断；>0 时函数 /
/// 调用边 / 实码只含 dirDepthOf(relPath) <= maxDepth 的文件，与 fullGraphJson
/// 的文件树同一口径。原实现 --depth 只过滤文件树数据、函数域遍历全部文件——
/// 同一份 HTML 两个数据域口径不同：depth 外符号画得出、悬停有反馈，而点击 /
/// 回车 / 搜索 / 公开 API setFocus 全部静默无反应。callee 候选同样限制在深度
/// 内，否则边会指向函数清单里不存在的端点——点它照样没反应。
func functionGraphDataD(graph: CodeGraph, findings: ConfidenceReport, en: Bool, maxDepth: Int64): JsonValue {
    let idx = graph.symbolIndex()
    let out = Json.obj()
    let fns = ArrayList<JsonValue>()
    let edgeAgg = HashMap<String, Int64>()
    let edgeTier = HashMap<String, String>()
    let byFile = HashMap<String, ArrayList<JsonValue>>()
    // 深度内文件集一次算完：函数体每一行的每个自由调用都要查候选定义，
    // 预建索引避免逐行重复算 dirDepthOf
    let inDepth = HashMap<String, Bool>()
    for (fe0 in graph.files) {
        inDepth[fe0.relPath] = maxDepth <= 0 || dirDepthOf(fe0.relPath) <= maxDepth
    }
    func keeps(p: String): Bool {
        match (inDepth.get(p)) {
            case Some(v) => v
            case None => false
        }
    }
    for (f in findings.findings) {
        let o = Json.obj()
        Json.set(o, "line", Json.of(f.line))
        Json.set(o, "weight", Json.of(flawWeight(f.kind)))
        Json.set(o, "kind", Json.of(flawId(f.kind)))
        // 树节点内嵌的 finding 必须与 confidenceEmbedJson 字段对齐：
        // 详情栏置信度 tab 按 dim 分组、渲染 label 与 evidence，
        // 缺一个字段整组渲染就落空（验收时曾因此空白）。
        Json.set(o, "dim", Json.of(dimensionId(flawDimension(f.kind))))
        Json.set(o, "label", Json.of(flawLabel(f.kind, en)))
        Json.set(o, "evidence", Json.of(f.evidence))
        match (byFile.get(f.file)) {
            case Some(list) => list.add(o)
            case None => byFile[f.file] = ArrayList<JsonValue>([o])
        }
    }
    let snippets = Json.obj()
    for (fe in graph.files) {
        // 与 fullGraphJson 完全相同的深度判定：两个数据域必须同口径
        if (!keeps(fe.relPath)) { continue }
        let content = readFileText(graph.root + "/" + fe.relPath)
        let srcLines = ArrayList<String>()
        match (content) {
            case Some(t) =>
                for (l in t.split("\n")) { srcLines.add(l) }
            case None => ()
        }
        let fileFindings = byFile.get(fe.relPath)
        let syms = fe.symbols
        var i: Int64 = 0
        while (i < Int64(syms.size)) {
            let s = syms[i]
            let bodyStart = s.line
            let bodyEnd = if (i + 1 < Int64(syms.size)) { syms[i + 1].line - 1 } else { Int64(srcLines.size) }
            let id = "f:" + fe.relPath + ":" + s.line.toString() + ":" + s.name
            let fd = ArrayList<JsonValue>()
            var maxW: Int64 = 0
            match (fileFindings) {
                case Some(list) =>
                    for (o in list) {
                        let ln = Json.intAt(o, "line", 0)
                        if (ln >= bodyStart && ln <= bodyEnd) {
                            fd.add(o)
                            let w = Json.intAt(o, "weight", 0)
                            if (w > maxW) { maxW = w }
                        }
                    }
                case None => ()
            }
            var j = bodyStart - 1
            while (j < bodyEnd && j < Int64(srcLines.size)) {
                let stripped = srcLines[j]
                if (!stripped.isEmpty()) {
                    for ((cname, _) in freeCallsIn(stripped)) {
                        if (cname == s.name) { continue }
                        match (idx.get(cname)) {
                            case Some(defs) =>
                                // callee 候选限制在深度内：边两端都必须是页面
                                // 可见数据域里的函数（超出的一律不解析成边）
                                var cand = defs
                                if (maxDepth > 0) {
                                    let kept = ArrayList<(String, SymDecl)>()
                                    for (d in defs) {
                                        if (keeps(d[0])) { kept.add(d) }
                                    }
                                    cand = kept
                                }
                                if (Int64(cand.size) > 0) {
                                    // 同文件可见定义优先：先找 dfile==fe.relPath
                                    // 的候选，命中则边指向它且 tier=direct——
                                    // 全库重名不再一票压过同文件（否则同文件调用
                                    // 被判 guessed 虚线、边目标指向按序排列的
                                    // 任意首个定义）
                                    var sameIdx: Int64 = -1
                                    var k: Int64 = 0
                                    while (k < Int64(cand.size)) {
                                        let (df, _) = cand[k]
                                        if (df == fe.relPath) { sameIdx = k; break }
                                        k += 1
                                    }
                                    let pick = if (sameIdx >= 0) { sameIdx } else { 0 }
                                    let (dfile, ddecl) = cand[pick]
                                    let calleeId = "f:" + dfile + ":" + ddecl.line.toString() + ":" + cname
                                    if (calleeId != id) {
                                        let ek = id + "=>" + calleeId
                                        // tier 按 (调用方, 被调) 解析结果唯一确定；
                                        // 同名 callee 的多次调用解析相同，记一次即可
                                        if (!edgeTier.contains(ek)) {
                                            let tier = if (sameIdx >= 0) { "direct" }
                                                else if (Int64(cand.size) > 1) { "guessed" }
                                                else { "resolved" }
                                            edgeTier[ek] = tier
                                        }
                                        match (edgeAgg.get(ek)) {
                                            case Some(v) => edgeAgg[ek] = v + 1
                                            case None => edgeAgg[ek] = 1
                                        }
                                    }
                                }
                            case None => ()
                        }
                    }
                }
                j += 1
            }
            let o = Json.obj()
            Json.set(o, "id", Json.of(id))
            Json.set(o, "file", Json.of(fe.relPath))
            Json.set(o, "name", Json.of(s.name))
            Json.set(o, "kind", Json.of(symKindId(s.kind)))
            Json.set(o, "line", Json.of(s.line))
            Json.set(o, "lang", Json.of(detectLang(fe.relPath)))
            Json.set(o, "findings", JArr(fd))
            Json.set(o, "weight", Json.of(maxW))
            // 实码是否命中引擎 40 行截断契约（graph-scene-schema.md:70-76：截断必须披露）
            Json.set(o, "trunc", Json.of(bodyEnd - bodyStart + 1 > 40))
            var code = StringBuilder()
            var cl = bodyStart - 1
            while (cl < bodyEnd && cl < Int64(srcLines.size) && cl < bodyStart + 39) {
                code.append(srcLines[cl]); code.append("\n")
                cl += 1
            }
            Json.set(snippets, id, Json.of(code.toString()))
            fns.add(o)
            i += 1
        }
    }
    let sorted = ArrayList<(String, Int64)>()
    for ((ek, w) in edgeAgg) { sorted.add((ek, w)) }
    insertionSortBy(sorted, { a, b => a[0] < b[0] })
    let ea = ArrayList<JsonValue>()
    for (p in sorted) {
        let segs = p[0].split("=>")
        if (segs.size == 2) {
            let tv = match (edgeTier.get(p[0])) {
                case Some(v) => v
                case None => "resolved"
            }
            let e = Json.obj()
            Json.set(e, "from", Json.of(segs[0]))
            Json.set(e, "to", Json.of(segs[1]))
            Json.set(e, "w", Json.of(p[1]))
            Json.set(e, "tier", Json.of(tv))
            ea.add(e)
        }
    }
    Json.set(out, "functions", JArr(fns))
    Json.set(out, "functionEdges", JArr(ea))
    Json.set(out, "codeSnippets", snippets)
    return out
}

// MARK: - 置信度内嵌（详情侧栏「置信度」tab + 热力图着色的数据源）

/// 置信度报告的页面内嵌形态：分数（顶栏分数 chip）+ astNote（astUsed=false
/// 时降级披露，审计 M2：不可静默）+ 按文件罚分表（热力图着色的**唯一口径
/// 来源**——客户端不许拿 findings 重算第二份罚分）+ 平铺 findings（每条带
/// 证据与维度，证据必须自足——人不开编辑器就能判断，confidence.cj 注释原话）。
/// 限流披露两个布尔：全量 400 条封顶 / 同类每文件 6 条封顶
/// （CONF_MAX_FINDINGS / CONF_MAX_PER_KIND_PER_FILE，confidence.cj）。
/// confidence 块的**唯一构造点**（内嵌 HTML 与持久化 confidence.json 共用同一形状）。
/// public：`confidence gen`（cli 包）持久化 confidence.json 时复用本函数——
/// 消费端（render index --confidence）期望的就是这个形状，抄第二份必然漂移。
public func confidenceEmbedJson(conf: ConfidenceReport, en: Bool): JsonValue {
    let o = Json.obj()
    Json.set(o, "score", Json.of(conf.score))
    Json.set(o, "astUsed", Json.of(conf.astUsed))
    Json.set(o, "astNote", Json.of(conf.astNote))
    // 限流披露用引擎真值（analyzeConfidence 在真实丢弃处置位）：拿结果集
    // 反推会把「恰好达到阈值但未截断」误报成「超出已汇总」
    Json.set(o, "cappedTotal", Json.of(conf.cappedTotal))
    Json.set(o, "cappedKind", Json.of(conf.cappedKind))
    // 按文件罚分表：引擎已按罚分降序排好（ConfidenceReport.files），
    // 原样下发，热力图与图例共用这一份口径
    let fs2 = ArrayList<JsonValue>()
    for ((path, pen) in conf.files) {
        let d = Json.obj()
        Json.set(d, "file", Json.of(path))
        Json.set(d, "penalty", Json.of(pen))
        fs2.add(d)
    }
    Json.set(o, "files", JArr(fs2))
    let fs = ArrayList<JsonValue>()
    for (f in conf.findings) {
        let d = Json.obj()
        Json.set(d, "file", Json.of(f.file))
        Json.set(d, "line", Json.of(f.line))
        Json.set(d, "kind", Json.of(flawId(f.kind)))
        Json.set(d, "weight", Json.of(flawWeight(f.kind)))
        Json.set(d, "dim", Json.of(dimensionId(flawDimension(f.kind))))
        Json.set(d, "label", Json.of(flawLabel(f.kind, en)))
        Json.set(d, "symbol", Json.of(f.symbol))
        Json.set(d, "evidence", Json.of(f.evidence))
        fs.add(d)
    }
    Json.set(o, "findings", JArr(fs))
    return o
}

/// 语言点色（热力图文件格的语言圆点）：沿用 scene 契约 themes.langs 的
/// 既有 token（graph-scene-schema.md；色值只有 archscene.cj 的
/// langThemeColors 一份构造点，本函数派生页面形态），不新增色相。
/// 无 token 的语言由页面回退中性灰。
func langThemesJson(): JsonValue {
    let th = Json.obj()
    Json.set(th, "dark", langsTokenJson(true))
    Json.set(th, "light", langsTokenJson(false))
    return th
}

// MARK: - 模块层（大项目先看模块：哪个模块、多可信、依赖流向哪）

/// 模块层数据（payload 的 graphModules）。三条单一口径，各只此一份：
///   · 划分 = arch.cj 的 moduleOfPath（与架构图同一份，本包不许出现第二份实现）；
///   · penalty / findings = conf.files / conf.findings（引擎按文件罚分表）按
///     模块聚合，模块归属走同一个 moduleOfPath；
///   · confIndex = confidenceScore(模块罚分, 模块文件数)（confidence.cj 公开
///     公式）——消费方拿现成值渲染，不许重算第二份。
/// 全部键恒发（0 也发）：零罚分/无疑点是「这个模块可信」的证据，缺键会被
/// 读成旧版本没有该字段。出口按 id 升序排定（确定性纪律同 archJson 的 M11）。
func graphModulesJson(graph: CodeGraph, findings: ConfidenceReport): JsonValue {
    let order = ArrayList<String>()
    let indexOf = HashMap<String, Int64>()
    let mFiles = ArrayList<Int64>()
    let mSymbols = ArrayList<Int64>()
    let mLines = ArrayList<Int64>()
    for (f in graph.files) {
        let m = moduleOfPath(f.relPath)
        var at: Int64 = -1
        match (indexOf.get(m)) {
            case Some(v) => at = v
            case None =>
                at = Int64(order.size)
                indexOf[m] = at
                order.add(m)
                mFiles.add(0)
                mSymbols.add(0)
                mLines.add(0)
        }
        mFiles[at] = mFiles[at] + 1
        mSymbols[at] = mSymbols[at] + Int64(f.symbols.size)
        mLines[at] = mLines[at] + f.lines
    }
    let mPenalty = HashMap<String, Int64>()
    for ((path, pen) in findings.files) {
        let m = moduleOfPath(path)
        match (mPenalty.get(m)) {
            case Some(v) => mPenalty[m] = v + pen
            case None => mPenalty[m] = pen
        }
    }
    let mFindings = HashMap<String, Int64>()
    for (fd in findings.findings) {
        let m = moduleOfPath(fd.file)
        match (mFindings.get(m)) {
            case Some(v) => mFindings[m] = v + 1
            case None => mFindings[m] = 1
        }
    }
    insertionSortBy(order, { a, b => a < b })
    let out = ArrayList<JsonValue>()
    for (id in order) {
        var at: Int64 = 0
        match (indexOf.get(id)) {
            case Some(v) => at = v
            case None => ()
        }
        var pen: Int64 = 0
        match (mPenalty.get(id)) {
            case Some(v) => pen = v
            case None => ()
        }
        var fnd: Int64 = 0
        match (mFindings.get(id)) {
            case Some(v) => fnd = v
            case None => ()
        }
        let o = Json.obj()
        Json.set(o, "id", Json.of(id))
        Json.set(o, "files", Json.of(mFiles[at]))
        Json.set(o, "symbols", Json.of(mSymbols[at]))
        Json.set(o, "lines", Json.of(mLines[at]))
        Json.set(o, "penalty", Json.of(pen))
        Json.set(o, "findings", Json.of(fnd))
        Json.set(o, "confIndex", Json.of(confidenceScore(pen, mFiles[at])))
        out.add(o)
    }
    return JArr(out)
}

/// 文件 → 模块映射（引擎算好的同一份 moduleOfPath 结果随数据下发）。驱动的
/// 下钻（点卡片聚焦模块内符号）与热力图目录标签一律查这张表，不做第二份
/// 划分实现——划分逻辑若变，页面跟着引擎走而不是各说各话。
func fileModulesJson(graph: CodeGraph): JsonValue {
    let o = Json.obj()
    for (f in graph.files) {
        Json.set(o, f.relPath, Json.of(moduleOfPath(f.relPath)))
    }
    return o
}

/// 跨模块引用边（payload 的 graphModuleEdges）= graph.archRefEdges（架构
/// 可信口径：顶格公开声明 + 跨模块歧义剔除，不含注释/字符串假边，D2 引入）
/// 按 moduleOfPath 聚合的模块对权重。**不许用 refEdges 反推**——引用口径的
/// 同名噪音（doc 注释提及他包符号、strx 同族合法重名）会把毫不相干的模块
/// 连成假依赖（arch.cj 同一结论）。自模块对不成边——跨模块边没有自环语义。
/// 出口按 from↑ → to↑ 全序（HashMap 物化后立即排定，确定性纪律同 M11）。
func graphModuleEdgesJson(graph: CodeGraph): JsonValue {
    // moduleOfPath 的 split 结果缓存：每条边两端各一次 ⇒ 2E 次 split → 每文件一次
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
    let weight = HashMap<String, Int64>()
    let pairs = ArrayList<(String, String)>()
    for ((from, to, w) in graph.archRefEdges) {
        let a = modAt(from)
        let b = modAt(to)
        if (a == b) { continue }
        let key = a + "|" + b
        match (weight.get(key)) {
            case Some(v) => weight[key] = v + w
            case None =>
                weight[key] = w
                pairs.add((a, b))
        }
    }
    insertionSortBy(pairs, { a, b =>
        if (a[0] != b[0]) { return a[0] < b[0] }
        return a[1] < b[1]
    })
    let out = ArrayList<JsonValue>()
    for ((a, b) in pairs) {
        var w: Int64 = 0
        match (weight.get(a + "|" + b)) {
            case Some(v) => w = v
            case None => ()
        }
        let o = Json.obj()
        Json.set(o, "from", Json.of(a))
        Json.set(o, "to", Json.of(b))
        Json.set(o, "w", Json.of(w))
        out.add(o)
    }
    return JArr(out)
}

/// 文件级调用边（payload 的 archRefEdges）= CodeGraph.archRefEdges 原样下发
/// （from/to = 相对路径，w = 命中的不同符号名个数）。代码层把「谁调谁」叠画
/// 在文件热力块上，数据源必须是架构口径：与 graphModuleEdges 同一判据，
/// **不许用 refEdges 反推**——引用口径的同名噪音会把毫不相干的文件连成假边
/// （arch.cj 同一结论）。物化处（build.cj）已按 from↑ → to↑ → count↑ 全序
/// 排定并有源码守卫钉住，这里照抄不再排序（第二份排序 = 第二份口径）。
/// 恒发（空数组也发）：「没有跨文件调用」是一个有意义的事实，缺键会被读成
/// 旧版本没有该字段。
func fileArchEdgesJson(graph: CodeGraph): JsonValue {
    let out = ArrayList<JsonValue>()
    for ((from, to, w) in graph.archRefEdges) {
        let o = Json.obj()
        Json.set(o, "from", Json.of(from))
        Json.set(o, "to", Json.of(to))
        Json.set(o, "w", Json.of(w))
        out.add(o)
    }
    return JArr(out)
}

// MARK: - HTML 交付物（单一代码图谱画布 + 详情侧栏）
//
// 【两段拆分】payload 构建（indexPayload）与模板渲染（renderIndexHtml）
// 是两个独立阶段：index gen 把 payload 持久化成 index.json（db 是核心、
// json 是渲染派生），render index 用**持久化的 payload** 直接渲染——
// 绘图不重算图谱。treeCanvasHtml 保持旧签名 = 两段的组合（临时 payload、
// 零持久化副作用），旧 `graph tree --format html` 行为不变。

/// treeCanvasHtml 内嵌 payload 的唯一构建点（gen 持久化与兼容面共用）。
/// 键集：fullGraphJson 的 11 契约键 + functionGraph / confidence /
/// langThemes / project / graphModules / graphModuleEdges / fileModules /
/// archRefEdges / projectTier / tierFiles / tierSymbols / compactMaxFiles /
/// compactMaxSymbols。tier 口径 = depth 过滤后的文件集（从已生成的
/// files 读回计数，不重抄 depth 判定——第二份口径必然漂移）。
public func indexPayload(graph: CodeGraph, depth: Int64, findings: ConfidenceReport, en: Bool): JsonValue {
    let root = fullGraphJson(graph, depth)
    // 函数域与文件树共用同一个 depth（契约D）：同一份 HTML 不允许两个
    // 数据域各说各话——depth 外的符号在页面上画得出却点不动
    Json.set(root, "functionGraph", functionGraphDataD(graph, findings, en, depth))
    Json.set(root, "confidence", confidenceEmbedJson(findings, en))
    Json.set(root, "langThemes", langThemesJson())
    Json.set(root, "project", Json.of(basename(graph.root)))
    // 模块层 + 分级（大项目先看模块：哪个模块、多可信、依赖流向哪）
    Json.set(root, "graphModules", graphModulesJson(graph, findings))
    Json.set(root, "graphModuleEdges", graphModuleEdgesJson(graph))
    Json.set(root, "fileModules", fileModulesJson(graph))
    // 文件级调用边（架构口径）：代码层叠画的「谁调谁」
    Json.set(root, "archRefEdges", fileArchEdgesJson(graph))
    var tierFiles: Int64 = 0
    var tierSymbols: Int64 = 0
    for (f in Json.arrAt(root, "files")) {
        tierFiles += 1
        tierSymbols += Int64(Json.arrAt(f, "symbols").size)
    }
    Json.set(root, "projectTier", Json.of(tierOf(tierFiles, tierSymbols)))
    Json.set(root, "tierFiles", Json.of(tierFiles))
    Json.set(root, "tierSymbols", Json.of(tierSymbols))
    Json.set(root, "compactMaxFiles", Json.of(COMPACT_MAX_FILES))
    Json.set(root, "compactMaxSymbols", Json.of(COMPACT_MAX_SYMBOLS))
    return root
}

/// index gen 的持久化 payload = 渲染 payload + 探针/版本/时间三键。
/// updateCount 单调递增（重建 = 旧值+1，首版 0）：渲染复用判定靠它区分
/// 「index 变了」与「index 没变」——若 gen 重置为 0，旧 render 的 0 会
/// 假匹配，陈旧产物被当成新产物复用。
public func indexPayloadForStore(graph: CodeGraph, depth: Int64, findings: ConfidenceReport,
                                 probe: SourceProbe, updateCount: Int64,
                                 generatedAt: String, en: Bool): JsonValue {
    let p = indexPayload(graph, depth, findings, en)
    Json.set(p, "probe", probe.toJson())
    Json.set(p, "updateCount", Json.of(updateCount))
    Json.set(p, "generatedAt", Json.of(generatedAt))
    return p
}

/// `index gen --format json` 的机读出口键集：
/// 11 契约键（fullGraphJson，一字不动）+ 新增恒发键。
/// 键集只有这一份清单（出口投影与键集测试都引它，两处各抄必漂移）。
public let INDEX_JSON_KEYS: Array<String> = [
    // 11 契约键（graph tree --json 同名同义）
    "root", "files", "importEdges", "referenceEdges", "truncated", "skipped",
    "oversizeSkipped", "unreadableDirs", "unreadableDirsTruncated", "depth", "depthOmitted",
    // 新增恒发键
    "graphModules", "graphModuleEdges", "fileModules", "projectTier",
    "tierFiles", "tierSymbols", "compactMaxFiles", "compactMaxSymbols",
    "probe", "updateCount", "generatedAt",
]

/// 从持久化 payload 投影机读出口（键集 = INDEX_JSON_KEYS，恒发——
/// 「没有截断」「没有 unreadable 目录」与「读不到」在键集上不可区分的
/// 事故已经发生过，缺键会被读成旧版本没有该字段）。
public func indexContractJson(payload: JsonValue): JsonValue {
    let o = Json.obj()
    for (k in INDEX_JSON_KEYS) {
        Json.set(o, k, Json.getOr(payload, k))
    }
    return o
}

/// 三参形态（规格签名）：不带 confMissing 标记的常规渲染。
public func renderIndexHtml(payload: JsonValue, confOpt: Option<JsonValue>, en: Bool): String {
    return renderIndexHtml(payload, confOpt, en, false)
}

/// 模板渲染段：payload JSON → 单文件 HTML。
/// **纯函数**：同 payload + 同 conf 覆盖 + 同 confMissing ⇒ 逐字节一致
///（确定性纪律：布局零随机、驱动无模板字面量、数据经 jsonSafeForEmbed）。
///
/// confOpt = `render index --confidence` 的置信度覆盖（confidence.json
/// 读到就替换 payload 的 confidence 键；None = 不动——「没有就放着」，
/// 页面吃 payload 里的生成时摘要或驱动自身的兜底）。
/// confMissing = --confidence 指定但 confidence.json 缺席：payload 打上
/// confMissing 标记，图例恒发一行「无置信度数据」说明——不伪造分数、
/// 不伪造 findings，只如实说这一页没有置信度数据可看。
///
/// payload 带 updateCount 时（index 持久化产物）在 HTML 注释里内嵌
/// updateCount 与 generatedAt，供复用判定比对；graph tree 的临时 payload
/// 没有这两个键，注释缺席（兼容面产物形状不变）。
public func renderIndexHtml(payload: JsonValue, confOpt: Option<JsonValue>, en: Bool,
                            confMissing: Bool): String {
    let root = payload
    match (confOpt) {
        case Some(c) => Json.set(root, "confidence", c)
        case None => ()
    }
    if (confMissing) {
        Json.set(root, "confMissing", Json.of(true))
    }
    // 驱动双语：en 进 payload（applyTexts 用 T 表覆盖模板静态中文）
    Json.set(root, "en", Json.of(en))
    let json = jsonSafeForEmbed(Json.pretty(root))
    let title = if (en) { "Code Graph" } else { "代码图谱" }
    // 文件数进 <title>：从 payload 读回（兼容面与持久化面同一个来源）
    var fileCount: Int64 = 0
    for (_ in Json.arrAt(root, "files")) { fileCount += 1 }
    // 持久化产物的自报家门（复用判定比对的就是这一行）
    var metaComment = ""
    if (Json.has(root, "updateCount")) {
        metaComment = "<!-- moongit index render · updateCount=" +
            Int64(Json.intAt(root, "updateCount", 0)).toString() +
            " · generatedAt=" + Json.strAt(root, "generatedAt", "") + " -->\n"
    }
    let langTag = if (en) { "en" } else { "zh-CN" }
    let sb = StringBuilder()
    sb.append("<!DOCTYPE html>\n${metaComment}<html lang=\"${langTag}\">\n<head>\n<meta charset=\"UTF-8\">\n")
    sb.append("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n")
    sb.append("<meta name=\"generator\" content=\"moonGit graph tree (Cangjie engine, deterministic layout)\">\n")
    sb.append("<title>${title} · ${fileCount} files</title>\n")
    sb.append("""
<style>
:root{--bg:#080d17;--panel:#101927;--panel2:#142031;--line:#2a3c52;--line2:#202e42;--text:#eaf3ff;--muted:#91a5bd;--muted2:#687f9a;--green:#59f0b8;--yellow:#ffc857;--red:#ff6b8a;--cyan:#5fdcff;--violet:#b69cff;--blue:#82a8ff;--radius:13px;--mono:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,monospace;--sans:Inter,-apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif}
*{box-sizing:border-box}html,body{margin:0;width:100%;height:100%;background:var(--bg);color:var(--text);font-family:var(--sans);overflow:hidden}button,input,select{font:inherit}button{cursor:pointer}button:focus-visible,input:focus-visible,select:focus-visible{outline:2px solid #6d9cff;outline-offset:2px}.app{height:100vh;min-height:560px;display:flex;flex-direction:column;background:radial-gradient(ellipse at 40% -20%,rgba(49,93,130,.16),transparent 43%),var(--bg)}
.topbar{height:60px;flex-shrink:0;border-bottom:1px solid var(--line2);display:flex;align-items:center;gap:18px;padding:0 22px;background:linear-gradient(100deg,rgba(12,19,32,.97),rgba(13,21,35,.94) 48%,rgba(12,18,29,.97));box-shadow:0 5px 22px rgba(0,0,0,.15)}.brandmark{width:31px;height:31px;border-radius:9px;background:linear-gradient(135deg,#86f7cf 0%,#54d8dd 48%,#809bff 100%);display:grid;place-items:center;color:#061713;box-shadow:0 0 20px rgba(90,219,235,.2),inset 0 1px 0 #ffffff88;animation:brandBreath 4.6s ease-in-out infinite}.brandmark svg{width:21px;height:21px}.brand{display:flex;align-items:center;gap:10px;min-width:225px}.brand h1{font-size:13px;letter-spacing:.105em;margin:0;font-weight:800}.brand small{font-size:10px;color:var(--muted);letter-spacing:.13em;display:block;margin-top:3px}.vdiv{width:1px;height:29px;background:var(--line)}.project-select{display:flex;align-items:center;gap:10px;min-width:175px;color:#c5d0dc}.project-avatar{width:27px;height:27px;border-radius:7px;background:linear-gradient(145deg,#1b3446,#202842);color:#7ae9ef;display:grid;place-items:center;font:700 11px var(--mono);border:1px solid #315166;box-shadow:inset 0 0 14px #58d4f012}.project-select strong{display:block;font-size:12px}.project-select small{display:block;font-size:10px;color:var(--muted);margin-top:3px}.tierchip{font:10px var(--mono);color:#8292a6;border:1px solid #263547;border-radius:5px;padding:4px 6px;margin-left:2px}.top-spacer{flex:1}.top-metric{display:flex;align-items:center;gap:9px;padding-right:7px}.score-donut{width:36px;height:36px;border-radius:50%;display:grid;place-items:center;background:conic-gradient(var(--green) 0 84%,#25333d 84%);position:relative;filter:drop-shadow(0 0 9px #59f0b82a);animation:donutBreath 3.8s ease-in-out infinite}.score-donut:before{content:"";position:absolute;inset:4px;border-radius:50%;background:#101720}.score-donut b{position:relative;font:700 10px var(--mono)}.top-metric label{font-size:10px;color:var(--muted);display:block}.top-metric strong{font:700 16px var(--mono);display:block;margin-top:3px;text-shadow:0 0 16px #59f0b81c}.primary-btn,.ghost-btn,.icon-btn,.tab-btn,.tiny-btn{border:1px solid var(--line);background:#121b25;color:#cdd8e4;border-radius:7px;transition:.15s}.primary-btn{padding:9px 12px;background:#17392f;border-color:#285847;color:#7ee6b5;font-size:11px;font-weight:700}.primary-btn:hover{background:#1d4a3c}.ghost-btn{padding:8px 11px;font-size:11px}.ghost-btn:hover,.icon-btn:hover,.tiny-btn:hover{border-color:#466077;background:#192633}.icon-btn{width:30px;height:30px;display:grid;place-items:center;font-size:15px}
.toolbar{height:54px;flex-shrink:0;display:flex;align-items:center;gap:11px;padding:0 22px;border-bottom:1px solid var(--line2);background:#0d131b}.tool-group{display:flex;align-items:center;gap:7px}.tool-label{font-size:10px;color:var(--muted);white-space:nowrap}.search-wrap{height:33px;width:224px;display:flex;align-items:center;gap:8px;padding:0 10px;background:#111b26;border:1px solid #293847;border-radius:7px}.search-wrap svg{width:14px;height:14px;color:#6f8297;flex-shrink:0}.search-wrap input{width:100%;background:none;border:0;outline:none;color:#dce7f1;font-size:11px}.search-wrap input::placeholder{color:#5e7185}.search-results{position:absolute;top:37px;left:0;right:0;background:#111b26;border:1px solid #344a5e;border-radius:8px;z-index:30;box-shadow:0 12px 35px #0009;overflow:hidden}.search-results button{width:100%;text-align:left;background:none;border:0;color:#cfdae6;padding:9px 10px;font-size:11px;display:flex;justify-content:space-between}.search-results button:hover{background:#1b2a38}.search-position{position:relative}.separator{height:22px;width:1px;background:#263342;margin:0 3px}.select{height:33px;background:#111b26;color:#c4d0dc;border:1px solid #2a3949;border-radius:7px;padding:0 9px;font-size:11px;max-width:170px}.threshold{display:flex;align-items:center;gap:9px;width:184px}.threshold input{width:98px;accent-color:#52dca4;height:3px}.threshold .num{font:11px var(--mono);color:#d2e0eb;min-width:24px}.mode-toggle{display:flex;gap:2px;padding:3px;background:#101923;border:1px solid #253342;border-radius:8px}.layout-chip{display:inline-flex;align-items:center;gap:6px;padding:6px 9px;border-radius:5px;background:linear-gradient(110deg,#15352f,#202a43);border:1px solid #2e675e;color:#9aefd7;font-size:10px;white-space:nowrap;box-shadow:inset 0 0 12px #59f0b80b}.toolbar-spacer{flex:1}.view-label{font-size:10px;color:#8a9aac}.status-dot{display:inline-block;width:6px;height:6px;border-radius:50%;background:var(--green);margin-right:5px;box-shadow:0 0 8px #59f0b855;animation:statusPulse 2.2s ease-in-out infinite}
.main{min-height:0;flex:1;display:grid;grid-template-columns:minmax(420px,1fr) 368px;gap:0}.graph-area{min-width:0;min-height:0;display:flex;flex-direction:column;position:relative;border-right:1px solid var(--line2)}.graph-head{height:44px;flex-shrink:0;display:flex;align-items:center;padding:0 18px;gap:10px;border-bottom:1px solid #23344a;background:linear-gradient(90deg,#0d1521,#101827 52%,#0c1420)}.eyebrow{font:10px var(--mono);color:#71869a;letter-spacing:.09em}.graph-title{font-size:12px;font-weight:700;color:#e2eaf2}.head-count{font:10px var(--mono);color:#71869a;background:#17212c;border:1px solid #243140;border-radius:5px;padding:4px 6px}.graph-actions{margin-left:auto;display:flex;align-items:center;gap:5px}.tiny-btn{padding:5px 8px;font-size:10px;color:#9db0c2}.canvas-wrap{position:relative;flex:1;min-height:0;overflow:hidden;isolation:isolate;background-color:#080d17;background-image:radial-gradient(rgba(99,143,182,.24) .75px,transparent .9px),linear-gradient(rgba(31,48,73,.12) 1px,transparent 1px),linear-gradient(90deg,rgba(31,48,73,.12) 1px,transparent 1px);background-size:22px 22px,88px 88px,88px 88px;background-position:2px 2px,0 0,0 0}.canvas-wrap::before{content:"";position:absolute;inset:-18%;z-index:0;pointer-events:none;background:radial-gradient(ellipse at 24% 30%,rgba(42,130,172,.17),transparent 36%),radial-gradient(ellipse at 73% 18%,rgba(120,86,203,.16),transparent 34%),radial-gradient(ellipse at 63% 83%,rgba(49,190,151,.1),transparent 39%);background-size:130% 130%;animation:auroraDrift 24s ease-in-out infinite alternate;filter:saturate(1.15)}.canvas-wrap:after{content:"";position:absolute;inset:0;pointer-events:none;z-index:2;background:radial-gradient(ellipse at 50% 46%,transparent 40%,rgba(4,8,15,.23) 100%)}#graphCanvas{position:absolute;width:100%;height:100%;inset:0;touch-action:none;z-index:1}.graph-overlay{position:absolute;z-index:4;pointer-events:none;top:14px;left:16px;display:flex;gap:7px;align-items:center}.overlay-tag{font-size:10px;color:#9caec0;background:rgba(12,20,34,.83);border:1px solid #2d435b;border-radius:6px;padding:6px 8px;backdrop-filter:blur(8px);box-shadow:0 4px 18px rgba(0,0,0,.08)}.overlay-tag b{font-family:var(--mono);color:#d2deea;font-weight:600}.canvas-legend{z-index:4;position:absolute;left:15px;bottom:15px;padding:9px 10px;background:rgba(12,20,32,.85);border:1px solid #2b4055;border-radius:8px;display:flex;gap:12px;align-items:center;backdrop-filter:blur(10px);box-shadow:0 8px 24px #0002}.legend-title{font-size:9px;color:#7e92a7;letter-spacing:.08em}.heat-key{display:flex;align-items:center;gap:5px;font-size:10px;color:#9caec0}.heat-dot{width:7px;height:7px;border-radius:50%;animation:heatPulse 3.4s ease-in-out infinite;box-shadow:0 0 9px currentColor}.heat-key:nth-of-type(2) .heat-dot{animation-delay:.4s}.heat-key:nth-of-type(3) .heat-dot{animation-delay:1.1s}.line-key{width:18px;height:0;border-top:2px solid}.line-key.dash{border-top-style:dashed}.minimap{position:absolute;right:15px;bottom:15px;z-index:5;width:166px;height:106px;background:rgba(14,23,32,.91);border:1px solid #314252;border-radius:8px;overflow:hidden;backdrop-filter:blur(7px)}.minimap-label{position:absolute;z-index:2;left:8px;top:6px;font:8px var(--mono);color:#8ba0b5;letter-spacing:.08em;pointer-events:none}#miniCanvas{width:100%;height:100%;display:block;cursor:crosshair}.hover-card{position:absolute;z-index:10;pointer-events:none;min-width:190px;max-width:250px;background:#111c27;border:1px solid #3a5062;box-shadow:0 10px 30px #0008;border-radius:8px;padding:10px 11px;display:none}.hover-title{font-size:11px;font-weight:700;color:#edf4fa}.hover-sub{font:9px var(--mono);color:#8499ae;margin-top:4px}.hover-row{display:flex;justify-content:space-between;margin-top:8px;font-size:9px;color:#8499ae}.hover-row strong{font:700 10px var(--mono)}.canvas-foot{height:34px;flex-shrink:0;border-top:1px solid #1a2632;display:flex;align-items:center;padding:0 16px;gap:8px;background:#0c1219}.crumb{display:flex;align-items:center;gap:7px;font-size:10px;color:#75899d;white-space:nowrap}.crumb button{border:0;background:none;padding:0;color:#8499ad;font-size:10px}.crumb button:hover{color:#d8e8f7}.crumb button.current{color:#d7e4f0;font-weight:700}.crumb .arr{color:#425365}.current-path{margin-left:auto;font:9px var(--mono);color:#63778c;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.canvas-msg{position:absolute;z-index:3;right:17px;top:15px;font-size:10px;color:#7890a3;background:rgba(13,21,29,.81);border:1px solid #293a49;padding:6px 8px;border-radius:6px;pointer-events:none}
.sidebar{min-width:0;min-height:0;background:linear-gradient(180deg,#101824,#0c131d 65%);display:flex;flex-direction:column}.side-head{height:64px;flex-shrink:0;padding:14px 17px 10px;border-bottom:1px solid #1e2a36;display:flex;align-items:center;gap:10px;background:linear-gradient(110deg,#121e2e,#101925 70%,#111b2b)}.side-icon{width:31px;height:31px;border-radius:8px;background:linear-gradient(145deg,#1a3842,#1f2941);border:1px solid #31566a;display:grid;place-items:center;color:#70dfb3;box-shadow:0 0 18px #5fdcff0e}.side-icon svg{width:17px;height:17px}.side-title{font-size:12px;font-weight:700}.side-sub{font:9px var(--mono);color:#70859a;margin-top:4px}.side-head .icon-btn{margin-left:auto;background:#111a24}.tabs{height:42px;flex-shrink:0;border-bottom:1px solid #24313e;display:flex;padding:0 11px;gap:1px;overflow-x:auto;scrollbar-width:none}.tabs::-webkit-scrollbar{display:none}.tab-btn{flex-shrink:0;border:0;border-radius:0;border-bottom:2px solid transparent;background:none;padding:0 9px;font-size:10px;color:#7d91a5;white-space:nowrap}.tab-btn:hover{color:#d8e4ef}.tab-btn.active{border-bottom-color:#4bd4a0;color:#bcebd9}.side-body{flex:1;min-height:0;overflow:auto;padding:16px 16px 18px;scrollbar-width:thin;scrollbar-color:#2b3a49 transparent}.panel-section{margin-bottom:17px}.section-head{display:flex;align-items:center;justify-content:space-between;margin-bottom:10px;border-bottom:1px solid #29394d;padding-bottom:7px}.section-title{font-size:10px;font-weight:800;letter-spacing:.06em;color:#b8c6d3}.section-meta{font:9px var(--mono);color:#71859a}.confidence-card{padding:13px;background:radial-gradient(ellipse at 8% 0%,rgba(95,220,255,.055),transparent 55%),linear-gradient(145deg,#111e2e,#101824);border:1px solid #2b3e53;border-radius:10px;position:relative;overflow:hidden;box-shadow:inset 0 1px 0 #ffffff05,0 8px 24px #0001}.confidence-card:after{content:"";position:absolute;right:-25px;top:-35px;width:115px;height:115px;border-radius:50%;border:1px solid #59f0b818;box-shadow:0 0 0 12px #59f0b807,0 0 0 24px #59f0b805;pointer-events:none}.confidence-top{display:flex;justify-content:space-between;align-items:flex-start;position:relative;z-index:1}.confidence-label{font-size:10px;color:#9bb6aa}.confidence-value{font:700 32px var(--mono);letter-spacing:-.06em;margin-top:6px;color:#66e5ac}.confidence-value small{font-size:12px;color:#82a095;letter-spacing:0}.conf-state{font-size:9px;padding:4px 6px;border:1px solid #32694f;color:#71dfab;background:#173629;border-radius:5px;margin-top:2px}.meter{height:5px;background:#263932;border-radius:6px;overflow:hidden;margin:12px 0 7px;position:relative;z-index:1}.meter span{display:block;height:100%;border-radius:6px;background:linear-gradient(90deg,#e9b753,#59d99c);filter:drop-shadow(0 0 4px currentColor)}.meter-labels{display:flex;justify-content:space-between;font:9px var(--mono);color:#7e978d;position:relative;z-index:1}.metric-grid{display:grid;grid-template-columns:1fr 1fr;gap:8px}.metric-box{border:1px solid #293b50;border-radius:8px;background:#111a23;padding:10px}.metric-box .label{font-size:9px;color:#7d91a4}.metric-box strong{font:700 17px var(--mono);display:block;margin-top:5px;color:#e0eaf2}.metric-box small{font-size:9px;color:#788c9f;display:block;margin-top:4px}.metric-box strong.green{color:#70dfae}.metric-box strong.yellow{color:#f0c766}.metric-box strong.red{color:#fb828b}.bar-list{display:flex;flex-direction:column;gap:10px}.bar-row{display:grid;grid-template-columns:83px 1fr 35px;align-items:center;gap:7px}.bar-row label{font-size:9px;color:#96a8b8;white-space:nowrap}.bar-track{height:5px;border-radius:4px;background:#202c38;overflow:hidden}.bar-track span{height:100%;display:block;border-radius:4px;filter:drop-shadow(0 0 4px currentColor)}.bar-row strong{font:10px var(--mono);text-align:right;color:#ccd8e4}.note{border:1px solid #293b50;border-left:2px solid #e0b44f;background:#151e26;border-radius:6px;padding:10px 11px;font-size:10px;line-height:1.65;color:#a9b6c3}.note strong{color:#e6c56f;font-weight:700}.pill-row{display:flex;gap:5px;flex-wrap:wrap}.pill{font-size:9px;color:#9db0c1;background:#17222d;border:1px solid #2a3b4a;border-radius:5px;padding:5px 7px}.list{display:flex;flex-direction:column;gap:6px}.list-row{border:1px solid #293b50;border-radius:7px;background:#111a23;padding:9px 9px;display:flex;gap:8px;align-items:center;cursor:pointer}.list-row:hover{border-color:#42596b;background:#14202a}.list-row .relation-dot{width:7px;height:7px;border-radius:50%;flex-shrink:0}.list-row .list-main{min-width:0;flex:1}.list-row strong{display:block;font-size:10px;color:#cbd8e4;font-weight:650;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.list-row small{display:block;font:9px var(--mono);color:#6e8397;margin-top:4px}.list-row .list-score{font:700 10px var(--mono);color:#a9d9c2}.evidence-item{display:flex;gap:9px;padding:9px 0;border-bottom:1px solid #1e2a36}.evidence-item:last-child{border-bottom:0}.evi-icon{width:24px;height:24px;border:1px solid #2a3b4b;border-radius:6px;display:grid;place-items:center;color:#83a6bf;font-size:10px;flex-shrink:0;background:#15212c}.evi-main{flex:1;min-width:0}.evi-main strong{display:block;font-size:10px;color:#c3d0dd}.evi-main p{margin:4px 0 0;font-size:9px;line-height:1.55;color:#8295a7}.evi-score{font:10px var(--mono);color:#d5e0e9}.evi-score.good{color:#6bdfaa}.evi-score.mid{color:#f0c35b}.evi-score.low{color:#fa818b}.mini-table{width:100%;border-collapse:collapse;font-size:9px}.mini-table th{text-align:left;font-weight:600;color:#7790a4;padding:8px 5px;border-bottom:1px solid #293846}.mini-table td{padding:9px 5px;color:#aebdca;border-bottom:1px solid #202b36;vertical-align:middle}.mini-table tr:last-child td{border-bottom:0}.mini-table .score-cell{font:10px var(--mono);font-weight:700}.empty{padding:25px 12px;text-align:center;color:#778ba0;font-size:10px;border:1px dashed #2a3946;border-radius:8px}.empty strong{display:block;color:#b5c4d1;font-size:11px;margin-bottom:5px}.side-actions{display:flex;gap:7px;margin-top:11px}.side-actions button{flex:1}.stat-row{display:flex;justify-content:space-between;align-items:center;padding:8px 0;border-bottom:1px solid #1c2834;font-size:10px;color:#91a4b6}.stat-row strong{font:10px var(--mono);color:#d0dce6}.stat-row:last-child{border-bottom:0}
.bottom-status{height:25px;flex-shrink:0;border-top:1px solid #26384c;background:linear-gradient(90deg,#0f1927,#0d151f);display:flex;align-items:center;justify-content:space-between;padding:0 16px;color:#617488;font:9px var(--mono)}.status-left,.status-right{display:flex;align-items:center;gap:14px}.status-green{color:#71dcae}.kbd{border:1px solid #2c3a47;border-radius:3px;padding:1px 4px;color:#8da0b3}.toast{position:fixed;bottom:39px;left:50%;transform:translate(-50%,12px);opacity:0;pointer-events:none;z-index:99;padding:10px 13px;border-radius:8px;border:1px solid #365345;background:#11231c;color:#a8e9cb;font-size:11px;box-shadow:0 8px 28px #0008;transition:.2s}.toast.show{opacity:1;transform:translate(-50%,0)}.modal-backdrop{position:fixed;inset:0;background:rgba(4,8,12,.79);z-index:80;display:none;align-items:center;justify-content:center;backdrop-filter:blur(5px)}.modal-backdrop.show{display:flex}.modal{width:min(620px,calc(100vw - 32px));max-height:80vh;overflow:auto;border:1px solid #344555;border-radius:13px;background:#101923;box-shadow:0 30px 100px #000b;padding:20px}.modal-head{display:flex;align-items:center;justify-content:space-between}.modal h2{font-size:15px;margin:0}.modal p{font-size:11px;line-height:1.7;color:#9aabba}.formula{font:11px var(--mono);color:#9fe2c0;background:#0a1511;border:1px solid #253e32;padding:12px;border-radius:7px;overflow:auto}.weights{width:100%;border-collapse:collapse;margin-top:10px;font-size:10px}.weights td,.weights th{text-align:left;padding:8px;border-bottom:1px solid #263442}.weights th{color:#8197aa}.weights td{color:#c5d2de}.weights tr:last-child td{border-bottom:0}
.breath-toggle{color:#75eac3;border-color:#367c69;background:linear-gradient(110deg,#12352f,#172c37);box-shadow:inset 0 0 14px #59f0b80b,0 0 16px #59f0b80a}.breath-toggle:not(.active){color:#8a9bad;border-color:#2a3949;background:#121b25;box-shadow:none}
@keyframes brandBreath{0%,100%{box-shadow:0 0 15px rgba(90,219,235,.16),inset 0 1px 0 #ffffff88;filter:saturate(1)}50%{box-shadow:0 0 28px rgba(90,219,235,.28),0 0 35px rgba(130,168,255,.08),inset 0 1px 0 #ffffff99;filter:saturate(1.12)}}
@keyframes donutBreath{0%,100%{filter:drop-shadow(0 0 5px #59f0b81a)}50%{filter:drop-shadow(0 0 12px #59f0b83d)}}
@keyframes auroraDrift{0%{transform:translate3d(-1.5%,0,0) scale(1);background-position:0% 0%}50%{transform:translate3d(1.5%,1%,0) scale(1.04);background-position:100% 60%}100%{transform:translate3d(-.5%,-1%,0) scale(1.02);background-position:20% 100%}}
@keyframes heatPulse{0%,100%{opacity:.75;transform:scale(.9);box-shadow:0 0 3px currentColor}50%{opacity:1;transform:scale(1.2);box-shadow:0 0 11px currentColor}}
@keyframes statusPulse{0%,100%{box-shadow:0 0 0 0 rgba(89,240,184,0)}50%{box-shadow:0 0 0 5px rgba(89,240,184,.05)}}
@media(max-width:1120px){.main{grid-template-columns:minmax(360px,1fr) 330px}.brand{min-width:190px}.topbar{gap:12px;padding:0 15px}.toolbar{gap:7px;padding:0 15px}.search-wrap{width:185px}.threshold{width:150px}.threshold input{width:70px}}
@media(max-width:850px){html,body{overflow:auto}.app{height:auto;min-height:100vh}.topbar{height:auto;min-height:62px;flex-wrap:wrap;padding:10px 12px}.brand{min-width:unset}.topbar .vdiv,.tierchip,.project-select small{display:none}.project-select{min-width:auto}.toolbar{height:auto;min-height:56px;flex-wrap:wrap;padding:10px 12px}.toolbar-spacer{display:none}.main{display:flex;flex-direction:column}.graph-area{height:640px;min-height:570px;border-right:0}.sidebar{min-height:520px;border-top:1px solid var(--line)}.side-body{max-height:600px}.current-path{display:none}.canvas-legend{max-width:calc(100% - 30px);flex-wrap:wrap}.minimap{width:130px;height:86px;bottom:62px}.bottom-status{position:static}.top-metric{margin-left:auto}}
@media(prefers-reduced-motion:reduce){.brandmark,.score-donut,.canvas-wrap::before,.heat-dot,.status-dot{animation:none!important}}
</style>
</head>
<body>
<div class="app">
  <header class="topbar">
    <div class="brand">
      <div class="brandmark"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 5.5 12 2l8 3.5v8L12 22 4 13.5z"/><path d="m4 5.5 8 4 8-4M12 9.5V22"/><circle cx="12" cy="9.5" r="2" fill="currentColor" stroke="none"/></svg></div>
      <div><h1>AI CODE RELIABILITY</h1><small>CONFIDENCE GRAPH · moonGit</small></div>
    </div>
    <div class="vdiv"></div>
    <div class="project-select"><div class="project-avatar" id="projAvatar">MG</div><div><strong id="projName">project</strong><small id="projMeta">indexing…</small></div><span class="tierchip" id="tierChip">—</span></div>
    <div class="top-spacer"></div>
    <div class="top-metric"><div class="score-donut" id="topDonut"><b id="topScoreMini">–</b></div><div><label id="lblTopConf">项目综合置信度</label><strong><span id="topScore">–</span><span style="font-size:10px;color:#7b8ea1;font-weight:500"> / 100</span></strong></div></div>
    <button class="ghost-btn" id="modelBtn">置信度模型 ↗</button>
  </header>
  <section class="toolbar">
    <div class="search-position">
      <div class="search-wrap"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="10.8" cy="10.8" r="6.8"/><path d="m16 16 5 5"/></svg><input id="searchInput" placeholder="搜索模块、文件、符号…" autocomplete="off"/><span style="font:9px var(--mono);color:#52677c">/</span></div>
      <div id="searchResults" class="search-results" style="display:none"></div>
    </div>
    <div class="separator"></div>
    <div class="tool-group"><span class="tool-label" id="lblRel">关系</span><select id="relationFilter" class="select"><option value="all">全部关系类型</option></select></div>
    <div class="separator"></div>
    <div class="tool-group threshold"><span class="tool-label" id="lblTh">置信度 ≥</span><input id="threshold" type="range" min="0" max="90" value="0" step="5"/><span class="num" id="thresholdValue">0</span></div>
    <div class="separator"></div>
    <div class="mode-toggle"><span class="layout-chip">⌁ <span id="lblMode">关系驱动 · 分层散点</span></span></div>
    <div class="toolbar-spacer"></div>
    <span class="view-label"><span class="status-dot"></span><span id="visibleCount">–</span></span>
    <button class="icon-btn" id="resetView" title="重置视图">⌂</button>
  </section>
  <main class="main">
    <section class="graph-area">
      <div class="graph-head"><span class="eyebrow">GRAPH /</span><span class="graph-title" id="graphScopeTitle">项目关系散点总览</span><span class="head-count" id="scopeCount">–</span><div class="graph-actions"><button class="tiny-btn" id="pathBtn">⇢ <span id="lblPath">高亮关系路径</span></button><button class="tiny-btn" id="fitBtn"><span id="lblFit">适应画布</span></button><button class="tiny-btn breath-toggle active" id="breathToggle" aria-pressed="true" title="切换图谱呼吸与关系粒子动画">✦ <span id="lblBreath">呼吸动态 ON</span></button></div></div>
      <div class="canvas-wrap" id="canvasWrap" data-canvas="codegraph">
        <canvas id="graphCanvas" aria-label="代码置信度关系图"></canvas>
        <div class="graph-overlay"><span class="overlay-tag"><span id="lblLevel">层级</span> <b id="levelTag">PROJECT</b></span><span class="overlay-tag"><span id="lblGraph">图谱</span> <b>CODEGRAPH</b></span></div>
        <div class="canvas-msg" id="canvasMsg">关系驱动散点 · 单击选中 · 双击下钻 · 拖动平移 · 滚轮缩放</div>
        <div class="hover-card" id="hoverCard"><div class="hover-title" id="hoverTitle"></div><div class="hover-sub" id="hoverSub"></div><div class="hover-row"><span id="lblHovConf">置信度</span><strong id="hoverScore"></strong></div><div class="hover-row"><span id="lblHovFind">疑点 / 罚分</span><strong id="hoverFind"></strong></div></div>
        <div class="canvas-legend"><span class="legend-title">CONFIDENCE</span><span class="heat-key"><i class="heat-dot" style="background:#ff6b8a"></i><span id="lgLo">低 0–59</span></span><span class="heat-key"><i class="heat-dot" style="background:#ffc857"></i><span id="lgMid">中 60–79</span></span><span class="heat-key"><i class="heat-dot" style="background:#59f0b8"></i><span id="lgHi">高 80–100</span></span><span style="width:1px;height:14px;background:#30404f"></span><span class="heat-key"><i class="line-key" style="border-color:#67c6f3"></i><span id="lgSrc">线色 = 来源节点（卡的左色条）· 虚线 = 词法不确定</span></span></div>
        <div class="minimap"><span class="minimap-label">MINIMAP / CLICK TO PAN</span><canvas id="miniCanvas"></canvas></div>
      </div>
      <div class="canvas-foot"><div class="crumb" id="breadcrumbs"></div><div class="current-path" id="currentPath">/</div></div>
    </section>
    <aside class="sidebar">
      <div class="side-head"><div class="side-icon"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 3 20 7.5v9L12 21l-8-4.5v-9z"/><path d="M12 3v9l8-4.5M12 12 4 7.5M12 12v9"/></svg></div><div><div class="side-title" id="sideTitle">置信度分析报告</div><div class="side-sub" id="sideSub">PROJECT OVERVIEW</div></div><button class="icon-btn" id="clearSelection" title="取消选中">×</button></div>
      <nav class="tabs" id="tabs">
        <button class="tab-btn active" data-tab="overview" id="tabOverview">概览</button><button class="tab-btn" data-tab="confidence" id="tabConfidence">置信度报告</button><button class="tab-btn" data-tab="relations" id="tabRelations">关系明细</button><button class="tab-btn" data-tab="evidence" id="tabEvidence">证据</button><button class="tab-btn" data-tab="modules" id="tabModules">模块汇总</button><button class="tab-btn" data-tab="symbols" id="tabSymbols">符号</button>
      </nav>
      <div class="side-body" id="sideBody"></div>
    </aside>
  </main>
  <footer class="bottom-status"><div class="status-left"><span class="status-green" id="freshTag">● INDEX</span><span id="footerNodes">–</span><span id="modelTag">MODEL: LEX-1</span><span id="evalTag"></span></div><div class="status-right"><span>Canvas renderer</span><span><span class="kbd">?</span> <span id="lblHelp">交互说明</span></span><span>moongit codegraph</span></div></footer>
</div>
<div class="toast" id="toast"></div>
<div class="modal-backdrop" id="modalBackdrop"><div class="modal"><div class="modal-head"><h2 id="modalTitle">综合置信度计算模型</h2><button class="icon-btn" id="closeModal">×</button></div><p id="modalIntro"></p><div class="formula" id="modalFormula"></div><table class="weights"><thead><tr><th id="modalTh1">疑点档位</th><th>weight</th><th id="modalTh2">观察内容</th></tr></thead><tbody><tr><td id="modalW1">低档 &lt;4</td><td>1–3</td><td id="modalD1">风格与可读性类疑点，按条数线性累积</td></tr><tr><td id="modalW2">中档 4–7</td><td>4–7</td><td id="modalD2">可信度实质受损：深嵌套/超长函数/魔法数等</td></tr><tr><td id="modalW3">高档 ≥8</td><td>8+</td><td id="modalD3">高风险模式：并发风险/指针风险/结构性缺陷</td></tr></tbody></table><p id="modalCaps"></p><button class="primary-btn" id="closeModal2" style="margin-top:5px">理解</button></div></div>
""")
    sb.append("<script>\nwindow.__CODEGRAPH__ = " + json + ";\n</script>\n<script>\n")
    sb.append(codegraphDriverJs(en))
    sb.append("""
</script>
</body>
</html>""")
    return sb.toString()
}


public func treeCanvasHtml(graph: CodeGraph, depth: Int64, en: Bool, findings: ConfidenceReport): String {
    return renderIndexHtml(indexPayload(graph, depth, findings, en), None<JsonValue>, en)
}

/// 从渲染产物读回内嵌的 updateCount（HTML 注释 `updateCount=N`）。
/// 与 renderIndexHtml 的写入是同一格式的一对——**读取器必须能回答
/// 「有没有标记」**：None = 旧产物 / 非本引擎产物 / 被改过，一律按
/// 「不能复用」处理，绝不猜成 0（0 恰好是首版的合法值）。
public func renderIndexEmbeddedUpdateCount(html: String): Option<Int64> {
    let marker = "updateCount="
    let a = indexOfStrFrom(html, marker, 0)
    if (a < 0) { return None }
    let from = a + marker.size
    let bs = html.toArray()
    var i = from
    // 跳过前导空白（注释格式是固定的，这里只容忍排版噪音）
    while (i < Int64(bs.size) && (bs[i] == 32 || bs[i] == 9)) { i += 1 }
    var digits = ArrayList<UInt8>()
    while (i < Int64(bs.size) && bs[i] >= 48 && bs[i] <= 57) {
        digits.add(bs[i])
        i += 1
    }
    if (Int64(digits.size) == 0) { return None }
    return metaInt(fromUtf8Lossy(digits.toArray()))
}

/// 从渲染产物读回内嵌的 generatedAt（HTML 注释 `generatedAt=… -->`）。
/// 与 updateCount 成对使用：版本号在「库与 index.json 双双缺席后重建」
/// 会从 0 重计，单比版本号可能把「旧版本 0」误当「新版本 0」——
/// 时间戳参与比对才真正回答「这份产物是不是从这份 index 画出来的」。
/// 找不到标记返回空串（与「没有」同义，调用方按不可复用处理）。
public func renderIndexEmbeddedGeneratedAt(html: String): String {
    let marker = "generatedAt="
    let a = indexOfStrFrom(html, marker, 0)
    if (a < 0) { return "" }
    let from = a + marker.size
    let end = indexOfStrFrom(html, " -->", from)
    if (end < 0) { return "" }
    if (end <= from) { return "" }
    // 边界都是 ASCII 标记串，UTF-8 切片安全
    return html[from..end]
}

/// 驱动：AI 置信度关系图（2026-10-12 按用户参考稿整体重做，完全替代
/// 旧的「模块卡片/文件球/符号球」三视图）。信息架构 = 层级作用域钻取
///（project → module → file → symbol）+ 有序网格分层布局（关系聚类）+
/// 双态走线：静态直角正交（物理通道车道）· 拖拽时全线自由贝塞尔 + 呼吸氛围（aurora/星尘/关系粒子/流动虚线）+ minimap +
/// 置信度阈值过滤 + 侧栏六 tab。无导出按钮（置信度报告走 confidence.json
/// 独立出口）；无双主题（参考稿为暗色单主题）。
/// 2026-10-12 用户验收二轮定稿：① 卡片外圈光晕退役，置信度色深度只留在
/// 框体自身（填充/边框/左色条）；② 布局从散点改为带内语义排序（模块/文件
/// 按名、符号按代码行）+ 有序网格铺排 + #序号徽标——顺序一眼可读；
/// 网格间距放大（散开不堆叠）；③ 呼吸只暴露在框体内（无外溢 shadow，
/// 外发光只留给选中态；悬停/选中呼吸环 = 框内描边）。
/// 确定性纪律：网格布局零随机零时间；呼吸层只影响绘制不影响坐标。
/// 绘制只调 CANVAS2D_SUBSET 内方法——不用径向渐变/measureText/clearRect，
/// save/restore 手动复位。
func codegraphDriverJs(en: Bool): String {
    // 双语表：模板静态文本为中文，en 时 applyTexts 用本表覆盖 textContent
    let tTopConf = if (en) { "Overall confidence" } else { "项目综合置信度" }
    let tModelBtn = if (en) { "Model ↗" } else { "置信度模型 ↗" }
    let tRel = if (en) { "Relations" } else { "关系" }
    let tRelAll = if (en) { "all relation types" } else { "全部关系类型" }
    let tRelCall = if (en) { "call" } else { "调用" }
    let tRelGuessed = if (en) { "uncertain call" } else { "词法不确定" }
    let tTh = if (en) { "confidence ≥" } else { "置信度 ≥" }
    let tMode = if (en) { "relation-driven · layered scatter" } else { "关系驱动 · 分层散点" }
    let tPath = if (en) { "highlight paths" } else { "高亮关系路径" }
    let tFit = if (en) { "fit view" } else { "适应画布" }
    let tBreathOn = if (en) { "breath ON" } else { "呼吸动态 ON" }
    let tBreathOff = if (en) { "breath OFF" } else { "呼吸动态 OFF" }
    let tLevel = if (en) { "scope" } else { "层级" }
    let tMsg = if (en) { "relation scatter · click to select · double-click to drill · drag to pan · wheel to zoom" }
        else { "关系驱动散点 · 单击选中 · 双击下钻 · 拖动平移 · 滚轮缩放" }
    let tHovConf = if (en) { "confidence" } else { "置信度" }
    let tHovFind = if (en) { "findings / penalty" } else { "疑点 / 罚分" }
    let tLgLo = if (en) { "low 0–59" } else { "低 0–59" }
    let tLgMid = if (en) { "mid 60–79" } else { "中 60–79" }
    let tLgHi = if (en) { "high 80–100" } else { "高 80–100" }
    let tLgSrc = if (en) { "edge color = source node (left bar) · dashed = uncertain" }
        else { "线色 = 来源节点（卡的左色条）· 虚线 = 词法不确定" }
    let tHelp = if (en) { "help" } else { "交互说明" }
    let tTabOv = if (en) { "Overview" } else { "概览" }
    let tTabConf = if (en) { "Confidence" } else { "置信度报告" }
    let tTabRel = if (en) { "Relations" } else { "关系明细" }
    let tTabEvi = if (en) { "Evidence" } else { "证据" }
    let tTabMod = if (en) { "Modules" } else { "模块汇总" }
    let tTabSym = if (en) { "Symbols" } else { "符号" }
    let bandModules = if (en) { "MODULES" } else { "模块" }
    let bandFiles = if (en) { "FILES" } else { "文件" }
    let bandTypes = if (en) { "TYPES" } else { "类型" }
    let bandFuncs = if (en) { "FUNCTIONS" } else { "函数" }
    let bandBoundary = if (en) { "EXTERNAL / CROSS-SCOPE" } else { "跨作用域边界" }
    let tpProject = if (en) { "project" } else { "项目" }
    let tpModule = if (en) { "module" } else { "模块" }
    let tpFile = if (en) { "file" } else { "文件" }
    let tpType = if (en) { "type" } else { "类型" }
    let tpMethod = if (en) { "function" } else { "函数" }
    let tpBoundary = if (en) { "boundary" } else { "边界" }
    let tFiles = if (en) { "files" } else { "文件" }
    let tSyms = if (en) { "symbols" } else { "符号" }
    let tLines = if (en) { "lines" } else { "行" }
    let tFindings = if (en) { "findings" } else { "疑点" }
    let tPenalty = if (en) { "penalty" } else { "罚分" }
    let tClean = if (en) { "clean share" } else { "清洁占比" }
    let tDegree = if (en) { "relations" } else { "关系数" }
    let tImpact = if (en) { "fan-out degree" } else { "关系度" }
    let tScale = if (en) { "scale" } else { "规模" }
    let tDimTitle = if (en) { "finding dimensions" } else { "疑点维度分布" }
    let tIntegrity = if (en) { "graph completeness" } else { "图谱完整性" }
    let tChildren = if (en) { "next level" } else { "下一级节点" }
    let tDirectRel = if (en) { "direct relations" } else { "直接关系" }
    let tAllRel = if (en) { "view all relations" } else { "查看全部关系" }
    let tNoChild = if (en) { "leaf node" } else { "当前层级已到达叶节点" }
    let tNoRel = if (en) { "no indexed edges on this node" } else { "此节点当前没有登记的显式边" }
    let tSecFormula = if (en) { "formula inputs" } else { "公式输入" }
    let tSecDims = if (en) { "dimensions detail" } else { "六维疑点明细" }
    let tLexNote = if (en) { "Scores are lexical heuristics over the symbol index, not an audit. Call edges resolve by name; dashed edges had several same-name candidates." }
        else { "分数来自符号索引上的词法启发式，不是审计结论。调用边按名字解析；虚线边存在多个同名候选。" }
    let tEviEmpty = if (en) { "no findings recorded in this scope" } else { "该作用域没有已记录的疑点" }
    let tEviCap = if (en) { "showing first #N findings" } else { "仅列出前 #N 条疑点" }
    let tSymCap = if (en) { "showing first #N symbols" } else { "仅列出前 #N 个符号" }
    let tSymEmpty = if (en) { "no symbols under this node" } else { "当前节点没有符号子项" }
    let tModAgg = if (en) { "Module index = engine-side aggregate over its files (single source: graphModules payload). The project score is the confidence.json headline, not a page-side re-aggregation." }
        else { "模块指数由引擎按其文件聚合后下发（页面不重算第二份）；项目总分 = confidence.json 的 headline，不是页面重算的平均。" }
    let tIn = if (en) { "IN" } else { "入" }
    let tOut = if (en) { "OUT" } else { "出" }
    let tStrength = if (en) { "weight" } else { "强度" }
    let tToastEnter = if (en) { "entered subgraph" } else { "已进入子图" }
    let tToastDrill = if (en) { "drilled into" } else { "已下钻至" }
    let tToastLocate = if (en) { "located" } else { "已定位" }
    let tToastPathOn = if (en) { "path highlight on" } else { "已高亮所选节点的直接关系" }
    let tToastPathOff = if (en) { "path highlight off" } else { "已关闭路径高亮" }
    let tToastBreathOn = if (en) { "breath & particles on" } else { "动态呼吸与关系粒子已开启" }
    let tToastBreathOff = if (en) { "motion paused" } else { "动态效果已暂停" }
    let tNoMatch = if (en) { "no match" } else { "无匹配节点" }
    let tReady = if (en) { "● INDEX READY" } else { "● 索引就绪" }
    let tTmp = if (en) { "● TEMP RENDER (no persisted index)" } else { "● 临时渲染（未持久化索引）" }
    let tIndexed = if (en) { "SYMBOLS INDEXED" } else { "个符号已索引" }
    let tEvalAt = if (en) { "RENDERED" } else { "渲染于" }
    let tCapNote = if (en) { "engine caps: 6 per kind per file / 400 total — excess summarized" }
        else { "同类每文件最多 6 条 / 全量最多 400 条，超出已汇总" }
    let tConfMissing = if (en) { "no confidence data in this render (confidence.json absent); structure only" }
        else { "无置信度数据（本次渲染未提供 confidence.json）——本页只呈现结构" }
    let tNoteTrunc = if (en) { "file cap reached — graph is partial, not full" } else { "文件数达上限——图谱不是全量" }
    let tNoteOver = if (en) { " oversize files excluded" } else { " 个超大文件未纳入" }
    let tNoteDepth = if (en) { " files omitted by --depth (raise it for more)" } else { " 个文件因 --depth 未纳入（提高可看更多）" }
    let tNoteUnread = if (en) { " dirs unreadable (graph is partial, not full)" } else { " 个目录读不到（图谱不是全量）" }
    let tNodes = if (en) { "nodes" } else { "节点" }
    let tRels = if (en) { "relations" } else { "关系" }
    let tTypeCol = if (en) { "kind" } else { "类型" }
    let tBoundaryOf = if (en) { "outside current scope" } else { "当前图层之外" }
    let dimVar = if (en) { "Variables" } else { "变量" }
    let dimFn = if (en) { "Functions" } else { "函数" }
    let dimType = if (en) { "Types" } else { "类型" }
    let dimPtr = if (en) { "Pointers" } else { "指针" }
    let dimConc = if (en) { "Concurrency" } else { "并发" }
    let dimStruct = if (en) { "Structure" } else { "结构" }
    let tierLf = if (en) { "tier: modules (#F files > #M)" } else { "模块级（#F 文件 > #M）" }
    let tierLs = if (en) { "tier: modules (#S symbols > #M)" } else { "模块级（#S 符号 > #M）" }
    let tierC = if (en) { "tier: compact" } else { "紧凑级" }
    let constJs = "var T = { topConf: " + jsStr(tTopConf) + ", modelBtn: " + jsStr(tModelBtn)
        + ", rel: " + jsStr(tRel) + ", relAll: " + jsStr(tRelAll) + ", relCall: " + jsStr(tRelCall) + ", relGuessed: " + jsStr(tRelGuessed)
        + ", th: " + jsStr(tTh) + ", mode: " + jsStr(tMode) + ", path: " + jsStr(tPath) + ", fit: " + jsStr(tFit)
        + ", breathOn: " + jsStr(tBreathOn) + ", breathOff: " + jsStr(tBreathOff)
        + ", level: " + jsStr(tLevel) + ", msg: " + jsStr(tMsg) + ", hovConf: " + jsStr(tHovConf) + ", hovFind: " + jsStr(tHovFind)
        + ", lgLo: " + jsStr(tLgLo) + ", lgMid: " + jsStr(tLgMid) + ", lgHi: " + jsStr(tLgHi) + ", help: " + jsStr(tHelp)
        + ", lgSrc: " + jsStr(tLgSrc)
        + ", tabOv: " + jsStr(tTabOv) + ", tabConf: " + jsStr(tTabConf) + ", tabRel: " + jsStr(tTabRel)
        + ", tabEvi: " + jsStr(tTabEvi) + ", tabMod: " + jsStr(tTabMod) + ", tabSym: " + jsStr(tTabSym)
        + ", bandModules: " + jsStr(bandModules) + ", bandFiles: " + jsStr(bandFiles) + ", bandTypes: " + jsStr(bandTypes)
        + ", bandFuncs: " + jsStr(bandFuncs) + ", bandBoundary: " + jsStr(bandBoundary)
        + ", tp: { project: " + jsStr(tpProject) + ", module: " + jsStr(tpModule) + ", file: " + jsStr(tpFile)
        + ", type: " + jsStr(tpType) + ", method: " + jsStr(tpMethod) + ", boundary: " + jsStr(tpBoundary) + " }"
        + ", files: " + jsStr(tFiles) + ", syms: " + jsStr(tSyms) + ", lines: " + jsStr(tLines)
        + ", findings: " + jsStr(tFindings) + ", penalty: " + jsStr(tPenalty) + ", clean: " + jsStr(tClean)
        + ", degree: " + jsStr(tDegree) + ", impact: " + jsStr(tImpact) + ", scale: " + jsStr(tScale)
        + ", dimTitle: " + jsStr(tDimTitle) + ", integrity: " + jsStr(tIntegrity)
        + ", children: " + jsStr(tChildren) + ", directRel: " + jsStr(tDirectRel) + ", allRel: " + jsStr(tAllRel)
        + ", noChild: " + jsStr(tNoChild) + ", noRel: " + jsStr(tNoRel)
        + ", secFormula: " + jsStr(tSecFormula) + ", secDims: " + jsStr(tSecDims) + ", lexNote: " + jsStr(tLexNote)
        + ", eviEmpty: " + jsStr(tEviEmpty) + ", eviCap: " + jsStr(tEviCap) + ", symCap: " + jsStr(tSymCap) + ", symEmpty: " + jsStr(tSymEmpty)
        + ", modAgg: " + jsStr(tModAgg) + ", inLbl: " + jsStr(tIn) + ", outLbl: " + jsStr(tOut) + ", strength: " + jsStr(tStrength)
        + ", toastEnter: " + jsStr(tToastEnter) + ", toastDrill: " + jsStr(tToastDrill) + ", toastLocate: " + jsStr(tToastLocate)
        + ", toastPathOn: " + jsStr(tToastPathOn) + ", toastPathOff: " + jsStr(tToastPathOff)
        + ", toastBreathOn: " + jsStr(tToastBreathOn) + ", toastBreathOff: " + jsStr(tToastBreathOff)
        + ", noMatch: " + jsStr(tNoMatch) + ", ready: " + jsStr(tReady) + ", tmp: " + jsStr(tTmp)
        + ", indexed: " + jsStr(tIndexed) + ", evalAt: " + jsStr(tEvalAt) + ", capNote: " + jsStr(tCapNote)
        + ", confMissingNote: " + jsStr(tConfMissing) + ", noteTrunc: " + jsStr(tNoteTrunc)
        + ", noteOver: " + jsStr(tNoteOver) + ", noteDepth: " + jsStr(tNoteDepth) + ", noteUnread: " + jsStr(tNoteUnread)
        + ", nodes: " + jsStr(tNodes) + ", rels: " + jsStr(tRels) + ", typeCol: " + jsStr(tTypeCol)
        + ", boundaryOf: " + jsStr(tBoundaryOf)
        + ", dims: { variable: " + jsStr(dimVar) + ", function: " + jsStr(dimFn) + ", type: " + jsStr(dimType)
        + ", pointer: " + jsStr(dimPtr) + ", concurrency: " + jsStr(dimConc) + ", structure: " + jsStr(dimStruct) + " }"
        + ", tierLf: " + jsStr(tierLf) + ", tierLs: " + jsStr(tierLs) + ", tierC: " + jsStr(tierC) + " };\n"
    return constJs + """
'use strict';
var D = window.__CODEGRAPH__;
var NL = String.fromCharCode(10);
var CONF = D.confidence || { score: 100, astUsed: true, astNote: '', cappedTotal: false, cappedKind: false, findings: [], files: [] };
var FG = D.functionGraph || { functions: [], functionEdges: [], codeSnippets: {} };
function $(s) { return document.querySelector(s); }
function esc(v) { return String(v === null || v === undefined ? '' : v).replace(/[&<>"']/g, function (ch) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]; }); }
function clampNum(v, lo, hi) { return v < lo ? lo : (v > hi ? hi : v); }
function hashSeed(value) { var h = 2166136261; var s = String(value); for (var i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); } return h >>> 0; }
function rand01(seed) { var x = (seed >>> 0) || 1; x ^= x << 13; x ^= x >>> 17; x ^= x << 5; return (x >>> 0) / 4294967295; }
function confidenceColor(score) { return score < 60 ? '#ff6b8a' : score < 80 ? '#ffc857' : '#59f0b8'; }
function phaseOf(id) { var h = 0; var s = String(id); for (var i = 0; i < s.length; i++) { h = (h * 31 + s.charCodeAt(i)) | 0; } return (Math.abs(h) % 1000) / 100; }
function rgba(hex, a) { var h = hex.replace('#', ''); var v = parseInt(h, 16); return 'rgba(' + ((v >> 16) & 255) + ',' + ((v >> 8) & 255) + ',' + (v & 255) + ',' + a + ')'; }
function baseName(p) { var segs = String(p).split('/'); return segs[segs.length - 1]; }
function typeLabel(t) { return T.tp[t] || t; }
// ── 置信度公式（confidence.cj 公开公式的驱动侧唯一实现，与旧版逐字同体）──
var CONF_SCALE = 20;
function confScore(penalty, files) {
  var n = files < 1 ? 1 : files;
  var density = penalty / n;
  var sc = Math.floor(100 * CONF_SCALE / (CONF_SCALE + density));
  if (sc > 100) { sc = 100; }
  if (sc < 0) { sc = 0; }
  return sc;
}
// ── 数据层：findings 归属 + 容器疑点 roll-up（与旧版同源，徽标/侧栏同口径：
// 容器计数 = 整棵子树含符号级 findings，不是直属 fileFindings）──
var BY_FILE = {};
(CONF.findings || []).forEach(function (f) { (BY_FILE[f.file] = BY_FILE[f.file] || []).push(f); });
var HEAT = {};
(CONF.files || []).forEach(function (p) { HEAT[p.file] = p.penalty; });
function maxW(list) { var w = 0; list.forEach(function (f) { if (f.weight > w) { w = f.weight; } }); return w; }
function rollUp(n) {
  var cnt = 0; var w = 0;
  if (!n.fileFindings) { n.findings.forEach(function (f) { cnt += 1; if (f.weight > w) { w = f.weight; } }); n.rollN = cnt; n.rollW = w; return; }
  n.fileFindings.forEach(function (f) { cnt += 1; if (f.weight > w) { w = f.weight; } });
  (n.children || []).forEach(function (c) {
    var cn = (typeof c === 'string') ? NODES[c] : c;
    if (!cn) { return; }
    rollUp(cn); cnt += cn.rollN; if (cn.rollW > w) { w = cn.rollW; }
  });
  n.rollN = cnt; n.rollW = w;
}
function cntOf(n) { return n.rollN; }
// ── 节点模型：project → module → file → symbol（+boundary 运行时生成）──
var NODES = {};
var FN = {};
FG.functions.forEach(function (f) { FN[f.id] = f; });
var OUT_EDGE = {};
FG.functionEdges.forEach(function (e) { (OUT_EDGE[e.from] = OUT_EDGE[e.from] || []).push([e.to, e.w, e.tier || 'resolved']); });
var GM = D.graphModules || [];
var ME = D.graphModuleEdges || [];
var FM = D.fileModules || {};
var AE = D.archRefEdges || [];
var SYM_OF_FILE = {};
// 符号节点（kind → 视觉类型：class/struct/enum/extension/interface = type，其余 = method）
FG.functions.forEach(function (f) {
  var pen = 0;
  (f.findings || []).forEach(function (fd) { pen += (fd.weight || 0); });
  var kind = f.kind || 'func';
  var vt = (kind === 'class' || kind === 'struct' || kind === 'enum' || kind === 'interface' || kind === 'extension') ? 'type' : 'method';
  NODES[f.id] = { id: f.id, name: f.name, type: vt, kind: kind, parent: 'p:' + f.file, file: f.file,
    line: f.line, confidence: confScore(pen, 1), penalty: pen, findings: f.findings || [],
    signature: kind + ' · L' + f.line, loc: f.file, children: [], cov: ((f.findings || []).length ? 40 : 100) };
  (SYM_OF_FILE[f.file] = SYM_OF_FILE[f.file] || []).push(f.id);
});
// 文件节点（保留子树口径 rollUp：rollN 含符号级 findings）
var FILES = D.files || [];
FILES.forEach(function (fe) {
  var kids = (SYM_OF_FILE[fe.path] || []).slice(0).sort(function (a, b) { return NODES[a].line - NODES[b].line; });
  var fileFindings = [];
  var bySym = {};
  (BY_FILE[fe.path] || []).forEach(function (f) {
    var target = null;
    kids.forEach(function (sid) { if (NODES[sid].line <= f.line) { target = sid; } });
    if (target) { (bySym[target] = bySym[target] || []).push(f); } else { fileFindings.push(f); }
  });
  kids.forEach(function (sid) { NODES[sid].findings = bySym[sid] || []; });
  var pen = HEAT[fe.path] || 0;
  NODES['p:' + fe.path] = { id: 'p:' + fe.path, name: baseName(fe.path), type: 'file', parent: 'm:' + (FM[fe.path] || ''),
    path: fe.path, lang: fe.lang, lines: fe.lines, confidence: confScore(HEAT[fe.path] || 0, 1),
    penalty: pen, fileFindings: fileFindings, children: kids, cov: (cnt0(fileFindings, kids) ? 55 : 100) };
});
function cnt0(direct, kids) {
  var n = direct.length;
  kids.forEach(function (sid) { n += (NODES[sid].findings || []).length; });
  return n;
}
// 模块节点（指数 = 引擎下发的 confIndex，页面不重算第二份）
GM.forEach(function (m) {
  NODES['m:' + m.id] = { id: 'm:' + m.id, name: m.id, type: 'module', parent: 'project', mid: m.id,
    confidence: m.confIndex, penalty: m.penalty || 0, findings: m.findings || 0, fileFindings: [],
    files: m.files || 0, symbols: m.symbols || 0, lines: m.lines || 0, children: [], cov: ((m.findings || 0) > 0 ? 60 : 100) };
});
FILES.forEach(function (fe) {
  var mid = FM[fe.path] || '';
  if (NODES['m:' + mid]) { NODES['m:' + mid].children.push('p:' + fe.path); }
});
// 项目节点（总分 = CONF.score 引擎 headline；罚分 = 文件罚分表求和，只作展示）
var totalPen = 0; var totalFindings = 0;
FILES.forEach(function (fe) { totalPen += (HEAT[fe.path] || 0); });
(CONF.findings || []).forEach(function () { totalFindings += 1; });
NODES.project = { id: 'project', name: D.project || 'project', type: 'project', parent: null,
  confidence: CONF.score, penalty: totalPen, findings: totalFindings, fileFindings: [],
  children: GM.map(function (m) { return 'm:' + m.id; }), cov: (totalFindings ? 55 : 100) };
// roll-up 容器疑点计数（徽标/侧栏同口径：project 递归整棵树）
rollUp(NODES.project);
// 身份色相：每个节点一个确定性格位色（边颜色 = 来源节点色相，卡的左色条
// 同色）——「谁和谁有关系」靠颜色直接读，不用逐条追线
var HUE_OF = {};
(function () {
  var ids = Object.keys(NODES).filter(function (id) { return NODES[id].type !== 'boundary'; });
  ids.sort();
  // 黄金角 137.5° 散布色相：相邻节点色相差最大化（等分 360/n 会出近似色）
  ids.forEach(function (id, i) { HUE_OF[id] = Math.round(i * 137.508) % 360; });
})();
function hueOf(n) {
  if (n.hue !== undefined) { return n.hue; }
  return hashSeed(n.id) % 360;   // boundary（作用域内动态生成）取 id 哈希色相
}
// 色相 + 明度/饱和度交替（按色相奇偶）：同系色也被拉开，重复色可辨
function hueCss(h) {
  var v = h % 2;
  return 'hsl(' + h + ',' + (62 + v * 16) + '%,' + (52 + v * 14) + '%)';
}
// 关系度（impact = 全数据集内该节点的边数）
var DEGREE = {};
function bump(id) { DEGREE[id] = (DEGREE[id] || 0) + 1; }
ME.forEach(function (e) { bump('m:' + e.from); bump('m:' + e.to); });
AE.forEach(function (e) { bump('p:' + e.from); bump('p:' + e.to); });
FG.functionEdges.forEach(function (e) { bump(e.from); bump(e.to); });
Object.keys(NODES).forEach(function (id) { NODES[id].impact = DEGREE[id] || 0; });
// ── 全局关系表（按作用域映射成可见边；端点不在图层内 → 边界节点聚合）──
var REL = {
  call: { label: T.relCall, color: '#67c6f3', dash: [] },
  guessed: { label: T.relGuessed, color: '#ffc857', dash: [5, 4] }
};
function strengthOf(w) { return Math.min(1, 0.12 + w / 9); }
var scopeId = 'project';
var selectedId = 'project';
var boundaryUsed = {};
function ensureBoundary(id, label, conf) {
  if (!NODES[id]) { NODES[id] = { id: id, name: label, type: 'boundary', parent: scopeId, confidence: conf,
    penalty: 0, findings: 0, children: [], cov: 100, boundary: true }; }
  return NODES[id];
}
function mapCurrentGraph() {
  var scope = NODES[scopeId];
  var ids = (scope.children || []).slice(0);
  var byId = {};
  ids.forEach(function (id) { byId[id] = 1; });
  boundaryUsed = {};
  var candidates = [];
  function mapEndpoint(id, fallbackConf) {
    if (byId[id]) { return id; }
    if (!NODES[id]) { return null; }
    // 边界节点软上限：8 个之后并流进一个「↗ +N」聚合节点（防止外围淹没主图）
    var bkeys = Object.keys(boundaryUsed);
    var bkey = 'b:' + id;
    if (bkeys.length >= 8 && !boundaryUsed[bkey]) { bkey = 'b:__overflow'; }
    if (!NODES[bkey]) {
      var host = NODES[id];
      var label = bkey === 'b:__overflow' ? '↗ +' + (bkeys.length + 1) : ('↗ ' + (host.type === 'file' ? baseName(host.path || host.name) : host.name));
      ensureBoundary(bkey, label, host.confidence);
    }
    boundaryUsed[bkey] = 1;
    return bkey;
  }
  if (scopeId === 'project') {
    ME.forEach(function (e) {
      var a = 'm:' + e.from; var b = 'm:' + e.to;
      if (!byId[a] || !byId[b] || a === b) { return; }
      candidates.push({ s: a, t: b, type: 'call', w: e.w || 1, label: '' });
    });
  } else if (scope.type === 'module') {
    AE.forEach(function (e) {
      var a = 'p:' + e.from; var b = 'p:' + e.to;
      if (a === b) { return; }
      var ma = byId[a] ? a : (NODES[a] && NODES[a].parent === scopeId ? a : mapEndpoint(a));
      var mb = byId[b] ? b : (NODES[b] && NODES[b].parent === scopeId ? b : mapEndpoint(b));
      if (!ma || !mb || ma === mb) { return; }
      candidates.push({ s: ma, t: mb, type: 'call', w: e.w || 1, label: '' });
    });
  } else if (scope.type === 'file') {
    (scope.children || []).forEach(function (sid) { byId[sid] = 1; });
    AE.forEach(function (e) {
      var a = 'p:' + e.from; var b = 'p:' + e.to;
      if (a !== scopeId) { return; }
      var mb = byId[b] ? b : mapEndpoint(b);
      if (!mb || mb === a) { return; }
      candidates.push({ s: a, t: mb, type: 'call', w: e.w || 1, label: '' });
    });
    (scope.children || []).forEach(function (sid) {
      var outs = OUT_EDGE[sid] || [];
      outs.forEach(function (o) {
        var toId = o[0];
        if (byId[toId] && toId !== sid) {
          candidates.push({ s: sid, t: toId, type: (o[2] === 'guessed' ? 'guessed' : 'call'), w: o[1] || 1, label: '' });
        } else if (!byId[toId] && FN[toId]) {
          var host = NODES['p:' + FN[toId].file];
          var mb = mapEndpoint(host ? host.id : '', host ? host.confidence : 60);
          if (mb && mb !== sid) { candidates.push({ s: sid, t: mb, type: (o[2] === 'guessed' ? 'guessed' : 'call'), w: o[1] || 1, label: '' }); }
        }
      });
    });
  }
  if (relationType !== 'all') {
    candidates = candidates.filter(function (e) { return e.type === relationType; });
  }
  var agg = {};
  var order = [];
  candidates.forEach(function (e) {
    var key = [e.s, e.t, e.type].sort().join('|');
    if (!agg[key]) { agg[key] = { s: e.s, t: e.t, type: e.type, count: 0, wsum: 0, tier: e.type }; order.push(agg[key]); }
    agg[key].count += 1; agg[key].wsum += (e.w || 1);
  });
  var viewEdges = order.map(function (e) {
    var w = e.wsum / e.count;
    return { s: e.s, t: e.t, type: e.type, w: w, count: e.count, strength: strengthOf(w),
      label: e.count > 1 ? (REL[e.type].label + ' ×' + e.count) : REL[e.type].label };
  });
  var viewNodes = ids.map(function (id) { return NODES[id]; });
  Object.keys(boundaryUsed).forEach(function (bid) { viewNodes.push(NODES[bid]); });
  viewNodes.forEach(function (n) { n.hidden = n.confidence < threshold; });
  return { viewNodes: viewNodes, viewEdges: viewEdges };
}
// ── 布局状态 ──
var canvas = $('#graphCanvas'), ctx = canvas.getContext('2d'), mini = $('#miniCanvas'), mctx = mini.getContext('2d'), wrap = $('#canvasWrap');
var zoom = 1, panX = 0, panY = 0, worldNodes = [], worldEdges = [], layerBands = [], worldWidth = 800, worldHeight = 600;
var dragging = null, lastPointer = null, panning = false, hoverNode = null, hasFit = false;
var cssW = 800, cssH = 600, dpr = window.devicePixelRatio || 1;
var breathEnabled = !window.matchMedia('(prefers-reduced-motion: reduce)').matches;
var animationTime = 0, lastAnimationFrame = 0, animationRequest = 0;
var relationType = 'all', threshold = 0, pathMode = false;
var ambientStars = [];
(function () {
  for (var i = 0; i < 42; i++) {
    ambientStars.push({ x: ((Math.sin(i * 127.1) * 43758.5453) % 1 + 1) % 1, y: ((Math.sin(i * 269.5 + 4.7) * 24634.6345) % 1 + 1) % 1,
      r: 0.45 + ((i * 7) % 9) / 10, phase: (i * 1.73) % 6.28, speed: 0.15 + ((i * 13) % 9) / 28,
      hue: i % 4 === 0 ? '#b69cff' : (i % 3 === 0 ? '#5fdcff' : '#59f0b8') });
  }
})();
function drawAtmosphere() {
  var t = animationTime;
  var blooms = [
    { x: cssW * (0.2 + 0.045 * Math.sin(t * 0.13)), y: cssH * (0.24 + 0.045 * Math.cos(t * 0.17)), r: Math.max(cssW, cssH) * 0.35, c: '#278db8', a: 0.075 },
    { x: cssW * (0.78 + 0.035 * Math.cos(t * 0.11)), y: cssH * (0.28 + 0.05 * Math.sin(t * 0.15)), r: Math.max(cssW, cssH) * 0.31, c: '#9271ec', a: 0.065 },
    { x: cssW * (0.62 + 0.035 * Math.sin(t * 0.09)), y: cssH * (0.84 + 0.035 * Math.cos(t * 0.12)), r: Math.max(cssW, cssH) * 0.28, c: '#28b98b', a: 0.045 }
  ];
  for (var bi = 0; bi < blooms.length; bi++) {
    var b = blooms[bi];
    var ring;
    for (ring = 6; ring >= 1; ring--) {
      ctx.globalAlpha = (b.a / 6) * ring * 0.55;
      ctx.fillStyle = b.c;
      ctx.beginPath(); ctx.arc(b.x, b.y, b.r * ring / 6, 0, 6.2832); ctx.fill();
    }
  }
  for (var si = 0; si < ambientStars.length; si++) {
    var star = ambientStars[si];
    var x = ((star.x + t * star.speed * 0.009) % 1) * cssW;
    var y = ((star.y + Math.sin(t * 0.32 + star.phase) * 0.012 + 1) % 1) * cssH;
    var pulse = breathEnabled ? 0.45 + 0.55 * (0.5 + 0.5 * Math.sin(t * 1.7 + star.phase)) : 0.55;
    ctx.globalAlpha = 0.12 + pulse * 0.22;
    ctx.fillStyle = star.hue;
    ctx.beginPath(); ctx.arc(x, y, star.r * (0.85 + pulse * 0.25), 0, 6.2832); ctx.fill();
  }
  ctx.globalAlpha = 1;
}
function visualLayer(n) {
  if (n.type === 'module') { return { key: 'module', rank: 0, label: T.bandModules }; }
  if (n.type === 'boundary') { return { key: 'boundary', rank: 5, label: T.bandBoundary }; }
  if (n.type === 'file') { return { key: 'file', rank: 1, label: T.bandFiles }; }
  if (n.type === 'type') { return { key: 'types', rank: 2, label: T.bandTypes }; }
  return { key: 'funcs', rank: 3, label: T.bandFuncs };
}
function nodeBoxSize(n) {
  if (n.type === 'module') { return { w: 188, h: 108 }; }
  if (n.type === 'boundary') { return { w: 166, h: 66 }; }
  if (n.type === 'file') { return { w: 194, h: 88 }; }
  if (n.type === 'type') { return { w: 184, h: 76 }; }
  return { w: 184, h: 76 };
}
function settleScatterLayer(arr, xMin, xMax, top, bottom) {
  for (var iter = 0; iter < 220; iter++) {
    var moved = false;
    for (var i = 0; i < arr.length; i++) {
      for (var j = i + 1; j < arr.length; j++) {
        var a = arr[i], b = arr[j];
        var ox = Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x) + 16;
        var oy = Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y) + 12;
        if (ox <= 0 || oy <= 0) { continue; }
        if (ox < oy) {
          var dir = (a.x + a.w / 2) <= (b.x + b.w / 2) ? -1 : 1;
          var d = ox / 2 + 1;
          a.x = clampNum(a.x + dir * d, xMin, xMax - a.w);
          b.x = clampNum(b.x - dir * d, xMin, xMax - b.w);
        } else {
          var dir2 = (a.y + a.h / 2) <= (b.y + b.h / 2) ? -1 : 1;
          var d2 = oy / 2 + 1;
          a.y = clampNum(a.y + dir2 * d2, top, bottom - a.h);
          b.y = clampNum(b.y - dir2 * d2, top, bottom - b.h);
        }
        moved = true;
      }
    }
    if (!moved) { break; }
  }
}
// 关系驱动的网格重排（确定性）：行内按邻居 x 重心、列内按邻居 y 重心，
// 各扫 3 轮——强关联的卡被换到相邻格位，连线变短变直，「挨着的就是有关系」。
// 只在网格格位之间对换，铺排的工整性不破坏。
function barySweepGrid(viewEdges, placed) {
  var byId = {};
  placed.forEach(function (p) { byId[p.id] = p; });
  function bary(id, axis) {
    var sum = 0, w = 0;
    var self = byId[id];
    viewEdges.forEach(function (e) {
      var other = null;
      if (e.s === id) { other = e.t; } else if (e.t === id) { other = e.s; }
      if (!other || !byId[other]) { return; }
      var q = byId[other];
      var ww = Math.max(0.5, e.strength || 0.5);
      sum += (axis === 'x' ? q.x + q.w / 2 : q.y + q.h / 2) * ww;
      w += ww;
    });
    if (!w) { return axis === 'x' ? self.x + self.w / 2 : self.y + self.h / 2; }
    return sum / w;
  }
  for (var pass = 0; pass < 3; pass++) {
    // 行内重排 x
    var rowsC = {};
    placed.forEach(function (p) {
      var k = Math.round(p.y / 10);
      if (!rowsC[k]) { rowsC[k] = []; }
      rowsC[k].push(p);
    });
    Object.keys(rowsC).forEach(function (k) {
      var row = rowsC[k];
      if (row.length < 2) { return; }
      var slots = row.map(function (p) { return p.x; }).sort(function (a, b) { return a - b; });
      row.sort(function (a, b) { return bary(a.id, 'x') - bary(b.id, 'x') || hashSeed(a.id) - hashSeed(b.id); });
      row.forEach(function (p, i) { p.x = slots[i]; });
    });
    // 列内重排 y
    var colsC = {};
    placed.forEach(function (p) {
      var k = Math.round(p.x / 10);
      if (!colsC[k]) { colsC[k] = []; }
      colsC[k].push(p);
    });
    Object.keys(colsC).forEach(function (k) {
      var col = colsC[k];
      if (col.length < 2) { return; }
      var slots2 = col.map(function (p) { return p.y; }).sort(function (a, b) { return a - b; });
      col.sort(function (a, b) { return bary(a.id, 'y') - bary(b.id, 'y') || hashSeed(a.id) - hashSeed(b.id); });
      col.forEach(function (p, i) { p.y = slots2[i]; });
    });
  }
}
function layoutGraph() {
  var mapped = mapCurrentGraph();
  var visible = mapped.viewNodes.filter(function (n) { return !n.hidden; });
  if (!visible.length) { worldNodes = []; worldEdges = []; layerBands = []; paintCounts(); draw(); return; }
  var groupsMap = {};
  var groups = [];
  visible.forEach(function (n) {
    var v = visualLayer(n);
    n._layerKey = v.key; n._layerRank = v.rank;
    if (!groupsMap[v.key]) { groupsMap[v.key] = { key: v.key, rank: v.rank, label: v.label, nodes: [] }; groups.push(groupsMap[v.key]); }
    groupsMap[v.key].nodes.push(n);
  });
  groups.sort(function (a, b) { return a.rank - b.rank; });
  // 有序网格铺排（用户验收定稿：散点堆叠改为「一眼可读顺序」）——
  // 带内先按语义键排序（模块/文件按名、符号按代码行、边界按名），
  // 再行主序铺进网格；#序号徽标 + 网格行列让顺序可直接读出来。
  // 网格间距放大（散开），重心/力松弛两道工序删除——它们会把顺序搅乱。
  function orderKey(n) {
    if (n.type === 'method' || n.type === 'type') { return [n.line || 0, n.name]; }
    return [0, n.name];
  }
  groups.forEach(function (g) {
    g.nodes.sort(function (a, b) {
      var ka = orderKey(a), kb = orderKey(b);
      if (ka[0] !== kb[0]) { return ka[0] - kb[0]; }
      return ka[1] < kb[1] ? -1 : (ka[1] > kb[1] ? 1 : 0);
    });
  });
  var GAPX = 78, GAPY = 84;   // 网格间距：行隙同时是走线通道（要容得下车道分流）
  var left = 56;
  var maxCellW = 120, maxCellH = 70;
  groups.forEach(function (g) {
    g.nodes.forEach(function (n) {
      var s = nodeBoxSize(n);
      if (s.w > maxCellW) { maxCellW = s.w; }
      if (s.h > maxCellH) { maxCellH = s.h; }
    });
  });
  var cellW = maxCellW + GAPX, cellH = maxCellH + GAPY;
  var layout = groups.map(function (g) {
    var n = g.nodes.length;
    var cols = Math.max(1, Math.min(n, Math.ceil(Math.sqrt(n * 1.7))));
    var rows = Math.ceil(n / cols);
    return { cols: cols, rows: rows, w: left * 2 + cols * cellW - GAPX, h: 40 + rows * cellH - GAPY + 70 };
  });
  var worldW = Math.max(cssW - 76, 0);
  layout.forEach(function (L) { if (L.w > worldW) { worldW = L.w; } });
  worldWidth = worldW;
  var gap = groups.length > 1 ? 84 : 0;   // 带间 = 走线通道（跨带边的水平走廊）
  var hsum = 0; layout.forEach(function (L) { hsum += L.h; });
  worldHeight = Math.max(cssH - 78, 32 + hsum + gap * (groups.length - 1) + 28);
  layerBands = [];
  var laneY = 28;
  var placed = []; var byId = {};
  groups.forEach(function (group, groupIndex) {
    var L = layout[groupIndex];
    layerBands.push({ y: laneY, h: L.h, label: group.label, key: group.key });
    var top = laneY + 32;
    var gridW = L.cols * cellW - GAPX;
    var offX = Math.max(left, (worldWidth - gridW) / 2);   // 网格整体居中（列对齐 = 顺序可读）
    group.nodes.forEach(function (n, i) {
      var size = nodeBoxSize(n);
      var col = i % L.cols, row = (i / L.cols) | 0;
      n._rank = i + 1;   // 带内顺序 → 卡片 #徽标
      var out = { data: n, id: n.id,
        x: offX + col * cellW + (cellW - GAPX - size.w) / 2,
        y: top + row * cellH + (cellH - GAPY - size.h) / 2,
        w: size.w, h: size.h, layerIndex: groupIndex, layerLabel: group.label };
      placed.push(out); byId[n.id] = out;
    });
    laneY += L.h + gap;
  });
  // 关系聚类重排：格位对换，强关联卡相邻（连线因此变短变直）
  barySweepGrid(mapped.viewEdges, placed);
  // #序号 = 最终排布的阅读序（行主序，带内各自编号）
  groups.forEach(function (g, gi) {
    var inBand = placed.filter(function (p) { return p.layerIndex === gi; });
    inBand.sort(function (a, b) { return (a.y - b.y) || (a.x - b.x); });
    inBand.forEach(function (p, i) { p.data._rank = i + 1; });
  });
  worldNodes = placed;
  var pos = {};
  worldNodes.forEach(function (n) { pos[n.id] = n; });
  worldEdges = mapped.viewEdges.filter(function (e) { return pos[e.s] && pos[e.t] && e.s !== e.t; })
    .map(function (e) { var we = {}; for (var k2 in e) { we[k2] = e[k2]; } we.na = pos[e.s]; we.nb = pos[e.t]; return we; });
  routeWorldEdges(false);
  paintCounts();
  draw();
}
function paintCounts() {
  $('#visibleCount').textContent = worldNodes.length + ' ' + T.nodes + ' · ' + worldEdges.length + ' ' + T.rels;
  var scope = NODES[scopeId];
  $('#scopeCount').textContent = scopeId === 'project' ? (worldNodes.length + ' ' + T.bandModules) : (worldNodes.length + ' NODES');
  $('#graphScopeTitle').textContent = scopeId === 'project' ? (D.project || 'project') + ' · ' + T.tp.project : scope.name + ' · ' + T.tp[scope.type];
  $('#levelTag').textContent = scopeId === 'project' ? 'PROJECT' : String(scope.type).toUpperCase();
}
// ── 直角正交布线（用户验收四轮定稿：轨迹要像电路走线一样一眼可追）──
// 源卡底/顶出 → 行间水平通道 → 列间隙垂直段 → 目标侧通道 → 进目标端口。
// 同通道多条边按确定性次序分车道并排（总线观感）；垂直段会被中间行卡片
// 挡住时平移到最近的列间隙。折线圆角拐弯（arcTo），粒子沿折线展示流向。
function portAnchor(n, side, t) {
  var inset = 12;
  if (side === 'left') { return { x: n.x, y: n.y + inset + t * Math.max(1, n.h - 2 * inset) }; }
  if (side === 'right') { return { x: n.x + n.w, y: n.y + inset + t * Math.max(1, n.h - 2 * inset) }; }
  if (side === 'top') { return { x: n.x + inset + t * Math.max(1, n.w - 2 * inset), y: n.y }; }
  return { x: n.x + inset + t * Math.max(1, n.w - 2 * inset), y: n.y + n.h };
}
function polylinePoint(points, t) {
  var total = 0; var i;
  var lens = [0];
  for (i = 1; i < points.length; i++) {
    var dx = points[i].x - points[i - 1].x, dy = points[i].y - points[i - 1].y;
    total += Math.sqrt(dx * dx + dy * dy);
    lens.push(total);
  }
  var target = t * total;
  for (i = 1; i < points.length; i++) {
    if (lens[i] >= target) {
      var seg = (lens[i] - lens[i - 1]) || 1;
      var k = (target - lens[i - 1]) / seg;
      return { x: points[i - 1].x + (points[i].x - points[i - 1].x) * k,
        y: points[i - 1].y + (points[i].y - points[i - 1].y) * k };
    }
  }
  return points[points.length - 1];
}
// ── 自适应贝塞尔走线（用户验收六轮定稿）：随端点变形的平滑曲线，不是
// 固定形态的折线圆角。控制点从两端端口沿竖直方向拉出（拉距 ∝ 端点间
// 距），曲线形状随两卡的距离与方位自然变化；同行卡走底部 U 形回绕。
// 布局已按关系聚类（barySweepGrid），短边为主，曲线天然清晰；线画在
// 卡片下层，穿过卡区的部分被卡片盖住，不添乱。
function portAnchor(n, side, t) {
  var inset = 12;
  if (side === 'left') { return { x: n.x, y: n.y + inset + t * Math.max(1, n.h - 2 * inset) }; }
  if (side === 'right') { return { x: n.x + n.w, y: n.y + inset + t * Math.max(1, n.h - 2 * inset) }; }
  if (side === 'top') { return { x: n.x + inset + t * Math.max(1, n.w - 2 * inset), y: n.y }; }
  return { x: n.x + inset + t * Math.max(1, n.w - 2 * inset), y: n.y + n.h };
}
function bezierSamples(sx, sy, tx, ty, c1y, c2y, per) {
  var out = [];
  for (var j = 0; j <= per; j++) {
    var t = j / per, u = 1 - t;
    out.push({ x: u * u * u * sx + 3 * u * u * t * sx + 3 * u * t * t * tx + t * t * t * tx,
      y: u * u * u * sy + 3 * u * u * t * c1y + 3 * u * t * t * c2y + t * t * t * ty });
  }
  return out;
}
// ── 双态走线（用户验收七轮定稿）：
//   静态 = 直角正交（物理通道车道：行隙/带隙内分道并排，电路板观感）；
//   拖拽 = 全线退化为自由贝塞尔（端口按卡位即时计算，肆意变形），
//   松手后重算正交归位。一动一静：拖图时「活」，静下来「清晰」。
function portAnchor(n, side, t) {
  var inset = 12;
  if (side === 'left') { return { x: n.x, y: n.y + inset + t * Math.max(1, n.h - 2 * inset) }; }
  if (side === 'right') { return { x: n.x + n.w, y: n.y + inset + t * Math.max(1, n.h - 2 * inset) }; }
  if (side === 'top') { return { x: n.x + inset + t * Math.max(1, n.w - 2 * inset), y: n.y }; }
  return { x: n.x + inset + t * Math.max(1, n.w - 2 * inset), y: n.y + n.h };
}
function routeWorldEdges(fast) {
  if (!worldEdges.length) { return; }
  // 行聚类：带内卡片按 y 顶聚成行
  var rowsByBand = {};
  worldNodes.forEach(function (n) {
    if (!rowsByBand[n.layerIndex]) { rowsByBand[n.layerIndex] = []; }
    var rows = rowsByBand[n.layerIndex];
    var row = null;
    rows.forEach(function (r) { if (Math.abs(r.top - n.y) < 20) { row = r; } });
    if (!row) { row = { top: n.y, bottom: n.y + n.h, cards: [] }; rows.push(row); }
    row.top = Math.min(row.top, n.y);
    row.bottom = Math.max(row.bottom, n.y + n.h);
    row.cards.push(n);
  });
  Object.keys(rowsByBand).forEach(function (k) {
    rowsByBand[k].sort(function (a, b) { return a.top - b.top; });
    rowsByBand[k].forEach(function (r) { r.cards.sort(function (a, b) { return a.x - b.x; }); });
  });
  function rowOf(n) {
    var rows = rowsByBand[n.layerIndex] || [];
    for (var i = 0; i < rows.length; i++) {
      if (n.y >= rows[i].top - 6 && n.y <= rows[i].top + 24) { return { band: n.layerIndex, idx: i, row: rows[i] }; }
    }
    return { band: n.layerIndex, idx: 0, row: rows[0] };
  }
  function rbCorridor(band, idx) {
    var rows = rowsByBand[band];
    return { key: 'rb:' + band + ':' + idx,
      center: (rows[idx].bottom + rows[idx + 1].top) / 2,
      span: Math.max(10, rows[idx + 1].top - rows[idx].bottom - 6) };
  }
  function ibCorridor(band) {
    var bb = layerBands[band];
    return { key: 'ib:' + band,
      center: (bb.y + bb.h + layerBands[band + 1].y) / 2,
      span: Math.max(10, layerBands[band + 1].y - bb.y - bb.h - 6) };
  }
  function bbCorridor(band) {
    var bb = layerBands[band];
    return { key: 'bb:' + band, center: bb.y + bb.h - 35, span: 60 };
  }
  var portGroups = {};
  function addPort(node, side, e, which, other) {
    var key = node.id + '|' + side;
    if (!portGroups[key]) { portGroups[key] = []; }
    portGroups[key].push({ node: node, side: side, e: e, which: which, other: other });
  }
  worldEdges.forEach(function (e) {
    var rs = rowOf(e.na), rt = rowOf(e.nb);
    var sameRow = rs.band === rt.band && rs.idx === rt.idx;
    var down = rt.band > rs.band || (rt.band === rs.band && rt.idx > rs.idx);
    e._down = down;
    e._sameRow = sameRow;
    addPort(e.na, sameRow ? 'bottom' : (down ? 'bottom' : 'top'), e, 's', e.nb);
    addPort(e.nb, sameRow ? 'bottom' : (down ? 'top' : 'bottom'), e, 't', e.na);
  });
  Object.keys(portGroups).forEach(function (key) {
    var arr = portGroups[key];
    arr.sort(function (a, b) {
      var av = a.other.x + a.other.w / 2;
      var bv = b.other.x + b.other.w / 2;
      return av - bv || hashSeed(a.e.s + a.e.t + a.e.type) - hashSeed(b.e.s + b.e.t + b.e.type);
    });
    arr.forEach(function (p, i) {
      var t = arr.length === 1 ? 0.5 : 0.12 + 0.76 * i / (arr.length - 1);
      var anchor = portAnchor(p.node, p.side, t);
      if (p.which === 's') { p.e._sx = anchor.x; p.e._sy = anchor.y; p.e._sSide = p.side; p.e._st = t; }
      else { p.e._tx = anchor.x; p.e._ty = anchor.y; p.e._tSide = p.side; p.e._tt = t; }
    });
  });
  var corridors = {};
  function register(corridor, e, which) {
    if (!corridors[corridor.key]) { corridors[corridor.key] = { center: corridor.center, span: corridor.span, edges: [] }; }
    corridors[corridor.key].edges.push({ e: e, which: which });
  }
  worldEdges.forEach(function (e) {
    var rs = e._rs = rowOf(e.na), rt = e._rt = rowOf(e.nb);
    if (e._sameRow) {
      var c0 = bbCorridor(rs.band);
      e._corA = c0.key; e._corB = c0.key;
      register(c0, e, 'A');
      return;
    }
    if (e._down) {
      var ca = (rs.idx + 1 < (rowsByBand[rs.band] || []).length) ? rbCorridor(rs.band, rs.idx) : ibCorridor(rs.band);
      var cb = (rt.idx > 0) ? rbCorridor(rt.band, rt.idx - 1) : ibCorridor(rt.band - 1);
      e._corA = ca.key; e._corB = cb.key;
      register(ca, e, 'A'); register(cb, e, 'B');
    } else {
      var ca2 = (rs.idx > 0) ? rbCorridor(rs.band, rs.idx - 1) : ibCorridor(rs.band - 1);
      var cb2 = (rt.idx + 1 < (rowsByBand[rt.band] || []).length) ? rbCorridor(rt.band, rt.idx) : ibCorridor(rt.band);
      e._corA = ca2.key; e._corB = cb2.key;
      register(ca2, e, 'A'); register(cb2, e, 'B');
    }
  });
  Object.keys(corridors).forEach(function (k) {
    var cor = corridors[k];
    cor.edges.sort(function (a, b) {
      var ea = a.e, eb = b.e;
      var ma = (ea._sx + ea._tx) / 2, mb = (eb._sx + eb._tx) / 2;
      return ma - mb || hashSeed(ea.s + ea.t) - hashSeed(eb.s + eb.t);
    });
    var n = cor.edges.length;
    var spacing = Math.max(2.6, Math.min(7, cor.span / (n + 1)));
    cor.edges.forEach(function (p, i) {
      var off = (i - (n - 1) / 2) * spacing;
      if (p.which === 'A') { p.e._yA = cor.center + off; }
      if (p.which === 'B') { p.e._yB = cor.center + off; }
    });
  });
  worldEdges.forEach(function (e) {
    var yA = (e._yA !== undefined) ? e._yA : e._sy;
    var yB = (e._yB !== undefined) ? e._yB : e._ty;
    var pts = [{ x: e._sx, y: e._sy }, { x: e._sx, y: yA }];
    if (e._sameRow) {
      pts.push({ x: e._tx, y: yA });
    } else {
      var lo = Math.min(yA, yB), hi = Math.max(yA, yB);
      var blocked = false;
      for (var ni = 0; ni < worldNodes.length && !blocked; ni++) {
        var n = worldNodes[ni];
        if (n.id === e.a || n.id === e.b) { continue; }
        if (n.y + n.h > lo + 4 && n.y < hi - 4 && e._tx > n.x + 6 && e._tx < n.x + n.w - 6) { blocked = true; }
      }
      if (!blocked) {
        pts.push({ x: e._tx, y: yA });
        if (Math.abs(yB - yA) > 2) { pts.push({ x: e._tx, y: yB }); }
      } else {
        var cands = [];
        worldNodes.forEach(function (n2) {
          if (n2.y + n2.h <= lo + 4 || n2.y >= hi - 4) { return; }
          if (e._tx > n2.x + 6 && e._tx < n2.x + n2.w - 6) { cands.push(n2.x - 26); cands.push(n2.x + n2.w + 26); }
        });
        cands.sort(function (a, b2) { return Math.abs(a - e._tx) - Math.abs(b2 - e._tx); });
        var vx = (cands.length ? cands[0] : e._tx) + (hashSeed(e.s + e.t) % 3 - 1) * 5;
        pts.push({ x: vx, y: yA });
        pts.push({ x: vx, y: yB });
        pts.push({ x: e._tx, y: yB });
      }
    }
    pts.push({ x: e._tx, y: e._ty });
    var clean = [pts[0]];
    for (var i = 1; i < pts.length; i++) {
      var p = pts[i], q = clean[clean.length - 1];
      if (Math.abs(p.x - q.x) > 1 || Math.abs(p.y - q.y) > 1) { clean.push(p); }
    }
    if (clean.length < 2) { clean.push({ x: e._tx + 1, y: e._ty }); }
    e.route = { points: clean };
  });
}
function drawEdge(e, index) {
  var a = e.na, b = e.nb, r = e.route;
  if (!a || !b || !r || !r.points || r.points.length < 2) { return; }
  var rel = REL[e.type] || { label: e.type, color: '#7a8c9f', dash: [] };
  // 拖拽态：全线退化为自由贝塞尔——端口按当前卡位即时重算（肆意变形），
  // 松手后 routeWorldEdges 重算正交，界面「活一下再归位」
  var pts;
  if (dragging) {
    var dS = portAnchor(a, e._sSide || 'bottom', e._st || 0.5);
    var dT = portAnchor(b, e._tSide || 'top', e._tt || 0.5);
    var sameRowD = Math.abs(b.y - a.y) < 24;
    var c1yD; var c2yD;
    if (sameRowD) {
      var dropD = Math.min(130, 46 + Math.abs(dT.x - dS.x) * 0.14);
      c1yD = dS.y + dropD; c2yD = dT.y + dropD;
    } else {
      c1yD = dS.y + (dT.y - dS.y) * 0.45;
      c2yD = dT.y - (dT.y - dS.y) * 0.45;
    }
    pts = [];
    for (var bi = 0; bi <= 18; bi++) {
      var bt = bi / 18, bu = 1 - bt;
      pts.push({ x: bu * bu * bu * dS.x + 3 * bu * bu * bt * dS.x + 3 * bu * bt * bt * dT.x + bt * bt * bt * dT.x,
        y: bu * bu * bu * dS.y + 3 * bu * bu * bt * c1yD + 3 * bu * bt * bt * c2yD + bt * bt * bt * dT.y });
    }
  } else {
    pts = r.points;
  }
  var rel = REL[e.type] || { label: e.type, color: '#7a8c9f', dash: [] };
  // 线色 = 来源节点身份色（与卡的左色条同色）——「谁和谁有关系」一眼可读
  var srcNode = NODES[e.s];
  var ecol = srcNode ? hueCss(hueOf(srcNode)) : rel.color;
  // 连线明确：pathMode 看选中、常态看悬停——聚焦后无关边退淡到 0.12，
  // 直接相连的边满亮（「谁连谁」不需要追线就能读出来）
  var focusId = null;
  if (pathMode && selectedId) { focusId = selectedId; }
  else if (hoverNode) { focusId = hoverNode.data.id; }
  var isPath = !!focusId && (a.id === focusId || b.id === focusId);
  var fade = focusId && !isPath ? 0.12 : 1;
  var pulse = breathEnabled ? 0.5 + 0.5 * Math.sin(animationTime * 1.5 + index * 0.73) : 0.2;
  ctx.globalAlpha = fade * (isPath ? 0.95 : 0.62);
  ctx.strokeStyle = ecol;
  ctx.lineWidth = (isPath ? 3 : 1.15 + e.strength * 1.0 + (breathEnabled ? pulse * 0.2 : 0)) / (zoom < 0.65 ? 1.25 : 1);
  ctx.setLineDash(rel.dash);
  ctx.lineDashOffset = breathEnabled ? -animationTime * 7 : 0;
  // 折线圆角拐弯（arcTo）——横平竖直、拐角柔和
  var sp = pts;
  ctx.beginPath(); ctx.moveTo(sp[0].x, sp[0].y);
  if (dragging) {
    for (var di = 1; di < sp.length; di++) { ctx.lineTo(sp[di].x, sp[di].y); }
    var lastP = sp[sp.length - 1];
  } else {
    for (var si = 1; si < sp.length - 1; si++) { ctx.arcTo(sp[si].x, sp[si].y, sp[si + 1].x, sp[si + 1].y, 9); }
    var lastP = sp[sp.length - 1];
    ctx.lineTo(lastP.x, lastP.y);
  }
  ctx.stroke();
  ctx.setLineDash([]); ctx.lineDashOffset = 0;
  // 箭头（末段方向，加大加不透明——方向不用猜）
  var prev = sp[sp.length - 2] || pts[pts.length - 2];
  var ang = Math.atan2(lastP.y - prev.y, lastP.x - prev.x), tip = 7.5;
  ctx.globalAlpha = fade * 0.95;
  ctx.fillStyle = ecol;
  ctx.beginPath(); ctx.moveTo(lastP.x, lastP.y);
  ctx.lineTo(lastP.x - tip * Math.cos(ang - 0.44), lastP.y - tip * Math.sin(ang - 0.44));
  ctx.lineTo(lastP.x - tip * Math.cos(ang + 0.44), lastP.y - tip * Math.sin(ang + 0.44));
  ctx.closePath(); ctx.fill();
  // 粒子沿折线流动（运行轨迹的方向指示）
  if (breathEnabled) {
    var t = (animationTime * (0.14 + e.strength * 0.03) + index * 0.217) % 1;
    var p = polylinePoint(sp, t), tail = polylinePoint(sp, Math.max(0, t - 0.06));
    ctx.globalAlpha = fade * 0.75;
    ctx.strokeStyle = rgba(ecol, 0.5);
    ctx.lineWidth = 2.1;
    ctx.beginPath(); ctx.moveTo(tail.x, tail.y); ctx.lineTo(p.x, p.y); ctx.stroke();
    for (var ring = 3; ring >= 1; ring--) {
      ctx.globalAlpha = fade * (0.28 / ring);
      ctx.fillStyle = ecol;
      ctx.beginPath(); ctx.arc(p.x, p.y, 7 * ring / 3, 0, 6.2832); ctx.fill();
    }
    ctx.globalAlpha = fade;
    ctx.fillStyle = '#f3fbff';
    ctx.beginPath(); ctx.arc(p.x, p.y, 1.8 + (isPath ? 1 : 0), 0, 6.2832); ctx.fill();
    var p2 = polylinePoint(sp, (t + 0.5) % 1);
    ctx.globalAlpha = fade * 0.48;
    ctx.fillStyle = ecol;
    ctx.beginPath(); ctx.arc(p2.x, p2.y, 1.35, 0, 6.2832); ctx.fill();
  }
  if (e.count > 1 && zoom > 0.68) {
    var mid = polylinePoint(sp, 0.5);
    ctx.globalAlpha = fade;
    ctx.font = '9px ' + MONO;
    ctx.fillStyle = ecol;
    ctx.textAlign = 'left';
    ctx.fillText('×' + e.count, mid.x + 5, mid.y - 5);
  }
  ctx.globalAlpha = 1;
}
function roundedRect(c, x, y, w, h, r) {
  c.beginPath(); c.moveTo(x + r, y); c.arcTo(x + w, y, x + w, y + h, r); c.arcTo(x + w, y + h, x, y + h, r);
  c.arcTo(x, y + h, x, y, r); c.arcTo(x, y, x + w, y, r); c.closePath();
}
function wrapText(c, text, x, y, maxWidth, lineHeight, maxLines) {
  var words = String(text).split('');
  var line = ''; var lines = [];
  for (var i = 0; i < words.length; i++) {
    var test = line + words[i];
    if (test.length * 6.2 > maxWidth && line) { lines.push(line); line = words[i]; } else { line = test; }
  }
  if (line) { lines.push(line); }
  if (lines.length > maxLines) {
    lines = lines.slice(0, maxLines);
    lines[maxLines - 1] = lines[maxLines - 1].slice(0, Math.max(1, lines[maxLines - 1].length - 1)) + '…';
  }
  lines.forEach(function (l, i) { c.fillText(l, x, y + i * lineHeight); });
}
var MONO = 'ui-monospace, Menlo, Consolas, monospace';
function drawNode(n, index) {
  var x = n.x, y = n.y, w = n.w, h = n.h;
  var data = n.data;
  var score = data.confidence, col = confidenceColor(score);
  var isSelected = data.id === selectedId, isHover = hoverNode === n;
  var isBoundary = data.type === 'boundary';
  var phase = phaseOf(data.id);
  var pulse = breathEnabled ? 0.5 + 0.5 * Math.sin(animationTime * 1.9 + phase) : 0.2;
  // 焦点退淡（与 drawEdge 同一 focusId 口径）：pathMode 看选中、常态看
  // 悬停——聚焦后非邻接卡片退到 0.5，邻接卡满亮，连线归属连带可读
  var focusId0 = null;
  if (pathMode && selectedId) { focusId0 = selectedId; }
  else if (hoverNode) { focusId0 = hoverNode.data.id; }
  var dimmed0 = !!focusId0 && data.id !== focusId0;
  var adj = true;
  if (dimmed0) {
    adj = worldEdges.some(function (e) { return (e.a === data.id || e.b === data.id) && (e.a === focusId0 || e.b === focusId0); });
  }
  var dimA = dimmed0 ? (adj ? 0.98 : 0.5) : 1;
  ctx.globalAlpha = dimA;
  var grow = 1 + pulse * 0.003 + (isSelected ? 0.003 : 0);
  if (breathEnabled) {
    x = x + w / 2 - (w * grow) / 2; y = y + h / 2 - (h * grow) / 2;
    w = w * grow; h = h * grow;
  }
  ctx.globalAlpha = dimA;
  // 呼吸只暴露在框体内（用户验收定稿）：无外圈光晕、常态无 shadow 外溢——
  // 置信度色深度由「卡片填充 + 边框 + 左色条」自身承载；外发光只留给选中态
  var baseFill = isBoundary ? '#111c2a' : (data.type === 'module' ? '#132134' : '#131f30');
  var heatAlpha = (score < 60 ? 0.20 : (score < 80 ? 0.16 : 0.12)) + (breathEnabled ? pulse * 0.05 : 0);
  ctx.shadowColor = col;
  ctx.shadowBlur = isSelected ? 16 : 0;
  roundedRect(ctx, x, y, w, h, 10);
  var cardGrad = ctx.createLinearGradient(x, y, x + w, y + h);
  cardGrad.addColorStop(0, baseFill);
  cardGrad.addColorStop(1, rgba(col, heatAlpha));
  ctx.fillStyle = cardGrad; ctx.fill();
  // 框体内的顶部热色沉积（第二层填充，仍被卡片路径裁住）
  ctx.fillStyle = rgba(col, heatAlpha * 0.5);
  ctx.fill();
  ctx.shadowBlur = 0;
  // 边框呼吸：宽度与亮度随 pulse 微幅波动（不出框）
  ctx.lineWidth = isSelected ? 2 : (isHover ? 1.8 : (data.cov < 75 ? 1.3 : 1.15)) + (breathEnabled ? pulse * 0.3 : 0);
  ctx.strokeStyle = (isSelected || isHover) ? col : (data.cov < 75 ? '#9b9aae' : rgba(col, 0.55 + pulse * 0.25));
  if (data.cov < 75 && !isSelected && !isHover) { ctx.setLineDash([4, 3]); ctx.lineDashOffset = breathEnabled ? -animationTime * 5 : 0; }
  ctx.stroke(); ctx.setLineDash([]); ctx.lineDashOffset = 0;
  if (breathEnabled) {
    var sweep = ((animationTime * 0.13 + phase * 0.11) % 1) * (w - 26);
    var sg = ctx.createLinearGradient(x + 13 + sweep - 18, y + 1, x + 13 + sweep + 18, y + 1);
    sg.addColorStop(0, rgba(col, 0)); sg.addColorStop(0.5, rgba(col, 0.42)); sg.addColorStop(1, rgba(col, 0));
    ctx.strokeStyle = sg; ctx.lineWidth = 1;
    ctx.beginPath(); ctx.moveTo(x + 13, y + 1); ctx.lineTo(x + w - 13, y + 1); ctx.stroke();
  }
  roundedRect(ctx, x, y, 4, h, 3);
  ctx.fillStyle = hueCss(hueOf(data));   // 左色条 = 身份色（出边同色，线归谁一眼可读）
  ctx.fill();
  var pad = 13, font = MONO;
  // 排列序号：带内读取顺序（模块/文件按名、符号按代码行）——一眼可读
  var rankTxt = data._rank ? ('#' + data._rank + ' ') : '';
  if (data.type === 'boundary') {
    ctx.fillStyle = '#94aac1'; ctx.font = '8px ' + font; ctx.textAlign = 'left';
    ctx.fillText(T.boundaryOf.toUpperCase(), x + pad, y + 13);
    ctx.fillStyle = '#edf5ff'; ctx.font = '600 10px ' + font;
    wrapText(ctx, data.name, x + pad, y + 30, w - pad * 2 - 27, 12, 1);
    ctx.fillStyle = col; ctx.font = '700 12px ' + font; ctx.textAlign = 'right';
    ctx.fillText(String(Math.round(score)), x + w - 9, y + 15);
    ctx.textAlign = 'left';
    meterBar(x + pad, y + h - 8, w - pad * 2, score, col, pulse);
  } else if (data.type === 'module') {
    ctx.fillStyle = '#91a8c0'; ctx.font = '9px ' + font; ctx.textAlign = 'left';
    ctx.fillText(rankTxt + 'MODULE', x + pad, y + 19);
    ctx.fillStyle = '#eaf3ff'; ctx.font = '600 13px ' + font;
    wrapText(ctx, data.name, x + pad, y + 39, w - pad * 2 - 40, 15, 1);
    ctx.fillStyle = '#8ca2b8'; ctx.font = '9px ' + font;
    ctx.fillText(data.files + ' ' + T.files + ' · ' + data.symbols + ' ' + T.syms, x + pad, y + h - 22);
    ctx.fillStyle = col; ctx.font = '700 16px ' + font; ctx.textAlign = 'right';
    ctx.fillText(String(Math.round(score)), x + w - 12, y + 31);
    ctx.textAlign = 'left';
    meterBar(x + pad, y + h - 12, w - pad * 2, score, col, pulse);
    if (zoom > 0.65) {
      var tag = '⚠' + cntOf(data);
      ctx.font = '8px ' + font;
      var tw = tag.length * 5.6 + 10;
      roundedRect(ctx, x + w - tw - 10, y + h - 28, tw, 14, 4);
      ctx.fillStyle = '#21344a'; ctx.fill();
      ctx.fillStyle = cntOf(data) > 0 ? '#f0c766' : '#9bb1c9';
      ctx.fillText(tag, x + w - tw - 5, y + h - 18);
    }
  } else if (data.type === 'file') {
    ctx.fillStyle = col; ctx.font = '8px ' + font; ctx.textAlign = 'left';
    ctx.fillText(rankTxt + 'FILE · ' + (data.lang || ''), x + pad, y + 16);
    ctx.fillStyle = '#eaf3ff'; ctx.font = '600 12px ' + font;
    wrapText(ctx, data.name, x + pad, y + 35, w - pad * 2 - 35, 14, 1);
    ctx.fillStyle = col; ctx.font = '700 12px ' + font; ctx.textAlign = 'right';
    ctx.fillText(String(Math.round(score)), x + w - 10, y + 19);
    ctx.textAlign = 'left';
    ctx.fillStyle = '#8ca2b8'; ctx.font = '9px ' + font;
    wrapText(ctx, data.lines + ' ' + T.lines + ' · ⚠' + cntOf(data), x + pad, y + 51, w - pad * 2, 11, 1);
    meterBar(x + pad, y + h - 10, w - pad * 2, score, col, pulse);
  } else {
    ctx.fillStyle = col; ctx.font = '8px ' + font; ctx.textAlign = 'left';
    ctx.fillText(rankTxt + typeLabel(data.type).toUpperCase() + ' · ' + (data.kind || ''), x + pad, y + 16);
    ctx.fillStyle = '#eaf3ff'; ctx.font = '600 12px ' + font;
    wrapText(ctx, data.name, x + pad, y + 35, w - pad * 2 - 35, 14, 1);
    ctx.fillStyle = col; ctx.font = '700 12px ' + font; ctx.textAlign = 'right';
    ctx.fillText(String(Math.round(score)), x + w - 10, y + 19);
    ctx.textAlign = 'left';
    ctx.fillStyle = '#8ca2b8'; ctx.font = '9px ' + font;
    wrapText(ctx, 'L' + data.line + ' · ⚠' + cntOf(data), x + pad, y + 51, w - pad * 2, 11, 1);
    meterBar(x + pad, y + h - 10, w - pad * 2, score, col, pulse);
  }
  if (data.cov < 75) {
    ctx.fillStyle = '#ffc857';
    ctx.beginPath(); ctx.arc(x + w - 11, y + h - 12, 3 + (breathEnabled ? pulse * 0.5 : 0), 0, 6.2832); ctx.fill();
  }
  // 选中/悬停的呼吸环改为「框体内描边」：外圈光环已按验收退役
  if (isSelected || isHover) {
    ctx.globalAlpha = dimA * (0.35 + pulse * 0.3);
    ctx.strokeStyle = col; ctx.lineWidth = 1;
    roundedRect(ctx, x + 2.5, y + 2.5, w - 5, h - 5, 8); ctx.stroke();
  }
  ctx.globalAlpha = 1;
}
function meterBar(x, y, w, score, col, pulse) {
  ctx.fillStyle = '#26384c';
  roundedRect(ctx, x, y, w, 3, 2); ctx.fill();
  roundedRect(ctx, x, y, Math.max(1, w * score / 100), 3, 2);
  ctx.fillStyle = col;
  ctx.fill();
}
function drawLayerBands() {
  for (var i = 0; i < layerBands.length; i++) {
    var b = layerBands[i];
    ctx.globalAlpha = 1;
    ctx.fillStyle = i % 2 === 0 ? 'rgba(26,43,63,.16)' : 'rgba(17,29,45,.10)';
    roundedRect(ctx, 18, b.y, worldWidth - 36, b.h, 12); ctx.fill();
    ctx.strokeStyle = 'rgba(83,119,151,.17)'; ctx.lineWidth = 1;
    ctx.setLineDash([3, 8]);
    ctx.beginPath(); ctx.moveTo(31, b.y + b.h); ctx.lineTo(worldWidth - 31, b.y + b.h); ctx.stroke();
    ctx.setLineDash([]);
    ctx.font = '9px ' + MONO; ctx.fillStyle = '#6f879f'; ctx.textAlign = 'left';
    ctx.fillText(b.label, 35, b.y + 15);
  }
}
function draw() {
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.fillStyle = '#0a1017';
  ctx.fillRect(0, 0, cssW, cssH);
  drawAtmosphere();
  ctx.setTransform(dpr * zoom, 0, 0, dpr * zoom, dpr * panX, dpr * panY);
  drawLayerBands();
  worldEdges.forEach(function (e, i) { drawEdge(e, i); });
  worldNodes.forEach(function (n, i) { drawNode(n, i); });
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  drawMini();
}
function drawMini() {
  var w = mini.clientWidth, h = mini.clientHeight;
  mctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  mctx.fillStyle = '#0b131c'; mctx.fillRect(0, 0, w, h);
  if (!worldNodes.length) { return; }
  var minX = 1e18, maxX = -1e18, minY = 1e18, maxY = -1e18;
  worldNodes.forEach(function (n) {
    if (n.x < minX) { minX = n.x; } if (n.x + n.w > maxX) { maxX = n.x + n.w; }
    if (n.y < minY) { minY = n.y; } if (n.y + n.h > maxY) { maxY = n.y + n.h; }
  });
  var pad = 10;
  var scale = Math.min((w - pad * 2) / Math.max(1, maxX - minX), (h - pad * 2) / Math.max(1, maxY - minY));
  var ox = (w - (maxX - minX) * scale) / 2 - minX * scale;
  var oy = (h - (maxY - minY) * scale) / 2 - minY * scale;
  mctx.strokeStyle = '#2b3c4a'; mctx.lineWidth = 0.5;
  worldEdges.forEach(function (e) {
    if (!e.route || !e.route.points) { return; }
    mctx.beginPath();
    e.route.points.forEach(function (p, i) {
      var x = p.x * scale + ox, y = p.y * scale + oy;
      if (i === 0) { mctx.moveTo(x, y); } else { mctx.lineTo(x, y); }
    });
    mctx.stroke();
  });
  worldNodes.forEach(function (n) {
    mctx.fillStyle = confidenceColor(n.data.confidence);
    mctx.globalAlpha = n.data.hidden ? 0.2 : 0.9;
    mctx.fillRect(n.x * scale + ox, n.y * scale + oy, Math.max(2, n.w * scale), Math.max(2, n.h * scale));
  });
  mctx.globalAlpha = 1;
  var vx = (-panX / zoom) * scale + ox, vy = (-panY / zoom) * scale + oy;
  var vw = (cssW / zoom) * scale, vh = (cssH / zoom) * scale;
  mctx.strokeStyle = '#e1eef9'; mctx.lineWidth = 1;
  mctx.strokeRect(vx, vy, vw, vh);
}
function animateFrame(timestamp) {
  if (!breathEnabled || document.hidden) { animationRequest = 0; return; }
  if (timestamp - lastAnimationFrame >= 1000 / 30) {
    animationTime = timestamp / 1000;
    draw();
    lastAnimationFrame = timestamp;
  }
  animationRequest = requestAnimationFrame(animateFrame);
}
function startAnimation() { if (breathEnabled && !document.hidden && !animationRequest) { animationRequest = requestAnimationFrame(animateFrame); } }
function setBreathEnabled(value) {
  breathEnabled = !!value;
  var btn = $('#breathToggle');
  btn.classList.toggle('active', breathEnabled);
  btn.setAttribute('aria-pressed', String(breathEnabled));
  $('#lblBreath').textContent = breathEnabled ? T.breathOn : T.breathOff;
  if (breathEnabled) { startAnimation(); } else { if (animationRequest) { cancelAnimationFrame(animationRequest); animationRequest = 0; } draw(); }
  toast(breathEnabled ? T.toastBreathOn : T.toastBreathOff);
}
function graphBounds() {
  var minX = 1e18, maxX = -1e18, minY = 1e18, maxY = -1e18;
  worldNodes.forEach(function (n) {
    if (n.x < minX) { minX = n.x; } if (n.x + n.w > maxX) { maxX = n.x + n.w; }
    if (n.y < minY) { minY = n.y; } if (n.y + n.h > maxY) { maxY = n.y + n.h; }
  });
  worldEdges.forEach(function (e) {
    (e.route && e.route.points || []).forEach(function (p) {
      if (p.x < minX) { minX = p.x; } if (p.x > maxX) { maxX = p.x; }
      if (p.y < minY) { minY = p.y; } if (p.y > maxY) { maxY = p.y; }
    });
  });
  if (!worldNodes.length) { return { minX: 0, maxX: cssW, minY: 0, maxY: cssH }; }
  return { minX: minX, maxX: maxX, minY: minY, maxY: maxY };
}
function fitView() {
  if (!worldNodes.length) { return; }
  var b = graphBounds();
  var pad = 36;
  var w = Math.max(1, b.maxX - b.minX), h = Math.max(1, b.maxY - b.minY);
  zoom = Math.min(1.16, (cssW - pad * 2) / w, (cssH - pad * 2) / h);
  zoom = Math.max(0.22, zoom);
  panX = (cssW - w * zoom) / 2 - b.minX * zoom;
  panY = (cssH - h * zoom) / 2 - b.minY * zoom;
  hasFit = true;
  draw();
}
function nodeAt(sx, sy) {
  var x = (sx - panX) / zoom, y = (sy - panY) / zoom;
  for (var i = worldNodes.length - 1; i >= 0; i--) {
    var n = worldNodes[i];
    if (x >= n.x && x <= n.x + n.w && y >= n.y && y <= n.y + n.h) { return n; }
  }
  return null;
}
function pointerPos(ev) { var r = canvas.getBoundingClientRect(); return { x: ev.clientX - r.left, y: ev.clientY - r.top }; }
var clickStart = null, lastClickTime = 0, lastClickedId = null;
canvas.addEventListener('pointerdown', function (ev) {
  var p = pointerPos(ev), n = nodeAt(p.x, p.y);
  canvas.setPointerCapture(ev.pointerId);
  clickStart = { x: p.x, y: p.y, node: n, time: Date.now() };
  lastPointer = p;
  if (n) { dragging = { id: n.id, bandIndex: n.layerIndex, offsetX: (p.x - panX) / zoom - n.x, offsetY: (p.y - panY) / zoom - n.y, moved: false }; }
  else { panning = true; }
});
canvas.addEventListener('pointermove', function (ev) {
  var p = pointerPos(ev);
  if (dragging && clickStart) {
    if (Math.sqrt((p.x - clickStart.x) * (p.x - clickStart.x) + (p.y - clickStart.y) * (p.y - clickStart.y)) > 3) { dragging.moved = true; }
    if (dragging.moved) {
      worldNodes.forEach(function (n) {
        if (n.id === dragging.id) { n.x = (p.x - panX) / zoom - dragging.offsetX; n.y = (p.y - panY) / zoom - dragging.offsetY; }
      });
      routeWorldEdges(true); draw();
    }
  } else if (panning && lastPointer) {
    panX += p.x - lastPointer.x; panY += p.y - lastPointer.y; draw();
  } else {
    var n = nodeAt(p.x, p.y);
    if (n !== hoverNode) { hoverNode = n; showHover(n, p); draw(); }
    else if (n) { moveHover(p); }
  }
  lastPointer = p;
});
canvas.addEventListener('pointerup', function (ev) {
  var p = pointerPos(ev);
  if (dragging && dragging.moved) {
    // 拖拽可能把卡片压到邻卡上：松手时把同带的卡片碰撞推开后重路由
    var band = layerBands[dragging.bandIndex];
    if (band) {
      settleScatterLayer(worldNodes.filter(function (n) { return n.layerIndex === dragging.bandIndex; }),
        56, worldWidth - 56, band.y + 32, band.y + band.h - 10);
    }
    routeWorldEdges(false); draw();
  }
  if (dragging && !dragging.moved && clickStart && clickStart.node) {
    var n = clickStart.node;
    var now = Date.now();
    if (n.id === lastClickedId && now - lastClickTime < 360) { handleDoubleClick(n); lastClickTime = 0; lastClickedId = null; }
    else { handleNodeClick(n); lastClickTime = now; lastClickedId = n.id; }
  }
  dragging = null; panning = false; clickStart = null; lastPointer = p;
});
canvas.addEventListener('pointerleave', function () {
  if (!dragging && !panning) { hoverNode = null; $('#hoverCard').style.display = 'none'; draw(); }
});
canvas.addEventListener('wheel', function (ev) {
  ev.preventDefault();
  var p = pointerPos(ev), before = zoom;
  var factor = ev.deltaY < 0 ? 1.1 : 0.91;
  zoom = Math.max(0.35, Math.min(2.4, zoom * factor));
  panX = p.x - (p.x - panX) * (zoom / before);
  panY = p.y - (p.y - panY) * (zoom / before);
  draw();
}, { passive: false });
mini.addEventListener('click', function (ev) {
  var r = mini.getBoundingClientRect();
  var x = ev.clientX - r.left, y = ev.clientY - r.top;
  var w = mini.clientWidth, h = mini.clientHeight;
  if (!worldNodes.length) { return; }
  var b = graphBounds();
  var pad = 10;
  var sc = Math.min((w - pad * 2) / Math.max(1, b.maxX - b.minX), (h - pad * 2) / Math.max(1, b.maxY - b.minY));
  var ox = (w - (b.maxX - b.minX) * sc) / 2 - b.minX * sc;
  var oy = (h - (b.maxY - b.minY) * sc) / 2 - b.minY * sc;
  var wx = (x - ox) / sc, wy = (y - oy) / sc;
  panX = cssW / 2 - wx * zoom; panY = cssH / 2 - wy * zoom;
  draw();
});
function showHover(n, p) {
  var h = $('#hoverCard');
  if (!n) { h.style.display = 'none'; return; }
  $('#hoverTitle').textContent = n.data.name;
  $('#hoverSub').textContent = typeLabel(n.data.type) + ' · ' + (n.data.path || n.data.file || n.data.loc || n.data.id);
  $('#hoverScore').textContent = Math.round(n.data.confidence) + '/100';
  $('#hoverScore').style.color = confidenceColor(n.data.confidence);
  $('#hoverFind').textContent = '⚠' + cntOf(n.data) + ' · −' + (n.data.penalty || 0);
  h.style.display = 'block';
  moveHover(p);
}
function moveHover(p) {
  var h = $('#hoverCard');
  if (h.style.display === 'none') { return; }
  var x = p.x + 14, y = p.y + 15;
  if (x + 255 > cssW) { x = p.x - 240; }
  if (y + 105 > cssH) { y = p.y - 110; }
  h.style.left = Math.max(4, x) + 'px';
  h.style.top = Math.max(4, y) + 'px';
}
function handleNodeClick(n) {
  selectedId = n.data.id;
  renderSidebar();
  draw();
}
function handleDoubleClick(n) {
  var item = n.data;
  if (item.children && item.children.length) {
    enterScope(item.id);
    toast(T.toastDrill + ' ' + item.name);
  } else {
    selectedId = item.id;
    activeTab = 'relations';
    updateTabs(); renderSidebar();
  }
}
function enterScope(id) {
  if (!NODES[id]) { return; }
  scopeId = id; selectedId = id;
  panX = 0; panY = 0; zoom = 1; hasFit = false;
  activeTab = 'overview';
  updateTabs();
  layoutGraph(); fitView(); updateBreadcrumbs(); renderSidebar();
}
function updateBreadcrumbs() {
  var el = $('#breadcrumbs');
  el.innerHTML = '';
  var chain = [];
  var cur = NODES[scopeId];
  while (cur) { chain.unshift(cur); cur = cur.parent ? NODES[cur.parent] : null; }
  chain.forEach(function (n, i) {
    if (i) { var a = document.createElement('span'); a.className = 'arr'; a.textContent = '›'; el.appendChild(a); }
    var b = document.createElement('button');
    b.textContent = n.id === 'project' ? (D.project || 'project') : n.name;
    b.className = i === chain.length - 1 ? 'current' : '';
    b.onclick = function () { enterScope(n.id); };
    el.appendChild(b);
  });
  $('#currentPath').textContent = '/ ' + chain.map(function (n) { return n.id === 'project' ? (D.project || 'project') : n.name; }).join(' / ');
}
function jumpToNode(id) {
  if (!NODES[id]) { return; }
  var target = NODES[id].parent || 'project';
  scopeId = target; selectedId = id;
  panX = 0; panY = 0; zoom = 1; hasFit = false;
  activeTab = 'overview';
  updateTabs(); layoutGraph(); fitView(); updateBreadcrumbs(); renderSidebar();
  toast(T.toastLocate + ': ' + NODES[id].name);
}
// ── 侧栏（六 tab）──
var activeTab = 'overview';
function updateTabs() {
  document.querySelectorAll('.tab-btn').forEach(function (b) { b.classList.toggle('active', b.getAttribute('data-tab') === activeTab); });
}
function confidenceBand(score) { return score < 60 ? (PAL_LO) : score < 80 ? (PAL_MID) : (PAL_HI); }
var PAL_LO = '低置信', PAL_MID = '中置信', PAL_HI = '高置信';
function scoreCard(n) {
  var s = Math.round(n.confidence), c = confidenceColor(s), band = confidenceBand(s);
  var label = typeLabel(n.type) + (en0() ? ' confidence' : '综合置信度');
  return '<div class="confidence-card"><div class="confidence-top"><div><div class="confidence-label">' + esc(label) + '</div>'
    + '<div class="confidence-value" style="color:' + c + '">' + s + '<small> / 100</small></div></div>'
    + '<span class="conf-state" style="color:' + c + ';border-color:' + c + '55;background:' + c + '12">' + esc(band) + '</span></div>'
    + '<div class="meter"><span style="width:' + s + '%;background:' + c + '"></span></div>'
    + '<div class="meter-labels"><span>⚠' + cntOf(n) + ' ' + T.findings + '</span><span>' + T.penalty + ' −' + (n.penalty || 0) + '</span></div></div>';
}
function section(title, meta) {
  return '<div class="section-head"><div class="section-title">' + title + '</div>' + (meta ? '<div class="section-meta">' + esc(meta) + '</div>' : '') + '</div>';
}
function metric(label, val, sub, cl) {
  return '<div class="metric-box"><div class="label">' + esc(label) + '</div><strong class="' + (cl || '') + '">' + esc(String(val)) + '</strong><small>' + esc(sub) + '</small></div>';
}
var DIM_KEYS = ['variable', 'function', 'type', 'pointer', 'concurrency', 'structure'];
function dimCounts(n) {
  var counts = {}; var total = 0;
  DIM_KEYS.forEach(function (k) { counts[k] = 0; });
  function addF(f) { var d = f.dim || 'structure'; if (!(d in counts)) { d = 'structure'; } counts[d] += 1; total += 1; }
  if (n.type === 'module') {
    (CONF.findings || []).forEach(function (f) { if (FM[f.file] === n.mid) { addF(f); } });
  } else if (n.type === 'file') {
    (BY_FILE[n.path] || []).forEach(addF);
  } else if (n.type === 'project') {
    (CONF.findings || []).forEach(addF);
  } else { (n.findings || []).forEach(addF); }
  return { counts: counts, total: total };
}
function scoreBars(n) {
  var dc = dimCounts(n);
  return '<div class="bar-list">' + DIM_KEYS.map(function (k) {
    var v = dc.counts[k];
    var pct = dc.total ? Math.round(v / dc.total * 100) : 0;
    var col = v ? confidenceColor(Math.max(20, 100 - pct)) : '#3b4a57';
    return '<div class="bar-row"><label>' + esc(T.dims[k]) + '</label><div class="bar-track"><span style="width:' + pct + '%;background:' + col + '"></span></div><strong style="color:' + (v ? col : '#71869a') + '">' + v + '</strong></div>';
  }).join('') + '</div>';
}
function childRows(n) {
  var ids = (n.children || []).slice(0, 30);
  if (!ids.length) { return '<div class="empty"><strong>' + esc(T.noChild) + '</strong></div>'; }
  return '<div class="list">' + ids.map(function (id) {
    var c = NODES[id];
    return '<div class="list-row" data-jump="' + esc(id) + '"><i class="relation-dot" style="background:' + confidenceColor(c.confidence) + '"></i>'
      + '<div class="list-main"><strong>' + esc(c.name) + '</strong><small>' + esc(typeLabel(c.type)) + ' · ⚠' + cntOf(c) + '</small></div>'
      + '<div class="list-score" style="color:' + confidenceColor(c.confidence) + '">' + Math.round(c.confidence) + '</div></div>';
  }).join('') + '</div>' + ((n.children || []).length > 30 ? '<div class="note" style="margin-top:7px">+ ' + ((n.children || []).length - 30) + '</div>' : '');
}
function nodeRelations(id) {
  var out = [];
  worldEdges.forEach(function (e) {
    if (e.s === id || e.t === id) { out.push({ other: e.s === id ? e.t : e.s, direction: e.s === id ? 'out' : 'in', type: e.type, w: e.w, count: e.count }); }
  });
  if (scopeId === id || out.length) { return out; }
  // 当前图层没有该节点的边（如 project 总览下的模块内边）——全数据集兜底
  if (id.indexOf('m:') === 0) {
    ME.forEach(function (e) {
      var ea = 'm:' + e.from; var eb = 'm:' + e.to;
      if (ea === id || eb === id) {
        out.push({ other: ea === id ? eb : ea, direction: ea === id ? 'out' : 'in', type: 'call', w: e.w || 1, count: 1 });
      }
    });
  } else if (id.indexOf('p:') === 0) {
    AE.forEach(function (e) {
      if ('p:' + e.from === id || 'p:' + e.to === id) {
        out.push({ other: ('p:' + e.from) === id ? 'p:' + e.to : 'p:' + e.from, direction: ('p:' + e.from) === id ? 'out' : 'in', type: 'call', w: e.w || 1, count: 1 });
      }
    });
  } else {
    (OUT_EDGE[id] || []).forEach(function (o) { out.push({ other: o[0], direction: 'out', type: o[2] === 'guessed' ? 'guessed' : 'call', w: o[1] || 1, count: 1 }); });
  }
  return out;
}
function relRows(rs, limit) {
  if (!rs.length) { return '<div class="empty"><strong>' + esc(T.noRel) + '</strong></div>'; }
  var shown = rs.slice(0, limit || 12);
  return '<div class="list">' + shown.map(function (e) {
    var other = NODES[e.other];
    var rel = REL[e.type] || { label: e.type, color: '#8496a8' };
    return '<div class="list-row" data-jump="' + esc(e.other) + '"><i class="relation-dot" style="background:' + rel.color + '"></i>'
      + '<div class="list-main"><strong>' + esc(other ? other.name : e.other) + '</strong>'
      + '<small>' + (e.direction === 'out' ? T.outLbl + ' →' : '← ' + T.inLbl) + ' · ' + esc(rel.label) + ' · ' + T.strength + ' ' + Math.round(strengthOf(e.w) * 100) + '%</small></div>'
      + '<div class="list-score" style="color:' + confidenceColor(other ? other.confidence : 60) + '">' + (other ? Math.round(other.confidence) : '–') + '</div></div>';
  }).join('') + '</div>';
}
function evidenceRows(n, limit) {
  var list;
  if (n.type === 'project') { list = CONF.findings || []; }
  else if (n.type === 'module') { list = (CONF.findings || []).filter(function (f) { return FM[f.file] === n.mid; }); }
  else if (n.type === 'file') { list = BY_FILE[n.path] || []; }
  else { list = n.findings || []; }
  if (!list.length) { return '<div class="empty"><strong>' + esc(T.eviEmpty) + '</strong></div>'; }
  var shown = list.slice(0, limit || 40);
  return shown.map(function (f) {
    var tierCol = f.weight >= 8 ? '#fa818b' : (f.weight >= 4 ? '#f0c35b' : '#6bdfaa');
    return '<div class="evidence-item"><div class="evi-icon">' + esc(T.dims[f.dim || 'structure'].slice(0, 1)) + '</div>'
      + '<div class="evi-main"><strong>' + esc(f.label || f.kind || '') + ' · ' + esc(baseName(f.file)) + ' L' + f.line + '</strong>'
      + '<p>' + esc(f.evidence || '') + '</p></div>'
      + '<div class="evi-score ' + (f.weight >= 8 ? 'low' : (f.weight >= 4 ? 'mid' : 'good')) + '" style="color:' + tierCol + '">w' + f.weight + '</div></div>';
  }).join('') + (list.length > shown.length ? '<div class="note" style="margin-top:8px">' + esc(T.eviCap.split('#N').join(String(list.length))) + '</div>' : '');
}
function integrityNotes() {
  var notes = [];
  if (D.confMissing) { notes.push(T.confMissingNote || 'no confidence data'); }
  if (!CONF.astUsed && CONF.astNote) { notes.push(CONF.astNote); }
  if (CONF.cappedTotal || CONF.cappedKind) { notes.push(T.capNote); }
  if (D.truncated) { notes.push(T.noteTrunc || 'file cap reached'); }
  if (D.oversizeSkipped > 0) { notes.push(D.oversizeSkipped + (T.noteOver || ' oversize excluded')); }
  if (D.depthOmitted > 0) { notes.push(D.depthOmitted + (T.noteDepth || ' omitted by depth')); }
  if (D.unreadableDirs && D.unreadableDirs.length) {
    notes.push((D.unreadableDirsTruncated ? '≥' : '') + D.unreadableDirs.length + (T.noteUnread || ' dirs unreadable'));
  }
  if (!notes.length) { return ''; }
  return '<div class="panel-section">' + section(esc(T.integrity), 'DISCLOSURE') + '<div class="note">' + notes.map(esc).join('<br>') + '</div></div>';
}
function symbolTable(n) {
  var syms;
  if (n.type === 'file') { syms = (n.children || []).map(function (id) { return NODES[id]; }); }
  else if (n.type === 'module') {
    syms = [];
    (n.children || []).forEach(function (fid) { (NODES[fid].children || []).forEach(function (sid) { syms.push(NODES[sid]); }); });
  } else if (n.type === 'project') { syms = FG.functions.map(function (f) { return NODES[f.id]; }).filter(Boolean); }
  else { syms = [n]; }
  var capN = 300;
  if (!syms.length) { return '<div class="empty"><strong>' + esc(T.symEmpty) + '</strong></div>'; }
  var shown = syms.slice(0, capN);
  return '<table class="mini-table"><thead><tr><th>' + esc(T.tabSym) + '</th><th>' + esc(T.typeCol) + '</th><th>' + esc(T.tabConf) + '</th></tr></thead><tbody>'
    + shown.map(function (s) {
      return '<tr data-jump="' + esc(s.id) + '" style="cursor:pointer"><td>' + esc(s.name) + '</td><td>' + esc(typeLabel(s.type)) + '</td>'
        + '<td class="score-cell" style="color:' + confidenceColor(s.confidence) + '">' + Math.round(s.confidence) + '</td></tr>';
    }).join('') + '</tbody></table>'
    + (syms.length > capN ? '<div class="note" style="margin-top:8px">' + esc(T.symCap.split('#N').join(String(syms.length))) + '</div>' : '');
}
function moduleSection() {
  var mods = GM.map(function (m) { return NODES['m:' + m.id]; }).sort(function (a, b) { return b.confidence - a.confidence; });
  return '<div class="panel-section">' + section(esc(T.bandModules), 'CONFIDENCE') + '<div class="bar-list">'
    + mods.map(function (m) {
      return '<div class="bar-row" style="grid-template-columns:95px 1fr 30px;cursor:pointer" data-jump="' + esc(m.id) + '"><label>' + esc(m.name) + '</label>'
        + '<div class="bar-track"><span style="width:' + Math.round(m.confidence) + '%;background:' + confidenceColor(m.confidence) + '"></span></div>'
        + '<strong style="color:' + confidenceColor(m.confidence) + '">' + Math.round(m.confidence) + '</strong></div>';
    }).join('') + '</div></div>'
    + '<div class="panel-section">' + section(esc(T.tabMod), 'FILES · SYMBOLS · LINES') + '<table class="mini-table"><thead><tr><th>' + esc(T.bandModules) + '</th><th>' + esc(T.tabConf) + '</th><th>⚠</th><th>' + esc(T.scale) + '</th></tr></thead><tbody>'
    + mods.map(function (m) {
      return '<tr data-jump="' + esc(m.id) + '" style="cursor:pointer"><td>' + esc(m.name) + '</td>'
        + '<td class="score-cell" style="color:' + confidenceColor(m.confidence) + '">' + Math.round(m.confidence) + '</td>'
        + '<td>' + cntOf(m) + '</td><td>' + m.files + ' · ' + m.symbols + ' · ' + m.lines + '</td></tr>';
    }).join('') + '</tbody></table></div>'
    + '<div class="panel-section">' + section('AGGREGATION', 'SINGLE SOURCE') + '<div class="note">' + esc(T.modAgg) + '</div></div>';
}
function formulaSection(n) {
  var denom = n.type === 'module' ? Math.max(1, n.files) : (n.type === 'project' ? Math.max(1, FILES.length) : 1);
  return '<div class="panel-section">' + section(esc(T.secFormula), 'CONF-SCALE 20') + '<div class="stat-row"><span>penalty</span><strong>' + (n.penalty || 0) + '</strong></div>'
    + '<div class="stat-row"><span>n</span><strong>' + denom + '</strong></div>'
    + '<div class="stat-row"><span>density</span><strong>' + ((n.penalty || 0) / denom).toFixed(2) + '</strong></div>'
    + '<div class="stat-row"><span>C = floor(100·20/(20+density))</span><strong style="color:' + confidenceColor(n.confidence) + '">' + Math.round(n.confidence) + '</strong></div></div>';
}
function renderSidebar() {
  var n = NODES[selectedId] || NODES[scopeId] || NODES.project;
  $('#sideTitle').textContent = n.type === 'project' ? (en0() ? 'Confidence report' : '置信度分析报告') : n.name + ' · ' + (en0() ? 'confidence' : '置信度报告');
  $('#sideSub').textContent = String(n.type).toUpperCase() + ' · ' + (n.path || n.file || n.loc || n.id);
  var rs = nodeRelations(n.id);
  var body = $('#sideBody');
  var html = '';
  if (activeTab === 'overview') {
    html += '<div class="panel-section">' + section('SCORE', n.id) + scoreCard(n) + '</div>';
    html += '<div class="panel-section">' + section('SIGNALS', 'METRICS') + '<div class="metric-grid">'
      + metric(T.findings, cntOf(n), T.penalty + ' −' + (n.penalty || 0), cntOf(n) > 0 ? 'yellow' : 'green')
      + metric(T.degree, rs.length, T.impact + ' ' + (n.impact || 0))
      + (n.type === 'module' ? metric(T.scale, n.files + ' · ' + n.symbols, n.lines + ' ' + T.lines)
        : (n.type === 'file' ? metric(T.scale, n.lines + ' ' + T.lines, (n.children || []).length + ' ' + T.syms)
          : metric(T.scale, FILES.length + ' ' + T.files, FG.functions.length + ' ' + T.syms)))
      + metric(T.clean, n.cov + '%', T.clean) + '</div></div>';
    html += '<div class="panel-section">' + section(esc(T.dimTitle), '0–N') + scoreBars(n) + '</div>';
    html += integrityNotes();
    html += '<div class="panel-section">' + section(esc(T.children), ((n.children || []).length) + ' ITEMS') + childRows(n) + '</div>';
    if ((n.children || []).length) {
      html += '<div class="side-actions"><button class="primary-btn" id="drillBtn">' + esc(T.toastDrill) + ' ↘</button></div>';
    }
    html += '<div class="panel-section">' + section(esc(T.directRel), 'INDEXED EDGES') + relRows(rs, 6)
      + (rs.length > 6 ? '<button class="ghost-btn" data-switch-tab="relations" style="width:100%;margin-top:7px">' + esc(T.allRel + ' ' + rs.length) + '</button>' : '') + '</div>';
  } else if (activeTab === 'confidence') {
    html += '<div class="panel-section">' + section('EXPLAINABLE SCORE', 'FORMULA') + scoreCard(n) + '</div>';
    html += formulaSection(n);
    html += '<div class="panel-section">' + section(esc(T.secDims), '0–N') + scoreBars(n) + '</div>';
    html += '<div class="panel-section">' + section('INTERPRETATION', 'NOT AN AUDIT') + '<div class="note">' + esc(T.lexNote) + '</div></div>';
  } else if (activeTab === 'relations') {
    var outs = rs.filter(function (e) { return e.direction === 'out'; });
    var ins = rs.filter(function (e) { return e.direction === 'in'; });
    html += '<div class="panel-section">' + section('STATS', rs.length + ' EDGES') + '<div class="metric-grid">'
      + metric(T.outLbl, outs.length, 'SOURCE') + metric(T.inLbl, ins.length, 'TARGET') + '</div></div>';
    html += '<div class="panel-section">' + section(esc(T.directRel), 'CLICK TO INSPECT') + relRows(rs, 100) + '</div>';
    html += '<div class="panel-section">' + section('EDGE SEMANTICS', 'LEGEND') + '<div class="pill-row">'
      + Object.keys(REL).map(function (k) { return '<span class="pill"><span style="color:' + REL[k].color + '">━</span> ' + esc(REL[k].label) + '</span>'; }).join('') + '</div></div>';
  } else if (activeTab === 'evidence') {
    html += '<div class="panel-section">' + section('PROVENANCE', 'FINDINGS') + scoreCard(n) + '</div>';
    html += '<div class="panel-section">' + section('FINDING EVIDENCE', 'ENGINE EXTRACTED') + evidenceRows(n, 40) + '</div>';
    html += integrityNotes();
  } else if (activeTab === 'modules') {
    html += moduleSection();
  } else if (activeTab === 'symbols') {
    html += '<div class="panel-section">' + section(esc(T.tabSym), 'SYMBOL INDEX') + symbolTable(n) + '</div>';
  }
  body.innerHTML = html;
  body.querySelectorAll('[data-jump]').forEach(function (el2) {
    el2.addEventListener('click', function () { jumpToNode(el2.getAttribute('data-jump')); });
  });
  body.querySelectorAll('[data-switch-tab]').forEach(function (el3) {
    el3.addEventListener('click', function () { activeTab = el3.getAttribute('data-switch-tab'); updateTabs(); renderSidebar(); });
  });
  var drill = $('#drillBtn');
  if (drill) { drill.onclick = function () { if ((n.children || []).length) { enterScope(n.id); } }; }
}
function en0() { return !!D.en; }
function toast(msg) {
  var el = $('#toast');
  el.textContent = msg;
  el.classList.add('show');
  clearTimeout(toast.timer);
  toast.timer = setTimeout(function () { el.classList.remove('show'); }, 2100);
}
// ── 过滤器 / 控件 ──
(function () {
  var sel = $('#relationFilter');
  Object.keys(REL).forEach(function (k) {
    var o = document.createElement('option');
    o.value = k; o.textContent = REL[k].label;
    sel.appendChild(o);
  });
})();
$('#relationFilter').addEventListener('change', function (e) { relationType = e.target.value; layoutGraph(); });
$('#threshold').addEventListener('input', function (e) { threshold = Number(e.target.value); $('#thresholdValue').textContent = String(threshold); layoutGraph(); });
$('#fitBtn').onclick = function () { fitView(); };
$('#resetView').onclick = function () { zoom = 1; panX = 0; panY = 0; hasFit = false; layoutGraph(); fitView(); };
$('#breathToggle').onclick = function () { setBreathEnabled(!breathEnabled); };
document.addEventListener('visibilitychange', function () {
  if (document.hidden) { if (animationRequest) { cancelAnimationFrame(animationRequest); animationRequest = 0; } }
  else { startAnimation(); }
});
$('#pathBtn').onclick = function () {
  pathMode = !pathMode;
  $('#pathBtn').style.borderColor = pathMode ? '#4e9479' : '';
  $('#pathBtn').style.color = pathMode ? '#8ce7be' : '';
  draw();
  toast(pathMode ? T.toastPathOn : T.toastPathOff);
};
$('#clearSelection').onclick = function () { selectedId = scopeId; activeTab = 'overview'; updateTabs(); renderSidebar(); draw(); };
document.querySelectorAll('.tab-btn').forEach(function (b) {
  b.addEventListener('click', function () { activeTab = b.getAttribute('data-tab'); updateTabs(); renderSidebar(); });
});
$('#modelBtn').onclick = function () { $('#modalBackdrop').classList.add('show'); };
$('#closeModal').onclick = $('#closeModal2').onclick = function () { $('#modalBackdrop').classList.remove('show'); };
$('#modalBackdrop').addEventListener('click', function (e) { if (e.target.id === 'modalBackdrop') { e.currentTarget.classList.remove('show'); } });
document.addEventListener('keydown', function (ev) {
  if (ev.key === '/' && ev.target.tagName !== 'INPUT' && ev.target.tagName !== 'TEXTAREA') {
    ev.preventDefault();
    $('#searchInput').focus();
  }
  if (ev.key === 'Escape') { $('#searchResults').style.display = 'none'; $('#modalBackdrop').classList.remove('show'); }
  if (ev.key === '?' && ev.target.tagName !== 'INPUT') { $('#modalBackdrop').classList.add('show'); }
});
var searchInput = $('#searchInput'), searchResults = $('#searchResults');
function searchableList() {
  return Object.keys(NODES).filter(function (id) { return id !== 'project' && NODES[id].type !== 'boundary'; }).map(function (id) { return NODES[id]; });
}
searchInput.addEventListener('input', function () {
  var q = searchInput.value.trim().toLowerCase();
  if (!q) { searchResults.style.display = 'none'; return; }
  var res = searchableList().filter(function (n) {
    return n.name.toLowerCase().indexOf(q) >= 0 || String(n.path || n.file || '').toLowerCase().indexOf(q) >= 0;
  }).slice(0, 8);
  searchResults.innerHTML = res.length ? res.map(function (n) {
    return '<button data-find="' + esc(n.id) + '"><span>' + esc(n.name) + ' <small style="color:#6f8498">· ' + esc(typeLabel(n.type)) + '</small></span>'
      + '<span style="color:' + confidenceColor(n.confidence) + '">' + Math.round(n.confidence) + '</span></button>';
  }).join('') : '<button><span>' + esc(T.noMatch) + '</span><span>—</span></button>';
  searchResults.style.display = 'block';
  searchResults.querySelectorAll('[data-find]').forEach(function (b) {
    b.onclick = function () {
      var n = NODES[b.getAttribute('data-find')];
      searchInput.value = n.name;
      searchResults.style.display = 'none';
      jumpToNode(n.id);
    };
  });
});
searchInput.addEventListener('keydown', function (ev) {
  if (ev.key === 'Enter') {
    var first = searchResults.querySelector('[data-find]');
    if (first) { first.click(); }
  }
  if (ev.key === 'Escape') { searchResults.style.display = 'none'; }
});
document.addEventListener('click', function (ev) {
  if (!ev.target.closest('.search-position')) { searchResults.style.display = 'none'; }
});
// ── 双语：en 时以 T 表覆盖模板静态中文 ──
function applyTexts() {
  if (!en0()) { return; }
  $('#lblTopConf').textContent = T.topConf;
  $('#modelBtn').textContent = T.modelBtn;
  $('#lblRel').textContent = T.rel;
  $('#relationFilter').options[0].textContent = T.relAll;
  $('#lblTh').textContent = T.th;
  $('#lblMode').textContent = T.mode;
  $('#lblPath').textContent = T.path;
  $('#lblFit').textContent = T.fit;
  $('#lblBreath').textContent = T.breathOn;
  $('#lblLevel').textContent = T.level;
  $('#canvasMsg').textContent = T.msg;
  $('#lblHovConf').textContent = T.hovConf;
  $('#lblHovFind').textContent = T.hovFind;
  $('#lgLo').textContent = T.lgLo; $('#lgMid').textContent = T.lgMid; $('#lgHi').textContent = T.lgHi;
  $('#lgSrc').textContent = T.lgSrc;
  $('#lblHelp').textContent = T.help;
  $('#tabOverview').textContent = T.tabOv; $('#tabConfidence').textContent = T.tabConf;
  $('#tabRelations').textContent = T.tabRel; $('#tabEvidence').textContent = T.tabEvi;
  $('#tabModules').textContent = T.tabMod; $('#tabSymbols').textContent = T.tabSym;
  $('#freshTag').textContent = T.ready;
}
function resize() {
  var r = wrap.getBoundingClientRect();
  cssW = r.width; cssH = r.height;
  dpr = window.devicePixelRatio || 1;
  canvas.width = Math.round(cssW * dpr); canvas.height = Math.round(cssH * dpr);
  canvas.style.width = cssW + 'px'; canvas.style.height = cssH + 'px';
  mini.width = Math.round(mini.clientWidth * dpr); mini.height = Math.round(mini.clientHeight * dpr);
  layoutGraph();
  if (!hasFit) { fitView(); } else { draw(); }
}
function init() {
  var score = Math.round(CONF.score);
  $('#topScore').textContent = String(score);
  $('#topScoreMini').textContent = String(score);
  $('#topDonut').style.background = 'conic-gradient(' + confidenceColor(CONF.score) + ' 0 ' + score + '%,#25333d ' + score + '% 100%)';
  $('#projName').textContent = D.project || 'project';
  $('#projAvatar').textContent = String(D.project || 'MG').slice(0, 2).toUpperCase();
  var symTotal = FG.functions.length;
  $('#projMeta').textContent = FILES.length + ' ' + T.files + ' · ' + symTotal + ' ' + T.syms + ' · ' + (D.langSummary || '');
  var f = D.tierFiles || 0;
  var tierTxt;
  if (D.projectTier === 'layered') {
    tierTxt = f > D.compactMaxFiles ? T.tierLf.split('#F').join(String(f)).split('#M').join(String(D.compactMaxFiles))
      : T.tierLs.split('#S').join(String(D.tierSymbols || 0)).split('#M').join(String(D.compactMaxSymbols));
  } else { tierTxt = T.tierC; }
  $('#tierChip').textContent = tierTxt;
  if (D.updateCount !== undefined && D.updateCount !== null) {
    $('#freshTag').textContent = '● INDEX v' + D.updateCount;
    $('#evalTag').textContent = T.evalAt + ' ' + (D.generatedAt || '');
  } else { $('#freshTag').textContent = T.tmp; }
  $('#footerNodes').textContent = symTotal + ' ' + T.indexed;
  // 模型弹窗：真实公式与限流披露
  $('#modalIntro').textContent = en0()
    ? 'The index is a lexical heuristic over the symbol graph. Combine the score with the disclosures; a missing AST pass is disclosed, never silently ignored.'
    : '该指数是符号图谱上的词法启发式估计，不是审计结论。请结合披露信息理解分数；AST 解析缺席时会显式披露，绝不静默忽略。';
  $('#modalFormula').textContent = 'C(n) = floor( 100 × ' + CONF_SCALE + ' / (' + CONF_SCALE + ' + penalty / n) )';
  $('#modalCaps').textContent = (CONF.cappedTotal || CONF.cappedKind) ? T.capNote : '';
  if (!CONF.astUsed && CONF.astNote) { $('#modalCaps').textContent += (CONF.astNote ? ' · ' : '') + CONF.astNote; }
  applyTexts();
  updateBreadcrumbs();
  resize();
  renderSidebar();
  $('#breathToggle').classList.toggle('active', breathEnabled);
  startAnimation();
}
var resizeTimer;
window.addEventListener('resize', function () {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(function () { hasFit = false; resize(); fitView(); }, 80);
});
init();
window.MoongitCodeGraph = {
  scene: D, nodes: NODES, version: 2,
  enterScope: enterScope,
  jumpTo: jumpToNode,
  select: function (id) { selectedId = id; renderSidebar(); draw(); }
};
"""
}
