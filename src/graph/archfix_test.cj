// graph/archfix_test.cj — 图谱修复单元的回归测试（R1–R10 出口侧 + R11 架构口径）。
//
// 【归属】graph_test.cj 属「图谱核心」单元，本文件不碰它；夹具 testRoot()/
// writeTree()/removeTree() 是同包包内函数，直接复用（隔离纪律见其文件头：
// 临时目录按 pid+时间戳命名、完整树删除、不碰 DEEPGIT_HOME）。
// R11（架构引用口径）与 src/graph/build.cj / model.cj / arch.cj 的
// archRefEdges 配套：引用边双口径的回归，见该 MARK 段注释。
//
// 【契约依赖】R3/R6 的 capped、unreadableDirs 字段由「图谱核心」单元按跨区域
// 契约 A/B 落地（ImpactResult.refFilesCapped/impactedCapped、
// CodeGraph.unreadableDirs）；本文件按契约消费，不重复定义。
package moongit.graph

import std.collection.*
import moongit.util.*
import std.unittest.*
import std.unittest.testmacro.*

// MARK: - R1：overviewJson 的 byLang/byKind 键序

/// R1 回归：byLang/byKind 原来直接迭代 HashMap 写进 JObj —— JObj 按插入序
/// 序列化，随机键序被固化进 JSON 契约（全包唯一未排序出口，M11 纪律）。
/// util 的 JObj 保持插入序，因此可直接断言键严格升序。
@Test
func testOverviewJsonLangAndKindKeysAreSorted(): Unit {
    let root = writeTree()
    try {
        let o = overviewJson(buildGraph(root))
        for (key in ["byLang", "byKind"]) {
            match (Json.getOr(o, key)) {
                case JObj(m) =>
                    // 前提：夹具至少 2 个键，否则「升序」恒真空转（不变量 18）
                    @Assert(m.size >= 2)
                    var prev = ""
                    var first = true
                    for ((k, _) in m) {
                        if (!first) {
                            @Assert(prev < k)
                        }
                        prev = k
                        first = false
                    }
                case _ => @Assert(false)
            }
        }
    } finally {
        removeTree(root)
    }
}

// MARK: - R2：graph tree 的 --depth 在 text 与 json 出口同一口径

/// treeText 可见文件行计数：文件行是 `${名字}  (${lang}, ${行} 行, ${n} 符号)`，
/// 全树里「 行, 」这个片段只出现在文件行（目录行注记是「 行)」，符号行是
/// 「(L${行号})」，头部汇总也是「 行)」）。
func treeVisibleFileCount(tree: String): Int64 {
    return Int64(tree.split(" 行, ").size) - 1
}

/// R2 回归：同一 depth 下 fullGraphJson 的文件集必须与 treeText 的可见文件集
/// 相等。原实现 JSON 把 ≤0 当不截断、text 当截到第 1 层；正数也错位一层
/// （text 可见文件最大目录深度 = maxDepth-1）—— 同一个 flag 两个出口两个答案。
@Test
func testTreeDepthMatchesFullGraphJsonFileSet(): Unit {
    let root = writeTree()
    try {
        // 深度 2 与 3 的文件各一个：没有它们夹具最深只有 1，错位一层验不出来
        ensureDir("${root}/flow/inner")
        writeFileAtomic("${root}/flow/inner/deep.cj", """
package moongit.flow.inner

public func deepThing(): Int64 { return 1 }
""")
        ensureDir("${root}/flow/inner/deeper")
        writeFileAtomic("${root}/flow/inner/deeper/deep2.cj", """
package moongit.flow.inner.deeper

public func deeperThing(): Int64 { return 2 }
""")
        let g = buildGraph(root)
        @Assert(Int64(g.files.size) == 6)

        // 正数 depth：JSON 留的每个文件 text 都可见；可见行数与 JSON 文件数相等
        //（夹具文件名唯一 ⇒ 行数相等 + 单向包含 ⇒ 集合相等）
        for (d in [1, 2, 3]) {
            let j = fullGraphJson(g, d)
            let kept = Json.arrAt(j, "files")
            let tree = treeText(g, d)
            @Assert(treeVisibleFileCount(tree) == Int64(kept.size))
            for (f in kept) {
                let p = Json.strAt(f, "path", "")
                let lang = Json.strAt(f, "lang", "")
                @Assert(tree.contains("${lastSeg(p)}  (${lang}"))
            }
            if (d < 3) {
                @Assert(tree.contains("深度截断"))
            }
        }
        // depth=3 恰好看全（最深文件 dirDepth=3）：不该有截断披露
        @Assert(!treeText(g, 3).contains("深度截断"))

        // ≤0：两边都是全量（原 text 出口把 ≤0 当截到第 1 层）
        for (d in [0, -1]) {
            let j = fullGraphJson(g, d)
            @Assert(Int64(Json.arrAt(j, "files").size) == Int64(g.files.size))
            let tree = treeText(g, d)
            @Assert(treeVisibleFileCount(tree) == Int64(g.files.size))
            @Assert(!tree.contains("深度截断"))
        }
    } finally {
        removeTree(root)
    }
}

// MARK: - R3：影响面两个 200 上限的披露（契约B 出口侧）

/// R3 回归（恒发半边）：impactJson 必须恒发 refFilesCapped/impactedCapped ——
/// false 也发。缺键会被消费方读成「旧版本没有这个字段」（同 depth 的恒发纪律）。
@Test
func testImpactJsonAlwaysEmitsCappedKeys(): Unit {
    let root = writeTree()
    try {
        let g = buildGraph(root)
        match (impactOf(g, "Text")) {
            case Some(res) =>
                // 前提：小夹具远不到 200 —— 这条测的是「false 也发」，不是截断本身
                @Assert(Int64(res.refFiles.size) < IMPACT_MAX_FILES)
                let j = impactJson(res)
                @Assert(Json.has(j, "refFilesCapped"))
                @Assert(Json.has(j, "impactedCapped"))
                // fallback 故意取反：键缺失时这里必须红（恒发与值一起钉）
                @Assert(Json.boolAt(j, "refFilesCapped", true) == false)
                @Assert(Json.boolAt(j, "impactedCapped", true) == false)
                // 未截断时文本不得出现「已达上限」——披露只在真截断时出现
                @Assert(!impactText(res).contains("已达上限"))
            case None => @Assert(false)
        }
    } finally {
        removeTree(root)
    }
}

/// R3 回归（截断半边）：真实撞上 IMPACT_MAX_FILES=200 —— 201 个引用 Text 的
/// 文件让 refFiles 在第 200 个 break（契约B 置 refFilesCapped），每个引用文件
/// 各带一个声明符号让 impacted 也撞上限。不注入小上限：走真实 collect 路径。
/// 引用形态抄 writeTree 已验证的 `t: Text` 类型标注（flow/update.cj → util 的
/// 引用边就是这么形成的）。
@Test
func testImpactCapIsDisclosedWhenLimitHit(): Unit {
    let root = writeTree()
    try {
        ensureDir("${root}/bulk")
        var i: Int64 = 0
        while (i <= IMPACT_MAX_FILES) {
            writeFileAtomic("${root}/bulk/ref${i}.cj", """
package moongit.bulk

public func fn${i}(t: Text): Int64 { return 1 }
""")
            i += 1
        }
        let g = buildGraph(root)
        match (impactOf(g, "Text")) {
            case Some(res) =>
                // 前提：真撞上限了（否则下面的断言全在测「没触发」）
                @Assert(Int64(res.refFiles.size) == IMPACT_MAX_FILES)
                @Assert(res.refFilesCapped)
                @Assert(Int64(res.impactedSymbols.size) == IMPACT_MAX_FILES)
                @Assert(res.impactedCapped)
                // JSON 恒发且如实为 true
                let j = impactJson(res)
                @Assert(Json.boolAt(j, "refFilesCapped", false))
                @Assert(Json.boolAt(j, "impactedCapped", false))
                // 文本出口两段都要披露
                let text = impactText(res)
                @Assert(text.contains("已达上限 ${IMPACT_MAX_FILES}"))
            case None => @Assert(false)
        }
    } finally {
        removeTree(root)
    }
}

// MARK: - R4：arch 的截断披露要进 html 出口



/// R4 回归（html 半边）：驱动 JS 必须真的消费 DATA.truncated —— 键在数据里、
/// 页面从不读它 = 数据显示没算。两种语言都要有消费点（英文模式同一分支）。
@Test
func testArchHtmlJsConsumesTruncatedFlag(): Unit {
    let root = writeTree()
    try {
        let arch = buildArch(buildGraph(root))
        @Assert(archCanvasHtml(arch, false).contains("DATA.truncated"))
        @Assert(archCanvasHtml(arch, true).contains("DATA.truncated"))
        // 消费点是条件插入：警示条元素只应在命中时出现
        @Assert(archCanvasHtml(arch, false).contains("truncbar"))
    } finally {
        removeTree(root)
    }
}

