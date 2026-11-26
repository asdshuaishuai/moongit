// archfix_dendro_test.cj —— 从图谱包的 archfix_test.cj 搬来的用例：它们断言的是 Dendro（置信度）的契约，
// 而图谱包的测试不能再引入 Dendro（cjpm：循环依赖）。用例原文未改，只换了所在的包。
// 建图、扫描这类被测能力仍是图谱包的公开接口（import cambium.graph）。

package cambium.dendro

import cambium.util.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import cambium.graph.*


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
/// scene 的 themes.{dark,light}.langs、treehtml 产物内嵌 JSON 的
/// langThemes.{dark,light}、archhtml 产物驱动 JS 的 PAL langs。
/// 它们输出形态各异（token JSON / 页面 JSON / JS 字面量），值必须同源。
@Test
func testLangThemePaletteSharedAcrossSceneTreeHtmlAndArchHtml(): Unit {
    let root = writeTree()
    try {
        let g = buildGraph(root)
        // ① scene 出口
        let scene = buildArchScene(buildArch(g), false)
        let themes = Json.getOr(scene, "themes")
        assertPaletteMatches(paletteMapOf(Json.getOr(Json.getOr(themes, "dark"), "langs")), true)
        assertPaletteMatches(paletteMapOf(Json.getOr(Json.getOr(themes, "light"), "langs")), false)
        // ② treehtml 出口：走真实产物，提取内嵌 JSON 再解 langThemes
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
        @Assert(!legacy.contains("cambium arch render"))
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
    @Assert(featureHits(codeOf("src/dendro/treehtml.cj")) == 0)       // 零手抄
}