// MARK: - R5：合并器不得丢 Layer-1 的字段

/// R5 回归：mergePatchConfidence 重建 entities 时只手挑 id/confidence/source/
/// relations 四键 —— Layer-1 补的 file/line/kind 全丢，uncertain 合并条目丢
/// context_ref，与文件头「算法层 entities：原样保留」的注释相反。
/// 走真实三层路径：diff → analyzePatchConfidence → patchConfidenceJson（Layer-1
/// 出口）→ mergePatchConfidence → mergedConfidenceJson；agent.json 是外部 Layer-2
/// 的产物，按其输出格式手工构造（被测的是合并器，不是 agent）。
@Test
func testMergePatchConfidenceKeepsEntityFieldsAndContextRef(): Unit {
    let root = writeTree()
    try {
        let g = buildGraph(root)
        let diff = """
+++ b/flow/update.cj
@@ -0,0 +1,5 @@
+public func newThing(): Int64 { return 1 }
+
+        runHelper()
+        otherHelper()
"""
        let pc = analyzePatchConfidence(g, diff)
        // 前提：夹具真的产出了实体与未决项（否则两条断言都在测空集合）
        @Assert(Int64(pc.entities.size) > 0)
        @Assert(Int64(pc.uncertain.size) >= 2)
        let algorithm = patchConfidenceJson(pc)

        // Layer-2：第一条 uncertain 给 resolved 裁决，第二条不处理（deferred 分支）
        let uncArr = Json.arrAt(algorithm, "uncertain")
        let firstId = Json.strAt(uncArr[0], "id", "")
        let item = Json.obj()
        Json.set(item, "id", Json.of(firstId))
        Json.set(item, "verdict", Json.of("resolved"))
        Json.set(item, "value", Json.of("x"))
        Json.set(item, "confidence", Json.of(0.8))
        Json.set(item, "reason", Json.of("verified in test"))
        let refs = ArrayList<JsonValue>()
        refs.add(Json.of("flow/update.cj:3"))
        Json.set(item, "evidence_refs", JArr(refs))
        let items = ArrayList<JsonValue>()
        items.add(item)
        let agent = Json.obj()
        Json.set(agent, "task", Json.of("layer2_review"))
        Json.set(agent, "items", JArr(items))

        match (mergePatchConfidence(algorithm, agent)) {
            case Some(m) =>
                let finalJ = mergedConfidenceJson(m, algorithm)
                let ents = Json.arrAt(finalJ, "entities")

                // ① 算法层实体：file/line/kind 逐字段与 Layer-1 一致（不是只有键）
                let src0 = Json.arrAt(algorithm, "entities")[0]
                let srcId = Json.strAt(src0, "id", "")
                var matched = false
                for (e in ents) {
                    if (Json.strAt(e, "id", "") == srcId) {
                        matched = true
                        @Assert(Json.strAt(e, "source", "") == "algorithm")
                        @Assert(Json.strAt(e, "file", "?") == Json.strAt(src0, "file", "!"))
                        @Assert(Json.intAt(e, "line", -1) == Json.intAt(src0, "line", -2))
                        @Assert(Json.strAt(e, "kind", "?") == Json.strAt(src0, "kind", "!"))
                    }
                }
                @Assert(matched)   // 前提：真找到了那条算法层实体

                // ② uncertain 合并条目：context_ref 保留（resolved 与 deferred
                //    两分支都要有），且 file/line 与 Layer-1 一致
                var agentSeen = false
                var deferredSeen = false
                for (u in uncArr) {
                    let uid = Json.strAt(u, "id", "")
                    for (e in ents) {
                        if (Json.strAt(e, "id", "") != uid) { continue }
                        let src = Json.strAt(e, "source", "")
                        if (src != "agent" && src != "deferred") { continue }
                        if (src == "agent") { agentSeen = true }
                        if (src == "deferred") { deferredSeen = true }
                        @Assert(Json.has(e, "context_ref"))
                        let cr = Json.getOr(e, "context_ref")
                        let orig = Json.getOr(u, "context_ref")
                        @Assert(Json.strAt(cr, "file", "?") == Json.strAt(orig, "file", "!"))
                        @Assert(Json.intAt(cr, "line", -1) == Json.intAt(orig, "line", -2))
                    }
                }
                @Assert(agentSeen)
                @Assert(deferredSeen)
            case None => @Assert(false)
        }
    } finally {
        removeTree(root)
    }
}

// MARK: - R6：读不到的目录在图谱出口披露（契约A 出口侧）

/// R6 回归（恒发半边）：fullGraphJson / overviewJson 恒发 unreadableDirs 与
/// unreadableDirsTruncated（空数组 / false 也发）——「读不到」与「没有」是两个
/// 状态，缺键会被下游读成后者。
@Test
func testGraphJsonExitsAlwaysEmitUnreadableDirsKeys(): Unit {
    let root = writeTree()
    try {
        let g = buildGraph(root)
        for (j in [fullGraphJson(g, 0), overviewJson(g)]) {
            @Assert(Json.has(j, "unreadableDirs"))
            @Assert(Json.has(j, "unreadableDirsTruncated"))
            @Assert(Int64(Json.arrAt(j, "unreadableDirs").size) == 0)
            // fallback 取反：键缺失即红
            @Assert(Json.boolAt(j, "unreadableDirsTruncated", true) == false)
        }
        // 文本出口：空态不天天提醒（披露行只在确有读不到的目录时出现）
        @Assert(!treeText(g, 0).contains("目录读不到"))
    } finally {
        removeTree(root)
    }
}

/// R6 回归（披露半边）：真实「读不到」的目录 —— chmod 000（仓颉 std 无权限
/// API，借 /bin/chmod，同 AGENTS #35 的先例）—— 必须出现在两个 JSON 出口的
/// unreadableDirs 里，treeText 也要有披露行。
@Test
func testUnreadableDirIsDisclosedInGraphExits(): Unit {
    let root = writeTree()
    ensureDir("${root}/locked")
    writeFileAtomic("${root}/locked/inside.cj", "package locked\n")
    try {
        let r = execCapture("/bin/chmod", ["000", "${root}/locked"], Option<String>.None, 10000)
        @Assert(r.exitCode == 0)   // 前提：权限真的改掉了，否则下面测的是空转
        let g = buildGraph(root)
        @Assert(Int64(g.unreadableDirs.size) > 0)   // 前提：核心侧真收集到（契约A）
        let full = fullGraphJson(g, 0)
        @Assert(Int64(Json.arrAt(full, "unreadableDirs").size) > 0)
        let ov = overviewJson(g)
        @Assert(Int64(Json.arrAt(ov, "unreadableDirs").size) > 0)
        @Assert(treeText(g, 0).contains("目录读不到"))
    } finally {
        // 先恢复权限再删树：chmod 000 的目录删不掉，finally 一声不响就会攒残留
        execCapture("/bin/chmod", ["755", "${root}/locked"], Option<String>.None, 10000)
        removeTree(root)
    }
}

// MARK: - R7：treeText 读不到目录的两档披露（收集上限 vs 展示上限）

/// 合成图谱：不落盘、无 IO——R7 测的是出口文案对 unreadableDirs 条数的分档，
/// 注入比「chmod 200 个目录」便宜且同样走真实 treeText。
func syntheticGraphWithUnreadable(unreadable: ArrayList<String>): CodeGraph {
    return CodeGraph(
        "/tmp/moongit-archfix-synthetic",
        ArrayList<FileEntry>(),
        ArrayList<(String, String)>(),
        ArrayList<(String, String, Int64)>(),
        false, 0, HashSet<String>(),
        ArrayList<(String, String, Int64)>(),
        ArrayList<(String, String, Int64)>(),
        0, unreadable,
        ArrayList<(String, String, Int64)>())
}

/// R7 回归：读不到的目录有两档「没看完」——核心侧收集上限
/// （GRAPH_MAX_UNREADABLE_DIRS=200）与出口展示上限（UNREADABLE_DIRS_SHOWN=20）
/// 共用一个标志时，>200 场景下披露数字停在 200 无法区分成因；达到收集上限时
/// 数字是**下界**，文案必须说清（「恰好 200」与「至少 200」在文本里不得同形）。
@Test
func testTreeTextUnreadableDirsTwoTierDisclosure(): Unit {
    // 普通档：3 条远未到收集上限 —— 维持原文案，不引入「至少」
    let few = ArrayList<String>()
    few.add("a")
    few.add("b")
    few.add("c")
    let plain = treeText(syntheticGraphWithUnreadable(few), 0)
    @Assert(plain.contains("⚠ 3 个目录读不到（以上不含它们的内容，不是全量）"))
    @Assert(!plain.contains("至少"))
    // 上限档：条数达到收集上限 —— 「至少」+「已达收集上限」两个限定都要在
    let capped = ArrayList<String>()
    var i: Int64 = 0
    while (i < GRAPH_MAX_UNREADABLE_DIRS) {
        capped.add("d${i}")
        i += 1
    }
    let hit = treeText(syntheticGraphWithUnreadable(capped), 0)
    @Assert(hit.contains("至少 ${Int64(GRAPH_MAX_UNREADABLE_DIRS)} 个目录读不到"))
    @Assert(hit.contains("已达收集上限 ${GRAPH_MAX_UNREADABLE_DIRS}"))
    @Assert(hit.contains("以上不含它们的内容，不是全量"))
}

// MARK: - R8：archJson 边的 violation/cycle 恒发 + drilldown 边同形状

/// R8 回归（恒发半边）：模块级边与 drilldown 边都必须有 violation/cycle 两键
/// （false 也发）。原先模块级边只在 true 时写键（键集随数据漂移），drilldown
/// 边则完全没有这两键 —— 同一份 JSON 两种边形状，消费方得写两套解码分支。
@Test
func testArchJsonEdgesAlwaysEmitViolationCycleKeys(): Unit {
    let root = writeTree()
    try {
        let arch = buildArch(buildGraph(root))
        // 前提：夹具确有模块级边与 drilldown 子图（空集上「每条边都有键」恒真）
        @Assert(Int64(arch.edges.size) > 0)
        @Assert(Int64(arch.drilldown.size) > 0)
        let j = archJson(arch, false)
        for (e in Json.arrAt(j, "edges")) {
            @Assert(Json.has(e, "violation"))
            @Assert(Json.has(e, "cycle"))
            // fallback 取反：键缺失即红（恒发与值一起钉）
            @Assert(Json.boolAt(e, "violation", true) == false)
            @Assert(Json.boolAt(e, "cycle", true) == false)
        }
        match (Json.getOr(j, "drilldown")) {
            case JObj(m) =>
                var drillEdges: Int64 = 0
                for ((_, sub) in m) {
                    for (eo in Json.arrAt(sub, "edges")) {
                        drillEdges += 1
                        @Assert(Json.has(eo, "violation"))
                        @Assert(Json.has(eo, "cycle"))
                    }
                }
                @Assert(drillEdges > 0)   // 前提：真有 drilldown 边可测
            case _ => @Assert(false)
        }
    } finally {
        removeTree(root)
    }
}

/// R8 回归（信号半边）：drilldown 边的 violation 必须与它所跨模块对的模块级
/// 信号一致 —— 造一条 util(层0) → cli(层3) 的违规边（isLayerViolation(0,3)），
/// util 子图里指向 @module:cli 的文件级边必须带 violation=true；
/// 同模块内部边（无模块级对应）恒 false。
@Test
func testArchJsonDrilldownEdgeCarriesModuleViolationSignal(): Unit {
    let root = writeTree()
    try {
        // util 文件引用 cli/main.swift 定义的 Runner：类型标注即可形成引用边
        //（writeTree 夹具里 flow→util 的引用边就是 `t: Text` 这么形成的）
        writeFileAtomic("${root}/util/bad.cj", """
package moongit.util

public func usesRunner(): Bool {
    let r: Runner = Runner()
    return r.go()
}
""")
        let j = archJson(buildArch(buildGraph(root)), false)
        // 前提：模块级真的有违规边 util→cli
        var violEdge = Option<JsonValue>.None
        for (e in Json.arrAt(j, "edges")) {
            if (Json.strAt(e, "from", "") == "util" && Json.strAt(e, "to", "") == "cli") {
                violEdge = Option<JsonValue>.Some(e)
            }
        }
        @Assert(violEdge.isSome())
        @Assert(Json.boolAt(violEdge.getOrThrow(), "violation", false))
        let sub = Json.getOr(Json.getOr(j, "drilldown"), "util")
        var crossSeen = false
        for (eo in Json.arrAt(sub, "edges")) {
            if (Json.strAt(eo, "to", "") == "@module:cli") {
                crossSeen = true
                @Assert(Json.boolAt(eo, "violation", false))
            }
        }
        @Assert(crossSeen)   // 前提：跨模块边真的落到了虚拟节点上
    } finally {
        removeTree(root)
    }
}

// MARK: - R9：语言色值表的单一构造点（scene / archhtml / treehtml 三出口同源）

/// langs JSON 形态 → 平面映射（值非字符串的键丢弃——色值表只该有字符串值）。
func paletteMapOf(langsJson: JsonValue): HashMap<String, String> {
    let m = HashMap<String, String>()
    match (langsJson) {
        case JObj(o) =>
            for ((k, v) in o) {
                match (v) {
                    case JStr(s) => m[k] = s
                    case _ => ()
                }
            }
        case _ => ()
    }
    return m
}

/// 映射断言：got 必须与 langThemeColors(dark) 的键值**完全一致**。
/// 前提先行（want 非空、两侧键数相等）——空集对空集会让逐键断言空转着绿。
func assertPaletteMatches(got: HashMap<String, String>, dark: Bool): Unit {
    let want = HashMap<String, String>()
    for ((k, v) in langThemeColors(dark)) { want[k] = v }
    @Assert(want.size > 0)
    @Assert(got.size == want.size)
    for ((k, v) in got) {
        match (want.get(k)) {
            case Some(c) => @Assert(v == c)
            case None => @Assert(false)
        }
    }
}

/// 从架构页产物提取驱动 JS PAL 的第 nth 个 langs 映射
/// （`langs:{ k:'v', … }` 片段，dark 在前 light 在后；键不带引号）。
/// 提取失败返回空映射——由调用方的「键数相等」前提把它变红，不静默通过。
func archHtmlLangPalette(html: String, nth: Int64): HashMap<String, String> {
    let m = HashMap<String, String>()
    var found: Int64 = 0
    var pos = 0
    while (found <= nth) {
        match (html.indexOf("langs:{ ", pos)) {
            case Some(p) =>
                if (found == nth) {
                    match (html.indexOf(" }", p)) {
                        case Some(e) =>
                            let body = html[(p + 8)..e]
                            for (pair in body.split(", ")) {
                                let kv = pair.split(":'")
                                if (kv.size == 2) {
                                    let colorRaw = kv[1]
                                    m[kv[0]] = colorRaw[0..(colorRaw.size - 1)]
                                }
                            }
                            return m
                        case None => return m
                    }
                }
                found += 1
                pos = p + 1
            case None => return m
        }
    }
    return m
}

/// R9 回归（行为半边）：三处产物必须携带同一组语言→色值映射 ——
/// treehtml 产物内嵌 JSON 的 langThemes.{dark,light}、archhtml 产物
/// 驱动 JS 的 PAL langs。输出形态各异（页面 JSON / JS 字面量），值必须同源。
@Test
func testLangThemePaletteSharedAcrossTreeHtmlAndArchHtml(): Unit {
    let root = writeTree()
    try {
        let g = buildGraph(root)
        // ① treehtml 出口：走真实产物，提取内嵌 JSON 再解 langThemes
        let html = treeCanvasHtml(g, 0, false, analyzeConfidence(g, false))
        let marker = "window.__CODEGRAPH__ = "
        match (html.indexOf(marker)) {
            case Some(s0) =>
                let start = s0 + marker.toArray().size
                match (html.indexOf(";\n</script>", start)) {
                    case Some(e0) =>
                        match (Json.parse(html[start..e0])) {
                            case Some(j) =>
                                let lt = Json.getOr(j, "langThemes")
                                assertPaletteMatches(paletteMapOf(Json.getOr(lt, "dark")), true)
                                assertPaletteMatches(paletteMapOf(Json.getOr(lt, "light")), false)
                            case None => @Assert(false)
                        }
                    case None => @Assert(false)
                }
            case None => @Assert(false)
        }
        // ③ archhtml 出口：驱动 JS 的 PAL langs（dark 第 0 个、light 第 1 个）
        let ahtml = archCanvasHtml(buildArch(g), false)
        assertPaletteMatches(archHtmlLangPalette(ahtml, 0), true)
        assertPaletteMatches(archHtmlLangPalette(ahtml, 1), false)
    } finally {
        removeTree(root)
    }
}

/// R9 源码守卫：语言色值字面量只许出现在 archscene.cj 的 langThemeColors
/// 构造点 —— archhtml.cj / treehtml.cj 再出现即手抄副本（多份副本必然漂移，
/// 漂移症状是同一语言在三个画面颜色不一致，且无任何测试能抓到）。
/// 判据用「语言专属」特征色值：#94a3b8 / #64748b（module 两色）与 UI 通用色
/// 撞车（CSS muted / tierHex fallback 都在用），进了清单就会误伤合法代码。
/// 匹配前剥注释 —— 解释性注释里引用色值会假红（同 AGENTS #30/#47 的教训）。
@Test
func __lintLangColorLiteralsHaveSingleConstructionSite(): Unit {
    let features = ["#f05138", "#f7801e", "#de6d10", "#3178c6", "#3572a5",
        "#00add8", "#00869b", "#dea584", "#b7410e", "#b07219", "#a97bff",
        "#7c4dff", "#555555", "#444444"]
    func codeOf(path: String): String {
        let raw = readFileTextChecked(path).getOrThrow()
        let sb = StringBuilder()
        var blk = CjStripState.Normal
        for (r in raw.split("\n")) {
            let (l, nb) = stripCjCommentEx(r, blk)
            blk = nb
            sb.append(l)
            sb.append("\n")
        }
        return sb.toString()
    }
    func countNeedle(code: String, needle: String): Int64 {
        var n: Int64 = 0
        var pos = 0
        while (true) {
            match (code.indexOf(needle, pos)) {
                case Some(p) => n += 1; pos = p + 1
                case None => break
            }
        }
        return n
    }
    func featureHits(code: String): Int64 {
        var n: Int64 = 0
        for (f in features) { n += countNeedle(code, f) }
        return n
    }
    // 构造点侧预期：langThemeColors 里命中特征色值的条数（改表时自动跟随，
    // 不硬编码数字——硬编码会在合法调色时假红）
    func paletteFeatureHits(dark: Bool): Int64 {
        var n: Int64 = 0
        for ((_, c) in langThemeColors(dark)) {
            for (f in features) {
                if (c == f) { n += 1 }
            }
        }
        return n
    }
    var want = paletteFeatureHits(true)
    want += paletteFeatureHits(false)
    @Assert(want > 0)   // 前提：特征集真命中了构造点（特征集体失效 = 空转绿）
    @Assert(featureHits(codeOf("src/graph/archscene.cj")) == want)   // 恰在构造点，不多不少
    @Assert(featureHits(codeOf("src/graph/archhtml.cj")) == 0)       // 零手抄
    @Assert(featureHits(codeOf("src/graph/treehtml.cj")) == 0)       // 零手抄
}

// MARK: - R10：treehtml 驱动的属性上下文转义（esc 补引号）

/// R10 回归：esc() 只转 & 和 < 却被用于 data-jump="…" 属性上下文 ——
/// 含双引号的文件名（macOS/Linux 合法）会提前闭合属性，点击跳转拿到截断 id
/// （archhtml L6 修过的同族缺陷）。2026-10-12 参考稿重设计：esc 改为
/// 字符映射表实现（& < > " ' 五字符全转义），消费点从 data-peer 换成
/// 侧栏 data-jump 属性——语义不变：属性上下文必须连引号一起转。
@Test
func testTreeHtmlDriverEscapesQuotesForAttributeContext(): Unit {
    let root = writeTree()
    try {
        let g = buildGraph(root)
        let html = treeCanvasHtml(g, 0, false, analyzeConfidence(g, false))
        // esc 定义：字符映射表里必须含双引号 → &quot;
        @Assert(html.contains("'\"': '&quot;'"))
        // 消费点还在：esc 确实用于 data-jump 属性（防只改定义不接线）
        @Assert(html.contains("data-jump=\"' + esc("))
        // 旧写法（只转 & 与 < 就收尾）必须消失
        @Assert(!html.contains(".replace(/</g, '&lt;'); }"))
    } finally {
        removeTree(root)
    }
}

/// 限流披露键（cappedKind/cappedTotal）必须透传引擎真值且恒发：
/// 旧行为拿结果集反推（findings.size 或同类计数 >= 阈值），
/// 「恰好 6 条未截断」会被误报成「超出已汇总」。真值的置位行为由
/// testConfidenceCappedFlagsComeFromRealDrops（graph_test.cj）钉住，
/// 这里钉的是内嵌出口与真值同源——布尔默认值取反法：键缺失时
/// boolAt 返回默认 true，断言 == false 必红，恒发与取值一次钉住。
@Test
func testConfidenceEmbedPassesThroughEngineCappedFlags(): Unit {
    func reportOf(ck: Bool, ct: Bool): ConfidenceReport {
        return ConfidenceReport("sandbox", 100, ArrayList<Finding>(), true, "",
            0, ArrayList<(FlawKind, Int64)>(), ArrayList<(String, Int64)>(),
            ArrayList<(ConfDimension, Int64, Int64, Int64)>(), cappedKind: ck, cappedTotal: ct)
    }
    let clean = confidenceEmbedJson(reportOf(false, false), false)
    @Assert(Json.boolAt(clean, "cappedKind", true) == false)
    @Assert(Json.boolAt(clean, "cappedTotal", true) == false)
    let capped = confidenceEmbedJson(reportOf(true, true), false)
    @Assert(Json.boolAt(capped, "cappedKind", false) == true)
    @Assert(Json.boolAt(capped, "cappedTotal", false) == true)
}

/// 限流披露必须在**每一个出口**（不变量 33）：JSON（CLI/MCP）、文本、LLM
/// 提示词包三出口都消费 cappedKind/cappedTotal 真值。HTML 内嵌的透传由
/// testConfidenceEmbedPassesThroughEngineCappedFlags 钉住，这里钉其余三出口。
/// 用命名参数构造双 true 报告：若出口条件性发键/漏披露，默认值取反即红。
@Test
func testConfidenceCappedDisclosureReachesEveryOutlet(): Unit {
    let r = ConfidenceReport("sandbox", 27, ArrayList<Finding>(), false, "词法降级",
        5, ArrayList<(FlawKind, Int64)>(), ArrayList<(String, Int64)>(),
        ArrayList<(ConfDimension, Int64, Int64, Int64)>(), cappedKind: true, cappedTotal: true)
    // ① JSON 出口：两键恒发且为真值
    let j = confidenceJson(r)
    @Assert(Json.boolAt(j, "cappedKind", false))
    @Assert(Json.boolAt(j, "cappedTotal", false))
    // ② 文本出口：全量上限披露行
    let txt = confidenceText(r)
    @Assert(txt.contains("已达全量上限"))
    // ③ LLM 提示词出口：模型必须知道拿到的是子集
    let llm = confidenceLlmPrompt(r, "demo")
    @Assert(llm.contains("全量上限"))
    // 干净报告：JSON 仍恒发（false 也发），文本/LLM 不凭空警示
    let clean = ConfidenceReport("sandbox", 100, ArrayList<Finding>(), true, "",
        5, ArrayList<(FlawKind, Int64)>(), ArrayList<(String, Int64)>(),
        ArrayList<(ConfDimension, Int64, Int64, Int64)>())
    let jc = confidenceJson(clean)
    @Assert(!Json.boolAt(jc, "cappedKind", true))
    @Assert(!Json.boolAt(jc, "cappedTotal", true))
    @Assert(!confidenceText(clean).contains("已达全量上限"))
    @Assert(!confidenceLlmPrompt(clean, "demo").contains("全量上限"))
}

// MARK: - R11：引用边双口径（refEdges 引用语义 / archRefEdges 架构语义）
//
// 【背景】refEdges 直接喂 buildArch 时架构违规满屏：引擎自身 9/9 模块对
// 「全违规」，逐边归因全是同名噪音（doc 注释提及他包符号、strx.cj 每包一份
// 的合法重名、泛型占位符 T 撞翻译函数 T、局部变量撞成员方法），没有一条
// 是真依赖。修法是引用边双口径：refEdges 维持现状（引用语义，对外契约
// referenceEdges 不变），新增 archRefEdges（架构语义，判据见 model.cj 字段
// 注释）供 buildArch 消费。北极度量：引擎自身架构违规清零。

/// 无向命中查询：edges 里是否存在 from→to 边。
func hasEdge(edges: ArrayList<(String, String, Int64)>, from: String, to: String): Bool {
    for ((a, b, _) in edges) {
        if (a == from && b == to) { return true }
    }
    return false
}

/// R11 共享夹具：三个互不相关的公开符号（分文件，「提及 A 却引用 B」才能
/// 精确区分）+ 引擎自身假边形态的四件套（跨模块同名 isBlank / 缩进成员
/// 方法 size / 泛型参数 T / cli 的翻译函数 T）。
func writeArchFixTree(): String {
    let root = testRoot()
    ensureDir("${root}/util")
    ensureDir("${root}/kernel")
    ensureDir("${root}/flow")
    ensureDir("${root}/graph")
    ensureDir("${root}/cli")
    writeFileAtomic("${root}/util/hosta.cj", """
package moongit.util

public func archSymAlpha(): Int64 { return 1 }
""")
    writeFileAtomic("${root}/util/hostb.cj", """
package moongit.util

public func archSymBeta(): Int64 { return 2 }
""")
    writeFileAtomic("${root}/util/hostc.cj", """
package moongit.util

public func archSymGamma(): Int64 { return 3 }
""")
    // (d)：跨模块同名公开符号（strx.cj 每包一份是 AGENTS 明文的合法重名）
    writeFileAtomic("${root}/util/strx.cj", """
package moongit.util

public func isBlank(s: String): Bool { return true }
""")
    writeFileAtomic("${root}/kernel/strx.cj", """
package moongit.kernel

public func isBlank(s: String): Bool { return true }
""")
    // (d)：成员方法（缩进声明）——跨包不可能以自由标识符形态调用
    writeFileAtomic("${root}/util/box.cj", """
package moongit.util

public class Box {
    public func size(): Int64 { return 1 }
}
""")
    // (d)：与泛型占位符 T 同名的公开函数（引擎自身 cli/lang.cj 的真实形态）
    writeFileAtomic("${root}/cli/lang.cj", """
package moongit.cli

public func T(en: String, zh: String): String { return zh }
""")
    return root
}

/// (a) 注释提及：行内注释与 doc 注释里出现他模块定义的符号名 → 架构口径
/// 无边。真调用另一符号作前提（否则「无边」可能是扫描器没在跑的空转绿，
/// 不变量 18）——refEdges 的剥注释口径是既有行为，一并钉住防回退。
@Test
func testArchRefEdgesIgnoreCommentMentions(): Unit {
    let root = writeArchFixTree()
    try {
        writeFileAtomic("${root}/graph/comment.cj", """
package moongit.graph

// 本行注释提到 archSymBeta 只是文档
/// doc 注释也提到 archSymBeta
public func callAlpha(): Int64 { return archSymAlpha() }
""")
        let g = buildGraph(root)
        // 前提：真调用在两口径都产边（基础设施在跑）
        @Assert(hasEdge(g.refEdges, "graph/comment.cj", "util/hosta.cj"))
        @Assert(hasEdge(g.archRefEdges, "graph/comment.cj", "util/hosta.cj"))
        // 注释里的提及在两口径都不算引用
        @Assert(!hasEdge(g.refEdges, "graph/comment.cj", "util/hostb.cj"))
        @Assert(!hasEdge(g.archRefEdges, "graph/comment.cj", "util/hostb.cj"))
        // 精确性：该文件的架构口径出边恰好一条（真调用），注释没有漏进来
        var archOut: Int64 = 0
        for ((from, _, _) in g.archRefEdges) {
            if (from == "graph/comment.cj") { archOut += 1 }
        }
        @Assert(archOut == 1)
    } finally {
        removeTree(root)
    }
}

/// (b) 字符串字面量：单行与多行字符串里出现他模块定义的符号名 → 架构口径
/// 无边。真调用另一符号作前提（同 (a)）。内容用 StringBuilder 拼 —— 多行
/// 字符串里嵌 \"\"\" 不适合再套一层字面量（AGENTS 编码约定）。
@Test
func testArchRefEdgesIgnoreStringLiterals(): Unit {
    let root = writeArchFixTree()
    try {
        let sb = StringBuilder()
        sb.append("package moongit.graph\n\n")
        sb.append("public func gammaInString(): String { return \"archSymGamma\" }\n\n")
        sb.append("public func gammaInMultiline(): String {\n")
        sb.append("    return \"\"\"\n")
        sb.append("    这里提到 archSymGamma 但只是字面量\n")
        sb.append("    \"\"\"\n")
        sb.append("}\n\n")
        sb.append("public func callAlpha2(): Int64 { return archSymAlpha() }\n")
        writeFileAtomic("${root}/graph/strlit.cj", sb.toString())
        let g = buildGraph(root)
        // 前提：真调用在两口径都产边
        @Assert(hasEdge(g.refEdges, "graph/strlit.cj", "util/hosta.cj"))
        @Assert(hasEdge(g.archRefEdges, "graph/strlit.cj", "util/hosta.cj"))
        // 字符串里的提及在两口径都不算引用
        @Assert(!hasEdge(g.refEdges, "graph/strlit.cj", "util/hostc.cj"))
        @Assert(!hasEdge(g.archRefEdges, "graph/strlit.cj", "util/hostc.cj"))
    } finally {
        removeTree(root)
    }
}

/// (c) 真实跨模块代码调用：两口径都必须有边（防修过头把真引用也剥掉）。
/// 自由函数调用与顶格公开类的类型标注两种形态都要幸存；成员方法调用
/// （b.size()）不得给目标文件添第二条边（size 是缩进成员，跨包不可达）。
@Test
func testArchRefEdgesKeepRealCrossModuleCalls(): Unit {
    let root = writeArchFixTree()
    try {
        writeFileAtomic("${root}/graph/caller.cj", """
package moongit.graph

public func callAlpha3(): Int64 { return archSymAlpha() }

public func usesBox(b: Box): Int64 { return b.size() }
""")
        let g = buildGraph(root)
        @Assert(hasEdge(g.refEdges, "graph/caller.cj", "util/hosta.cj"))
        @Assert(hasEdge(g.archRefEdges, "graph/caller.cj", "util/hosta.cj"))
        @Assert(hasEdge(g.refEdges, "graph/caller.cj", "util/box.cj"))
        @Assert(hasEdge(g.archRefEdges, "graph/caller.cj", "util/box.cj"))
        // box.cj 边的权重恰为 1：Box（类型标注）算，size（成员方法）不算
        var boxW: Int64 = 0
        for ((from, to, w) in g.archRefEdges) {
            if (from == "graph/caller.cj" && to == "util/box.cj") { boxW = w }
        }
        @Assert(boxW == 1)
    } finally {
        removeTree(root)
    }
}

/// (d) 引擎自身假边形态的定向回归：跨模块同名公开符号（isBlank 每包一份）
/// 在引用口径如实成边、在架构口径被歧义剔除；泛型参数 T（声明）不产生
/// → cli/lang.cj 的撞名假边（引用口径的这条假边正是引擎自身 graph→cli
/// 违规对的真实成因之一）。北极星形态：flow 的架构口径出边为空。
@Test
func testArchRefEdgesRejectCrossModuleAmbiguityAndGenerics(): Unit {
    let root = writeArchFixTree()
    try {
        writeFileAtomic("${root}/flow/app.cj", """
package moongit.flow

public func runApp(): Bool { return isBlank("x") }

public func genericCaller(): Int64 { return wrapFn<Int64>(7) }

public func wrapFn<T>(x: T): T { return x }
""")
        let g = buildGraph(root)
        // 引用口径（refEdges）如实保留同名噪音——对外契约不变
        @Assert(hasEdge(g.refEdges, "flow/app.cj", "kernel/strx.cj"))
        @Assert(hasEdge(g.refEdges, "flow/app.cj", "util/strx.cj"))
        @Assert(hasEdge(g.refEdges, "flow/app.cj", "cli/lang.cj"))
        // 架构口径：isBlank 定义跨 util/kernel 两模块 = 词法歧义，两条都不产生
        @Assert(!hasEdge(g.archRefEdges, "flow/app.cj", "kernel/strx.cj"))
        @Assert(!hasEdge(g.archRefEdges, "flow/app.cj", "util/strx.cj"))
        // 架构口径：声明行的泛型参数 T 是声明不是引用，不撞 cli/lang.cj 的 T
        @Assert(!hasEdge(g.archRefEdges, "flow/app.cj", "cli/lang.cj"))
        // 北极星形态：本夹具 flow 没有真跨模块依赖，架构口径出边必须为空
        var flowOut: Int64 = 0
        for ((from, _, _) in g.archRefEdges) {
            if (from == "flow/app.cj") { flowOut += 1 }
        }
        @Assert(flowOut == 0)
    } finally {
        removeTree(root)
    }
}

// MARK: - R12：架构口径残留泄漏的两处收尾（二轮自测：9 对 → 2 对 → 0 对）

/// (e) 泛型实参位置（判据⑤）：函数体内的 `Option<T>` 的 T 前导 `<`——
/// 类型实参的归属需要类型信息，词法不可判。引擎自身 lock.cj 的
/// `var result: Option<T> = None`（函数体行，非声明行）曾因此残留
/// kernel→cli 假边。引用口径的 T 边如实保留（对外契约）。
@Test
func testArchRefEdgesIgnoreGenericTypeArguments(): Unit {
    let root = writeArchFixTree()
    try {
        writeFileAtomic("${root}/graph/genuse.cj", """
package moongit.graph

public func wrapGen<T>(x: T): T {
    let cached: Option<T> = None
    if (cached.isSome()) { return x }
    return x
}

public func callAlpha4(): Int64 { return archSymAlpha() }
""")
        let g = buildGraph(root)
        // 前提：T 的定义（cli/lang.cj，引擎自身的翻译函数）确实被看见——
        // 引用口径的 T 撞名边存在（契约保留，不是空转绿）
        @Assert(hasEdge(g.refEdges, "graph/genuse.cj", "cli/lang.cj"))
        // 架构口径：声明行的 T（判据④）与 Option<T> 泛型实参的 T（判据⑤）
        // 都不产生 → cli 的撞名假边
        @Assert(!hasEdge(g.archRefEdges, "graph/genuse.cj", "cli/lang.cj"))
        // 真调用幸存（防修过头）
        @Assert(hasEdge(g.archRefEdges, "graph/genuse.cj", "util/hosta.cj"))
    } finally {
        removeTree(root)
    }
}

/// (f) 字符串里的 import 不是 import：scanSource 的 import 检测用原始行
/// （行锚定，extract.cj 的设计取舍），夹具字符串里的 `from flow.update
/// import fakeImport` 曾被当成真 import 拖进 importEdges，在架构图上
/// 捏造 graph→flow 模块依赖（二轮自测的残留违规对之一）。过滤后真 import
/// 与 `#include`（C 的 import 形态，被 stripCode 的 # 注释词头剥空，特例
/// 收集）都必须存活。
@Test
func testImportEdgesIgnoreImportsInsideStringLiterals(): Unit {
    let root = writeArchFixTree()
    try {
        let sb = StringBuilder()
        sb.append("package moongit.graph\n\n")
        sb.append("import moongit.util\n\n")
        sb.append("public func caller3(): Int64 { return archSymAlpha() }\n\n")
        sb.append("public func docText2(): String {\n")
        sb.append("    return \"\"\"\n")
        sb.append("    from flow.update import fakeImport\n")
        sb.append("    \"\"\"\n")
        sb.append("}\n")
        writeFileAtomic("${root}/graph/realimp.cj", sb.toString())
        // 假 import 的解析目标：flow 模块里真有同名目录与符号可命中
        writeFileAtomic("${root}/flow/fake.cj", """
package moongit.flow

public func fakeImport(): Int64 { return 9 }
""")
        // #include 被 stripCode 的 # 注释词头剥空——特例必须收，
        // 否则 C 项目的 include 边全部被误杀
        writeFileAtomic("${root}/graph/user.h", """
#include "hosta.cj"

int use(void) { return 0; }
""")
        let g = buildGraph(root)
        // 前提：真 import 存活（解析到 util 模块的文件）
        var hasRealImport = false
        var hasFakeImport = false
        var hasInclude = false
        for ((from, to) in g.importEdges) {
            if (from == "graph/realimp.cj" && to.startsWith("util/")) { hasRealImport = true }
            if (from == "graph/realimp.cj" && to.startsWith("flow/")) { hasFakeImport = true }
            if (from == "graph/user.h" && to.startsWith("util/")) { hasInclude = true }
        }
        @Assert(hasRealImport)
        // 字符串里的假 import 不进 importEdges——flow 方向零边
        @Assert(!hasFakeImport)
        // #include 特例存活
        @Assert(hasInclude)
        // 引用/架构两口径都没有 fakeImport 符号边（字符串已剥，双保险）
        @Assert(!hasEdge(g.refEdges, "graph/realimp.cj", "flow/fake.cj"))
        @Assert(!hasEdge(g.archRefEdges, "graph/realimp.cj", "flow/fake.cj"))
    } finally {
        removeTree(root)
    }
}

// MARK: - R13：架构图深度技术呈现（扇入/扇出/不稳定度 + 分层泳道布局）
//
// 【背景】用户反馈「只是模块流转，看不出实质」。升级三件事：
//   ① 治理指标：fanIn/fanOut/instability（口径 = 模块级 ArchEdge 的 weight，
//      唯一算法在 buildArch，各出口共用 ArchModule 上的同一份值）
//   ② 布局：分层泳道——L3(接口层) 在最上、L0(基础层) 在最下，
//      依赖健康方向 = 箭头向下；违规 = 逆流向上，一眼可见
//   ③ 出口恒发：archJson modules 四键 + lanes、scene panels 四键、
//      驱动 JS 真消费（数据说了必须有人显示，不变量 17）

/// R13 回归（指标半边）：fanIn/fanOut 逐模块与边表求和一致（口径唯一），
/// instability 与定义式逐模块一致且落在 0..100；夹具 flow→util 有真边
/// ⇒ util 被依赖（fanIn>0、不稳定度更低），flow 依赖别人（fanOut>0）。
/// 走真实 buildGraph + buildArch，不手搓 ArchData。
@Test
func testFanInFanOutInstabilityComputedFromAggregatedEdges(): Unit {
    let root = writeTree()
    try {
        let arch = buildArch(buildGraph(root))
        var utilM = Option<ArchModule>.None
        var flowM = Option<ArchModule>.None
        for (m in arch.modules) {
            if (m.id == "util") { utilM = Option<ArchModule>.Some(m) }
            if (m.id == "flow") { flowM = Option<ArchModule>.Some(m) }
        }
        @Assert(utilM.isSome())   // 前提：夹具真的有 util 模块
        @Assert(flowM.isSome())
        let u = utilM.getOrThrow()
        let f = flowM.getOrThrow()
        // 前提：flow→util 真有模块级边（writeTree 的 `t: Text` 引用边）
        var flowToUtil = false
        for (e in arch.edges) {
            if (e.fromId == "flow" && e.toId == "util") { flowToUtil = true }
        }
        @Assert(flowToUtil)
        @Assert(u.fanIn > 0)
        @Assert(f.fanOut > 0)
        @Assert(u.instability < f.instability)
        // 定义式逐模块一致（含 0 出入模块恒 0）；纯整数四舍五入
        // (200*fanOut+total)/(2*total) = round(100*fanOut/total)，零浮点
        for (m in arch.modules) {
            let total = m.fanIn + m.fanOut
            let want = if (total == 0) { 0 } else { (200 * m.fanOut + total) / (2 * total) }
            @Assert(m.instability == want)
            @Assert(m.instability >= 0)
            @Assert(m.instability <= 100)
        }
        // 口径唯一：fanIn/fanOut 必须等于模块级边表逐边求和（不许第二份算法）
        for (m in arch.modules) {
            var fi: Int64 = 0
            var fo: Int64 = 0
            for (e in arch.edges) {
                if (e.toId == m.id) { fi += e.weight }
                if (e.fromId == m.id) { fo += e.weight }
            }
            @Assert(m.fanIn == fi)
            @Assert(m.fanOut == fo)
        }
    } finally {
        removeTree(root)
    }
}

/// R13 回归（恒发半边）：archJson 的 modules 每项恒发 fanIn/fanOut/instability/
/// layerName 四键（0 也发）；`lanes` 恒发（本夹具必非空），泳道 y 自上而下
/// 单调递增（接口层在上、基础层在下），几何与布局常量同源。
/// 默认值取反法：键缺失时 intAt 返回默认 -1/101，断言必红——恒发与取值一起钉。
@Test
func testArchJsonModulesAlwaysEmitFanKeysAndLanes(): Unit {
    let root = writeTree()
    try {
        let arch = buildArch(buildGraph(root))
        layoutArch(arch)
        let j = archJson(arch, false)
        let ms = Json.arrAt(j, "modules")
        @Assert(ms.size > 0)   // 前提：夹具有模块（空集上「每项都有键」恒真空转）
        for (m in ms) {
            @Assert(Json.has(m, "fanIn"))
            @Assert(Json.has(m, "fanOut"))
            @Assert(Json.has(m, "instability"))
            @Assert(Json.has(m, "layerName"))
            @Assert(Json.intAt(m, "fanIn", -1) >= 0)
            @Assert(Json.intAt(m, "fanOut", -1) >= 0)
            @Assert(Json.intAt(m, "instability", -1) >= 0)
            @Assert(Json.intAt(m, "instability", 101) <= 100)
            @Assert(Json.strAt(m, "layerName", "").size > 0)
        }
        // lanes 条数 = 非空层数；自上而下 y 单调递增；泳道高 = 卡片高 + 上下留白
        let distinct = HashMap<Int64, Bool>()
        for (m in arch.modules) { distinct[m.layer] = true }
        let lanes = Json.arrAt(j, "lanes")
        @Assert(Int64(lanes.size) == Int64(distinct.size))
        var prevY = -1.0
        var y3 = -1.0
        var y0 = -1.0
        for (lane in lanes) {
            @Assert(Json.has(lane, "layer"))
            @Assert(Json.has(lane, "name"))
            @Assert(Json.has(lane, "modules"))
            let y = Json.numAt(lane, "y", -1.0)
            @Assert(y > prevY)
            prevY = y
            @Assert(Json.numAt(lane, "h", 0.0) == ARCH_CARD_H + ARCH_LANE_PAD_V * 2.0)
            let li = Json.intAt(lane, "layer", -1)
            if (li == 3) { y3 = y }
            if (li == 0) { y0 = y }
        }
        @Assert(prevY > 0.0)   // 前提：真的有泳道（否则上面的单调断言空转）
        // 接口层(3) 在基础层(0) 之上（y 向下 ⇒ y 更小）；夹具两层都在
        @Assert(y3 > 0.0 && y0 > 0.0)
        @Assert(y3 < y0)
    } finally {
        removeTree(root)
    }
}

/// R13 回归（布局半边）：分层泳道——同层所有卡片 y 相同、卡片尺寸固定为
/// 布局常量；接口层(cli, L3) 的 y < 编排层(flow, L2) < 基础层(util, L0)
/// （画布坐标 y 向下，接口层在上 ⇒ y 更小；健康依赖方向 = 箭头向下）。
@Test
func testLayoutSwimlaneSameLayerSameYAndInterfaceAboveFoundation(): Unit {
    let root = writeTree()
    try {
        let arch = buildArch(buildGraph(root))
        layoutArch(arch)
        // 前提：夹具同时有 cli(L3)/flow(L2)/util(L0) 三个层
        var sawL3 = false
        var sawL2 = false
        var sawL0 = false
        for (m in arch.modules) {
            if (m.layer == 3) { sawL3 = true }
            if (m.layer == 2) { sawL2 = true }
            if (m.layer == 0) { sawL0 = true }
        }
        @Assert(sawL3 && sawL2 && sawL0)
        // 同层 y 相同；尺寸 = 布局常量（固定卡片，不再按名字长度伸缩）
        let yByLayer = HashMap<Int64, Float64>()
        for (m in arch.modules) {
            @Assert(m.w == ARCH_CARD_W)
            @Assert(m.h == ARCH_CARD_H)
            match (yByLayer.get(m.layer)) {
                case Some(y) => @Assert(y == m.y)
                case None => yByLayer[m.layer] = m.y
            }
        }
        @Assert(yByLayer.size >= 3)   // 前提：上面逐层收 y 真收到了三层
        var y3 = 0.0
        var y2 = 0.0
        var y0 = 0.0
        for (m in arch.modules) {
            if (m.layer == 3) { y3 = m.y }
            if (m.layer == 2) { y2 = m.y }
            if (m.layer == 0) { y0 = m.y }
        }
        @Assert(y3 < y2)
        @Assert(y2 < y0)
        // 卡片在泳道内：x 不越过泳道右边界（泳道宽 = 标签区 + 最大槽数 × 槽宽）
        var maxSlots: Int64 = 1
        for (m in arch.modules) {
            var n: Int64 = 0
            for (m2 in arch.modules) {
                if (m2.layer == m.layer) { n += 1 }
            }
            if (n > maxSlots) { maxSlots = n }
        }
        let laneRight = ARCH_MARGIN + ARCH_LANE_LABEL_W + Float64(maxSlots) * ARCH_SLOT_W
        for (m in arch.modules) {
            @Assert(m.x >= ARCH_MARGIN + ARCH_LANE_LABEL_W)
            @Assert(m.x + m.w <= laneRight)
        }
    } finally {
        removeTree(root)
    }
}


/// R13 回归（驱动消费半边）：renderJs 必须真消费新数据——泳道（DATA.lanes）、
/// 卡片治理信号（fanIn/instability）、顶栏体检（buildHealth/Top3）、图例
/// （buildLegend）。键在数据里、页面不读 = 数据显示没算（不变量 17 的教训）。
/// 两种语言都要有消费点（英文模式同一分支），且双语词来自 ArchUi。
@Test
func testArchHtmlDriverConsumesFanKeysLanesHealthLegend(): Unit {
    let root = writeTree()
    try {
        let arch = buildArch(buildGraph(root))
        let zh = archCanvasHtml(arch, false)
        let en = archCanvasHtml(arch, true)
        for (html in [zh, en]) {
            @Assert(html.contains("DATA.lanes"))        // 泳道几何的消费点
            @Assert(html.contains("instability"))       // 不稳定度条
            @Assert(html.contains("fanIn"))             // 入出徽标
            @Assert(html.contains("buildHealth"))       // 顶栏体检区
            @Assert(html.contains("Top3"))              // 扇入/扇出 Top3
            @Assert(html.contains("buildLegend"))       // 图例
        }
        // 双语：中文页出现中文体检/图例词，英文页出现英文词（不许半中半英）
        @Assert(zh.contains("架构体检"))
        @Assert(zh.contains("无违规"))
        @Assert(zh.contains("不稳定度=出/(入+出)"))
        @Assert(en.contains("Fan-in"))
        @Assert(en.contains("no violations"))
        @Assert(en.contains("instability = out/(in+out)"))
    } finally {
        removeTree(root)
    }
}

// MARK: - R12b：豁免标志的下标修正（当前 token 自己的前导标志）

/// (g) 接收者调用豁免用的是**当前 token 自己**的前导点标志——曾误写下标
/// ai-1（那是前一个 token 的标志），判据③⑤整体失效：`boxed.T()` 的 T
/// 前一个 token 是 boxed（前导空格），撞名豁免不触发，残留 graph→cli 假边
/// （引擎自身 lock.cj 的 `var result: Option<T>` 同理，迷你仓二分实证）。
@Test
func testArchRefEdgesReceiverCallUsesOwnLeadingFlag(): Unit {
    let root = writeArchFixTree()
    try {
        writeFileAtomic("${root}/graph/recv.cj", """
package moongit.graph

public func recvCaller(boxed: Box): Int64 {
    let v = boxed.T()
    return archSymAlpha()
}
""")
        let g = buildGraph(root)
        // 前提：真调用与真类型依赖幸存（扫描在跑、判据①的顶格公开入口有效）
        @Assert(hasEdge(g.archRefEdges, "graph/recv.cj", "util/hosta.cj"))
        @Assert(hasEdge(g.archRefEdges, "graph/recv.cj", "util/box.cj"))
        // `boxed.T()` 的 T 是接收者调用（前导点属于自己的标志），不撞
        // cli/lang.cj 的翻译函数 T
        @Assert(!hasEdge(g.archRefEdges, "graph/recv.cj", "cli/lang.cj"))
    } finally {
        removeTree(root)
    }
}

// MARK: - arch 链路第二阶段：renderArchHtml 两段拆分（archJson 字符串 + 模板）

/// renderArchHtml（模板段，吃 archJson 字符串）与 archCanvasHtml（旧签名 = 两段组合）：
///   · 组合兼容：旧签名产物 == renderArchHtml(Json.pretty(archJson(...)))——
///     `graph arch --format html` 行为不变（只打印不落盘）
///   · 确定性：同一份 JSON 两次渲染逐字节一致
///   · round-trip（meta/坐标在）：持久化 payload（archJson 全量 + meta 包装）
///     渲染时内嵌复用判定标记，renderIndexEmbeddedUpdateCount / GeneratedAt
///     读得回（与 index 渲染同一对读写）；兼容面临时 JSON 无 updateCount
///     → 无标记（旧产物形状不变）
@Test
func testRenderArchHtmlTwoSegmentRoundTrip(): Unit {
    let root = writeTree()
    try {
        let arch = buildArch(buildGraph(root))
        layoutArch(arch)
        let json = Json.pretty(archJson(arch, false))
        // 组合兼容：旧签名 == 两段组合（模板段不吃 ArchData，只吃字符串）
        let legacy = archCanvasHtml(arch, false)
        @Assert(legacy == renderArchHtml(json, false))
        // 确定性：同输入逐字节一致
        @Assert(renderArchHtml(json, false) == renderArchHtml(json, false))
        // 坐标在页面里：布局已算好，内嵌 JSON 带 lanes（泳道矩形）与模块 x/y
        @Assert(legacy.contains("\"lanes\""))
        @Assert(legacy.contains("\"x\""))
        // 兼容面：临时 JSON 无 updateCount → 无复用标记（graph arch 产物形状不变）
        @Assert(!legacy.contains("moongit arch render"))
        // round-trip（meta 在）：archJson 全量 + meta 包装 → 标记可读回
        let stored = Json.parse(json).getOrThrow()
        Json.set(stored, "probe", SourceProbe(1, 2, 3).toJson())
        Json.set(stored, "updateCount", Json.of(7))
        Json.set(stored, "generatedAt", Json.of("2026-10-12T00:00:00Z"))
        Json.set(stored, "en", Json.of(false))
        let html = renderArchHtml(Json.pretty(stored), false)
        match (renderIndexEmbeddedUpdateCount(html)) {
            case Some(n) => @Assert(n == 7)
            case None => @Assert(false)   // 无标记 = 读取器与写入器脱钩，当场红
        }
        @Assert(renderIndexEmbeddedGeneratedAt(html) == "2026-10-12T00:00:00Z")
        // meta 键不改变绘图数据：modules/lanes 原样内嵌
        @Assert(html.contains("\"lanes\""))
        // 双语两面（模板文案与内嵌数据同语言面；ArchUi 单一来源）
        @Assert(legacy.contains("技术架构"))
        @Assert(archCanvasHtml(arch, true).contains("Architecture"))
    } finally {
        removeTree(root)
    }
}


/// 测试用引号字面量（避免在仓颉源码里写转义引号——上一版的 \\" 序列
/// 直接是非法 token，测试目标编译失败）。
func jsStrForTestQuote(): String {
    let out = ArrayList<UInt8>()
    out.add(34)
    return fromUtf8Lossy(out.toArray())
}

// ── 职责分层（技术深度）：分类器 / 聚合 / JSON 出口 / HTML 消费 ──

/// 分类器：真实仓库文件名逐个钉住。规则按优先级排序——
/// SettingsSheet 命中界面（Sheet 后缀）而不是数据（Settings）；
/// SessionStore 命中存储（Store）而不是服务；AppDelegate 是入口。
@Test
func testFileRoleClassification(): Unit {
    // 入口
    @Assert(fileRole("Sources/d2note/main.swift") == ROLE_ENTRY)
    @Assert(fileRole("Sources/d2note/AppDelegate.swift") == ROLE_ENTRY)
    @Assert(fileRole("app/App.ts") == ROLE_ENTRY)
    // 界面（优先于数据词：SettingsSheet 不是配置模型）
    @Assert(fileRole("Sources/d2note/EditorTextView.swift") == ROLE_UI)
    @Assert(fileRole("Sources/d2note/SettingsSheet.swift") == ROLE_UI)
    @Assert(fileRole("src/CommandPalette.ts") == ROLE_UI)
    @Assert(fileRole("src/Theme.swift") == ROLE_UI)
    // 存储（优先于服务词：SessionStore 不是 session 服务）
    @Assert(fileRole("Sources/d2note/SessionStore.swift") == ROLE_STORAGE)
    @Assert(fileRole("src/cache.rs") == ROLE_STORAGE)
    // 服务
    @Assert(fileRole("Sources/d2note/TranslateService.swift") == ROLE_SERVICE)
    @Assert(fileRole("Sources/d2note/SuggestionEngine.swift") == ROLE_SERVICE)
    // 数据
    @Assert(fileRole("Sources/d2note/EditorDocument.swift") == ROLE_MODEL)
    @Assert(fileRole("Sources/d2note/SourceLanguage.swift") == ROLE_MODEL)
    // 支撑
    @Assert(fileRole("Sources/d2note/Highlighter.swift") == ROLE_SUPPORT)
    @Assert(fileRole("Sources/d2note/Formatter.swift") == ROLE_SUPPORT)
    // 其他（无任何职责词命中——如实落「其他」，不硬编）
    @Assert(fileRole("Sources/d2note/SampleContent.swift") == ROLE_OTHER)
    @Assert(fileRole("Package.swift") == ROLE_OTHER)
}

/// 角色违规判定：低秩依赖高秩（数据→界面、存储→服务）= 违规；
/// 「其他」两侧都不判（坐标系之外，同模块层 4 的 M12 教训）。
@Test
func testRoleViolationDirection(): Unit {
    @Assert(isRoleViolation(ROLE_MODEL, ROLE_UI))          // 数据 → 界面 = 逆流
    @Assert(isRoleViolation(ROLE_STORAGE, ROLE_SERVICE))   // 存储 → 服务 = 逆流
    @Assert(!isRoleViolation(ROLE_UI, ROLE_SERVICE))       // 界面 → 服务 = 健康下行
    @Assert(!isRoleViolation(ROLE_ENTRY, ROLE_UI))         // 入口 → 界面 = 健康
    @Assert(!isRoleViolation(ROLE_OTHER, ROLE_UI))         // 其他不参与
    @Assert(!isRoleViolation(ROLE_UI, ROLE_OTHER))         // 同上
}

/// 聚合不变量：标准夹具上
///   ① roles 恒 7 组（空角色也在，files=0）；
///   ② Σ roleMix == Σ role files == 总文件数（一个文件恰归一个角色）；
///   ③ 模块 roleMix 桶数恒 7（消费方按桶画比例，键集不漂）；
///   ④ 入口文件被记录（夹具有 main 入口形态的文件则非空，这里只验形状）。
@Test
func testRoleAggregationInvariants(): Unit {
    let root = writeTree()
    try {
        let arch = buildArch(buildGraph(root))
        @Assert(arch.roles.size == ROLE_COUNT)
        var roleFileSum: Int64 = 0
        for (g in arch.roles) { roleFileSum += g.files }
        @Assert(roleFileSum == arch.totalFiles)
        var mixSum: Int64 = 0
        for (m in arch.modules) {
            @Assert(m.roleMix.size == ROLE_COUNT)
            for (c in m.roleMix) { mixSum += c }
        }
        @Assert(mixSum == arch.totalFiles)
        // 代表文件：非空角色的 topFiles 不超过 8，且都是真实路径（行数降序裁剪）
        for (g in arch.roles) {
            @Assert(g.topFiles.size <= 8)
            @Assert(g.topFiles.size <= g.files)
        }
        // 职责视图布局：非空角色卡有坐标，空角色坐标为 0（不画）
        var laidOut = 0
        for (g in arch.roles) {
            if (g.files > 0) {
                laidOut += 1
                @Assert(g.w > 0.0)
            }
        }
        @Assert(laidOut > 0)
    } finally {
        removeTree(root)
    }
}

/// archJson 职责出口恒发（空仓库给空数组——缺键会被消费方读成旧版本）；
/// 模块对象带 7 桶 roleMix；角色卡带 id（驱动 findNode/依赖面板按 id 找节点）。
@Test
func testArchJsonCarriesRoleView(): Unit {
    let root = writeTree()
    try {
        let arch = buildArch(buildGraph(root))
        let j = archJson(arch, false)
        @Assert(Json.has(j, "roles"))
        @Assert(Json.has(j, "roleLanes"))
        @Assert(Json.has(j, "roleEdges"))
        @Assert(Json.has(j, "roleViolations"))
        @Assert(Json.intAt(j, "roleViolations", -1) >= 0)
        var roleWithId = 0
        for (r in Json.arrAt(j, "roles")) {
            @Assert(Json.has(r, "id"))
            roleWithId += 1
        }
        @Assert(roleWithId > 0)
        for (m in Json.arrAt(j, "modules")) {
            @Assert(Json.arrAt(m, "roleMix").size == ROLE_COUNT)
            @Assert(Json.has(m, "entryFiles"))
        }
    } finally {
        removeTree(root)
    }
}

/// 驱动消费半边：交互 HTML 必须真的读职责数据——视图切换 chips、
/// 角色泳道（roleLanes）、角色边、边信号规范化（violation → viol）。
/// 键在数据里、页面不读 = 数据显示没算（不变量 17 的教训）。
@Test
func testArchHtmlConsumesRoleView(): Unit {
    let root = writeTree()
    try {
        let html = archCanvasHtml(buildArch(buildGraph(root)), false)
        // 切换 chips 与驱动接线
        @Assert(html.contains("vchip"))
        // HTML 里该属性由模板写成 data-view="role"（引号是字面量的一部分）
        @Assert(html.contains("data-view=" + jsStrForTestQuote() + "role" + jsStrForTestQuote()))
        // 角色泳道与角色边的消费点
        @Assert(html.contains("DATA.roleLanes"))
        @Assert(html.contains("DATA.roleEdges"))
        @Assert(html.contains("RNAMES"))
        // 边信号规范化（修 violation → viol 的键名漂移潜伏 bug）
        @Assert(html.contains("e.viol = !!e.violation"))
    } finally {
        removeTree(root)
    }
}
