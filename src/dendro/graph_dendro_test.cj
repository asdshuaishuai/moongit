// graph_dendro_test.cj —— 从图谱包的 graph_test.cj 搬来的用例：它们断言的是 Dendro（置信度）的契约，
// 而图谱包的测试不能再引入 Dendro（cjpm：循环依赖）。用例原文未改，只换了所在的包。
// 建图、扫描这类被测能力仍是图谱包的公开接口（import cambium.graph）。

package cambium.dendro

import cambium.util.*
import std.collection.*
import std.env.*
import std.fs.*
import std.posix.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import cambium.graph.*


@Test
func testTodoMarkerShape(): Unit {
    // ⚠️ 标记字面量**必须拼接构造**：直接写出「注释开头的标记」会被本检测器
    // 扫到自己的测试数据（`AGENTS.md` 不变量 55：needle 字面量在源码里 ⇒ 匹配到自己）。
    let td = "TO" + "DO"
    let fx = "FIX" + "ME"
    let hk = "HA" + "CK"
    let xx = "X" + "XX"
    // 可执行标记（注释开头处）
    @Assert(containsTodo("// " + td + ": fix the parser"))
    @Assert(containsTodo("//" + td + "(alice): rework"))
    @Assert(containsTodo("  # " + fx + ": broken"))
    @Assert(containsTodo("/* " + hk + ": temporary */"))
    @Assert(containsTodo("// " + xx))
    // 假阳性回归：描述性文字 / 文档里示范标记写法，都不得命中
    @Assert(!containsTodo("// 魔法数字、TODO 残留。它们单看都不致命"))
    @Assert(!containsTodo("// MARK: - ③ TODO 残留"))
    @Assert(!containsTodo("/// 只认可执行标记：`TODO:` / `TODO(owner)`"))
    @Assert(!containsTodo("let x = 1  // 正文里的 TODO 只是提及"))
    @Assert(!containsTodo("let todo = compute()"))
}


func confFixture(): String {
    let root = "${tempDirPath()}/cambium-conf-test-${getpid()}-${nowMillis()}"
    ensureDir("${root}/util")
    ensureDir("${root}/cli")
    writeFileAtomic("${root}/util/a.cj", """
package p

public func usedElsewhere(): Int64 { return 1 }

func localHelper(): Int64 { return 2 }

public func callerOfLocal(): Int64 { return localHelper() }

public func deadOne(): Int64 { return 3 }
""")
    writeFileAtomic("${root}/cli/b.cj", """
package q

public func run(): Int64 { return usedElsewhere() }
""")
    return root
}


func orphanNames(rep: ConfidenceReport): ArrayList<String> {
    let names = ArrayList<String>()
    for (f in rep.findings) {
        match (f.kind) {
            case Orphan => names.add(f.symbol)
            case _ => ()
        }
    }
    return names
}


@Test
func testOrphanIsSymbolLevel(): Unit {
    let root = confFixture()
    try {
        let rep = analyzeConfidence(buildGraph(root), false)
        let names = orphanNames(rep)
        // 定义了、全仓无任何非声明处引用 → 报
        @Assert(names.contains("deadOne"))
        // 仅在同文件内被调用 → 不算孤儿（符号级判定的关键）
        @Assert(!names.contains("localHelper"))
        // 被**别的文件**引用 → 不算孤儿
        @Assert(!names.contains("usedElsewhere"))
    } finally {
        removePathIfExists(root)
    }
}


@Test
func testLexicalDeepNestingAndMagic(): Unit {
    // 纯仓颉夹具（无 tree-sitter 语法 → 走词法路径）：验证词法路径确实产出
    // 深嵌套与魔法数，而不是只剩「超长函数」。
    let root = "${tempDirPath()}/cambium-conf-lex-${getpid()}"
    ensureDir(root)
    writeFileAtomic("${root}/deep.cj", """
package p

public func deep(): Int64 {
    if (a) {
        if (b) {
            if (c) {
                if (d) {
                    if (e) {
                        return 111
                    }
                }
            }
        }
    }
    let x = 222
    let y = 333
    return x + y
}
""")
    try {
        let rep = analyzeConfidence(buildGraph(root), false)
        var deep = false
        var magic = false
        for (f in rep.findings) {
            match (f.kind) {
                case DeepNesting => deep = true
                case MagicNumber => magic = true
                case _ => ()
            }
        }
        @Assert(deep)
        @Assert(magic)
    } finally {
        removePathIfExists(root)
    }
}


@Test
func testFindingsOrderIsTotalAndDeterministic(): Unit {
    // 旧比较器只按 (权重, file, line)：long-function(4) 与 deep-nesting(4) 在同一
    // file:line 上判等 ⇒ 保留输入序 ⇒ 不同输入序产出不同结果。全序后必须一致。
    let a = ArrayList<Finding>()
    a.add(Finding(DeepNesting, "f.cj", 10, "x", "n"))
    a.add(Finding(LongFunction, "f.cj", 10, "x", "l"))
    let b = ArrayList<Finding>()
    b.add(Finding(LongFunction, "f.cj", 10, "x", "l"))
    b.add(Finding(DeepNesting, "f.cj", 10, "x", "n"))
    sortFindings(a)
    sortFindings(b)
    @Assert(flawId(a[0].kind) == flawId(b[0].kind))
    @Assert(flawId(a[1].kind) == flawId(b[1].kind))
    // 并列时按 flawId 兜底："deep-nesting" < "long-function"
    @Assert(flawId(a[0].kind) == "deep-nesting")
}


@Test
func testScoreIsSizeInvariantAndMonotone(): Unit {
    // 关键性质：**与仓库规模无关**。同样的「每文件密度」，文件数乘 10 不该把分压下去。
    // 旧公式 `100 − 惩罚/√文件数` 恰在此处失败（惩罚随文件数线性长、√ 长更慢）。
    @Assert(confidenceScore(20, 1) == confidenceScore(200, 10))
    @Assert(confidenceScore(60, 3) == confidenceScore(600, 30))
    // 无惩罚 = 满分；极稀疏仍高分；极密趋近 0
    @Assert(confidenceScore(0, 50) == 100)
    @Assert(confidenceScore(1, 1000) >= 95)
    @Assert(confidenceScore(100000, 1) == 0)
    // 单调：惩罚越多分越低
    @Assert(confidenceScore(50, 10) > confidenceScore(150, 10))
}


@Test
func testAstDetectionIsOrderIndependent(): Unit {
    // 限流（每文件每类 6 条）与重复体「报哪一条」都取决于**处理顺序** ——
    // 而顺序来自外部 ast-grep 进程。检测必须对输入顺序不敏感（否则报哪几条是外部工具
    // 的偶然顺序决定的，既不确定也无原则）。
    let base = ArrayList<AstNode>()
    var i: Int64 = 0
    while (i < 8) {
        base.add(AstNode("f.cj", 10 + i * 3, 12 + i * 3, "fn", "func f${i}() { }"))
        i += 1
    }
    let reversed = ArrayList<AstNode>()
    var k: Int64 = 7
    while (k >= 0) {
        reversed.add(base[k])
        k -= 1
    }
    let fa = ArrayList<Finding>()
    let capA = CapDropCounter()
    detectFromAst(base, fa, capA)
    let fb = ArrayList<Finding>()
    let capB = CapDropCounter()
    detectFromAst(reversed, fb, capB)
    // 限流确实生效：8 条 stub 只留 6 条（否则下面「两者相等」会空转成恒真）
    @Assert(Int64(fa.size) == 6)
    @Assert(Int64(fb.size) == 6)
    // 丢弃计数在丢弃判定点发生：8 − 6 = 2（cappedKind 真值来源的接缝守卫——
    // counter 没接进 bumpFinding 时这条会恒 0 而上面照样全绿）
    @Assert(capA.kindDrops == 2)
    @Assert(capB.kindDrops == 2)
    var j: Int64 = 0
    while (j < Int64(fa.size)) {
        @Assert(flawId(fa[j].kind) == flawId(fb[j].kind))
        @Assert(fa[j].line == fb[j].line)
        j += 1
    }
    // 按位置取前 6 条（行号 10,13,…,25）
    @Assert(fa[0].line == 10)
    @Assert(fa[5].line == 25)
}




// MARK: - 补丁级置信度（三层）

@Test
func testParseUnifiedDiff(): Unit {
    let diff = "--- a/x.c\n+++ b/x.c\n@@ -1,2 +1,3 @@\n ctx\n-old\n+new1\n+new2\n"
    let (files, errs) = parseUnifiedDiff(diff)
    @Assert(errs == 0)
    @Assert(Int64(files.size) == 1)
    @Assert(files[0].newPath == "x.c")
    var added: Int64 = 0
    for (pl in files[0].lines) {
        if (pl.kind == 1) { added += 1 }
    }
    @Assert(added == 2)
    // 新增行行号：new1 在 +1 起 hunk 的第 2 行（ctx 后）
    var firstAdd: Int64 = -1
    for (pl in files[0].lines) {
        if (pl.kind == 1) { firstAdd = pl.newNo; break }
    }
    @Assert(firstAdd == 2)
}


@Test
func testPatchConfidenceLayers(): Unit {
    let root = writeTree()
    let graph = buildGraph(root)
    try {
        // patch：调用了存在的 Text（解析）+ 不存在的幻觉 fn（未解析）
        let diff = "--- a/flow/update.cj\n+++ b/flow/update.cj\n@@ -1,3 +1,7 @@\n" +
            " package cambium.flow\n+\n+public func patchHelper(t: Text): Bool {\n" +
            "+    let ok = t.trimAll(\"x\")\n+    return ok && ghost_fn(t)\n+}\n"
        let pc = analyzePatchConfidence(graph, diff)
        // S1 部分（有解析也有未解析）
        @Assert(pc.overall > 0.0 && pc.overall < 1.0)
        // 幻觉调用进 uncertain
        var hasGhost = false
        for (u in pc.uncertain) {
            if (uncId(u.kind) == "unresolved_call" && u.id.contains("ghost_fn")) { hasGhost = true }
        }
        @Assert(hasGhost)
        // entity：patchHelper 被识别
        var hasEntity = false
        for (e in pc.entities) {
            if (e.name == "patchHelper") { hasEntity = true }
        }
        @Assert(hasEntity)
        // S7 恒 null（词法层如实披露）
        @Assert(pc.nullSignals.contains("S7"))

        // Layer 3：合并（agent 裁决 resolved/unresolved/deferred 三态）
        let alg = patchConfidenceJson(pc)
        let ag = Json.parse("{\"items\": [{\"id\": \"x\", \"verdict\": \"resolved\", \"confidence\": 1.0}]}").getOrThrow()
        match (mergePatchConfidence(alg, ag)) {
            case Some(m) =>
                // x 不在 uncertain → deferred（agent 处理了不存在的项不影响）
                @Assert(m.overall >= 0.0)
                var hasDeferred = false
                for (e in m.entities) {
                    if (Json.strAt(e, "source", "") == "deferred") { hasDeferred = true }
                }
                @Assert(hasDeferred)   // ghost_fn 项没人裁决 → deferred
            case None => @Assert(false)
        }
    } finally {
        removeTree(root)
    }
}


// MARK: - 审查回归（audit-2026-10-09）

/// H1：一个声明只能生成**一个** entity。原实现把 entities.add 写在「前窥 15 行」
/// 的 while 体内 ⇒ 声明后每跟一行非声明代码就多一个同 id 的 entity；而声明紧跟
/// 另一声明行（首轮即 break）时一条都不生成。测试原先只断言 hasEntity，
/// 两种错都兜不住。
@Test
func testPatchEntityIsOnePerDeclaration(): Unit {
    let root = writeTree()
    try {
        let graph = buildGraph(root)
        let diff = "--- a/flow/update.cj\n+++ b/flow/update.cj\n@@ -1,3 +1,10 @@\n" +
            " package cambium.flow\n+\n+public func patchHelper(t: Text): Bool {\n" +
            "+    let a = 1\n+    let b = 2\n+    return second(t)\n+}\n" +
            "+public func second(t: Text): Bool {\n+    return true\n+}\n"
        let pc = analyzePatchConfidence(graph, diff)
        var n1: Int64 = 0
        var n2: Int64 = 0
        for (e in pc.entities) {
            if (e.name == "patchHelper") { n1 += 1 }
            if (e.name == "second") { n2 += 1 }
        }
        // 3 行函数体 ⇒ 恰好一个（不是 3 个）
        @Assert(n1 == 1)
        // 紧跟在前一个声明之后的声明：原先一条都不生成
        @Assert(n2 == 1)
        @Assert(pc.totalEntities == 2)
        // 前窥行不得重复计入统计：patchHelper 体内恰有一个自由调用 second(t)，
        // totalRelations（= totalRefs）必须恰好是 1 —— 前窥重复统计的旧缺陷会让它变 2
        // （原断言 `x == A || x >= 0` 后一析取恒真，什么都没钉——复审 2026-10-10）
        @Assert(pc.totalRelations == 1)
        // 前向引用只走 use-before-def 一条通道：不再同时记 unresolved_call（双罚）
        var ubd: Int64 = 0
        var unresSecond: Int64 = 0
        for (u in pc.uncertain) {
            if (uncId(u.kind) == "use_before_def") { ubd += 1 }
            if (uncId(u.kind) == "unresolved_call" && u.id.contains("second")) { unresSecond += 1 }
        }
        @Assert(ubd == 1)
        @Assert(unresSecond == 0)
    } finally {
        removeTree(root)
    }
}


/// H1 的另 half：同一行引用不得产生两条重复 uncertain ——
/// 合并器（mergePatchConfidence）逐条把 uncertain 计入 conf 均值，重复即双算。
@Test
func testPatchUncertainHasNoDuplicates(): Unit {
    let root = writeTree()
    try {
        let graph = buildGraph(root)
        let diff = "--- a/flow/update.cj\n+++ b/flow/update.cj\n@@ -1,3 +1,7 @@\n" +
            " package cambium.flow\n+\n+public func patchHelper(t: Text): Bool {\n" +
            "+    let ok = t.trimAll(\"x\")\n+    return ok && ghost_fn(t)\n+}\n"
        let pc = analyzePatchConfidence(graph, diff)
        var ghost: Int64 = 0
        for (u in pc.uncertain) {
            if (uncId(u.kind) == "unresolved_call" && u.id.contains("ghost_fn")) { ghost += 1 }
        }
        @Assert(ghost == 1)
    } finally {
        removeTree(root)
    }
}


/// H2：use-before-def 必须真的能触发。原实现用「扫到第 N 行时已知」的 patchDecls
/// 判「声明在后」，条件 n2 > pl.newNo 永假 ⇒ UUseBeforeDef 一条不产生、
/// S5 恒为 1.0 虚抬 overall 约 1/10 标度。
@Test
func testPatchUseBeforeDefFires(): Unit {
    let root = writeTree()
    try {
        let graph = buildGraph(root)
        // 先调用 later()，后声明 later() —— 同一文件内 use-before-def
        let diff = "--- a/flow/update.cj\n+++ b/flow/update.cj\n@@ -1,3 +1,8 @@\n" +
            " package cambium.flow\n+\n+public func patchHelper(t: Text): Bool {\n" +
            "+    return later(t)\n+}\n+\n+public func later(t: Text): Bool {\n" +
            "+    return true\n+}\n"
        let pc = analyzePatchConfidence(graph, diff)
        var ubd: Int64 = 0
        for (u in pc.uncertain) {
            if (uncId(u.kind) == "use_before_def" && u.id.contains("later")) { ubd += 1 }
        }
        @Assert(ubd >= 1)
    } finally {
        removeTree(root)
    }
}


/// H2 负向：先声明后使用不得报 use-before-def（否则这条信号变成噪音，
/// 每条 patch 都被判「先用后声明」）。
@Test
func testPatchDeclaredBeforeUseIsNotFlagged(): Unit {
    let root = writeTree()
    try {
        let graph = buildGraph(root)
        let diff = "--- a/flow/update.cj\n+++ b/flow/update.cj\n@@ -1,3 +1,8 @@\n" +
            " package cambium.flow\n+\n+public func early(t: Text): Bool {\n" +
            "+    return true\n+}\n+\n+public func patchHelper(t: Text): Bool {\n" +
            "+    return early(t)\n+}\n"
        let pc = analyzePatchConfidence(graph, diff)
        for (u in pc.uncertain) {
            @Assert(!(uncId(u.kind) == "use_before_def" && u.id.contains("early")))
        }
    } finally {
        removeTree(root)
    }
}


// MARK: - 审查回归（audit-2026-10-09）：置信度渲染层

/// M5：渲染层原先**零测试**。三个出口（text/json/llmPrompt）里最容易烂掉的是
/// 「披露字段还在不在」—— 而它没有任何断言盯着。这里用一份手搓报告钉住形状。
private func confReportFixture(astUsed: Bool, astNote: String): ConfidenceReport {
    let findings = ArrayList<Finding>()
    findings.add(Finding(MagicNumber, "a.cj", 3, "v", "17"))
    findings.add(Finding(TodoResidue, "a.cj", 9, "w", "TODO"))
    let byKind = ArrayList<(FlawKind, Int64)>()
    byKind.add((MagicNumber, 1))
    byKind.add((TodoResidue, 1))
    let files = ArrayList<(String, Int64)>()
    // 罚分降序（analyzeConfidence 的既有约定）
    files.add(("b.cj", 7))
    files.add(("a.cj", 4))
    let dims = ArrayList<(ConfDimension, Int64, Int64, Int64)>()
    dims.add((DimStructure, 4, 2, 90))
    return ConfidenceReport("/tmp/x", 88, findings, astUsed, astNote, 2, byKind, files, dims)
}


/// M4 + M5：JSON 出口的键集必须稳定，且两个「files」不许互相覆盖。
/// 原实现把罚分表和 filesAnalyzed 都写成 "files" —— Json.set 同键就地覆盖，
/// 于是罚分表在 JSON 出口里被静默丢掉（MCP codegraph_confidence 同源）。
@Test
func testConfidenceJsonKeySetIsStable(): Unit {
    let j = confidenceJson(confReportFixture(true, "ast-grep 已启用"))
    for (k in ["root", "score", "dimensions", "penaltyByFile", "findings", "byKind", "astUsed", "astNote", "filesAnalyzed", "semantics",
        "cappedKind", "cappedTotal", "findingsTotal", "penaltyTotal", "coverage"]) {
        @Assert(Json.has(j, k))
    }
    // 覆盖面七键恒发（结构化版 astNote）
    let cov = Json.getOr(j, "coverage")
    for (k in ["astFiles", "lexicalFiles", "astBatchesTotal", "astBatchesFailed", "kindsDropped", "nodesDropped", "kindsUnavailable"]) {
        @Assert(Json.has(cov, k))
    }
    // 罚分表必须真的在（不被 filesAnalyzed 覆盖）
    let pf = Json.arrAt(j, "penaltyByFile")
    @Assert(Int64(pf.size) == 2)
    @Assert(Json.strAt(pf[0], "file", "") == "b.cj")
    @Assert(Json.intAt(pf[0], "penalty", 0) == 7)
    @Assert(Json.intAt(j, "filesAnalyzed", 0) == 2)
    // 旧的 "files" 键不许以数组形态回来（那说明有人改回去了）
    match (Json.get(j, "files")) {
        case Some(JArr(_)) => @Assert(false)
        case _ => ()
    }
}


/// ast-grep 的探测顺序：环境变量 CAMBIUM_AST_GREP → PATH → 用户目录常见位置 → 系统级固定路径。
/// 原先只查 4 个固定路径、不查 PATH：cargo / npm 装的（没有 root 时的唯一装法）引擎看不到，装了也白装。
/// 这里把三级各自钉住；环境变量在 finally 里逐个还原，不污染同进程后续用例。
@Test
func testFindAstGrepSearchesPathThenHomeThenEnv(): Unit {
    let base = "/tmp/dendro-astgrep-${nowMillis()}"
    let bin = base + "/bin"
    let home = base + "/home"
    ensureDir(bin)
    ensureDir(home + "/.local/bin")
    writeFileAtomic(bin + "/ast-grep", "#!/bin/sh\nexit 0\n")
    writeFileAtomic(home + "/.local/bin/ast-grep", "#!/bin/sh\nexit 0\n")
    let savedPath = getVariable("PATH")
    let savedHome = getVariable("HOME")
    let savedEnv = getVariable("CAMBIUM_AST_GREP")
    try {
        // 环境变量空串 = 没设（不许把空串当成路径）
        setVariable("CAMBIUM_AST_GREP", "")
        // ① PATH：放在最前面，压过机器上可能已装的 ast-grep
        setVariable("PATH", bin + ":" + savedPath.getOrThrow())
        @Assert(findAstGrep() == Some(bin + "/ast-grep"))
        // ② PATH 上没有 → 用户目录的常见安装位置
        setVariable("PATH", base + "/no-bin")
        setVariable("HOME", home)
        @Assert(findAstGrep() == Some(home + "/.local/bin/ast-grep"))
        // ③ 环境变量最优先，且两端空白去掉
        setVariable("CAMBIUM_AST_GREP", "  " + bin + "/ast-grep ")
        @Assert(findAstGrep() == Some(bin + "/ast-grep"))
        // PATH 的空目录段不当当前目录：cwd 上有同名文件也不算装了
        setVariable("CAMBIUM_AST_GREP", "")
        setVariable("HOME", base + "/empty-home")
        setVariable("PATH", savedPath.getOrThrow() + "::" + base + "/no-bin")
        @Assert(findAstGrep() != Some("ast-grep"))
    } finally {
        // 进程里原先没设过的变量，还原成空串（std.env 没有取消设置的接口；空串一律按「没设」读）
        setVariable("CAMBIUM_AST_GREP", savedEnv.getOrDefault { "" })
        setVariable("HOME", savedHome.getOrDefault { "" })
        setVariable("PATH", savedPath.getOrDefault { "" })
        removePathIfExists(base)
    }
}

/// 规则里的节点种类要拿 ast-grep 本人验证：各版本的 tree-sitter 语法节点名会变，
/// 规则里混进一个不认的种类，整份规则被拒 ⇒ 这一语言的语法树信号全丢
/// （实测：Swift 的 struct_declaration / enum_declaration 在 0.51 上不认，Swift 那一批整个失败）。
/// 用一个「见到 struct_declaration 就拒绝」的假 ast-grep 钉住剔除与披露。
@Test
func testAstKindsAreValidatedAgainstTheInstalledAstGrep(): Unit {
    let base = "/tmp/dendro-astkinds-${nowMillis()}"
    ensureDir(base)
    let fake = base + "/fake-sg"
    writeFileAtomic(fake, "#!/bin/sh\n# 规则文件是第 3 个参数；含 struct_declaration 就拒绝（= 本版不认这个节点）\ngrep -qE \"struct_declaration|enum_declaration\" \"$3\" && exit 8\nexit 0\n")
    let _ = execCapture("/bin/chmod", ["755", fake], Option<String>.None, 10000)
    AST_DROPPED_KINDS.clear()
    try {
        let ok = validKinds(fake, "swift", "Swift", ["function_declaration", "struct_declaration", "class_declaration"])
        @Assert(ok.size == 2)
        @Assert(ok[0] == "function_declaration")
        @Assert(ok[1] == "class_declaration")
        @Assert(AST_DROPPED_KINDS.size == 1)
        @Assert(AST_DROPPED_KINDS[0] == "swift.struct_declaration")
        // 生成的规则里不再出现被剔除的种类，认得的照样在
        AST_DROPPED_KINDS.clear()
        let yml = rulesYamlFor(fake, "swift")
        @Assert(!yml.contains("struct_declaration"))
        @Assert(!yml.contains("enum_declaration"))
        @Assert(yml.contains("kind: function_declaration"))
        @Assert(yml.contains("kind: class_declaration"))
        @Assert(yml.contains("kind: catch_block"))
        @Assert(yml.contains("language: Swift"))
        // 同一条规则里的多个种类用「任一」并列；三条规则之间用文档分隔符隔开
        @Assert(yml.contains("  any:\n    - kind: function_declaration"))
        @Assert(yml.split("---\n").size == 3)
    } finally {
        cleanupAstTmpDirs()
        AST_DROPPED_KINDS.clear()
        removePathIfExists(base)
    }
}

/// M5 + M2：降级披露必须出现在**每一个**出口。
/// 原实现 README 承诺 astNote 降级披露，却没有一条测试钉住它。
@Test
func testConfidenceDegradedNoteAppearsInEveryExit(): Unit {
    let degraded = confReportFixture(false, "ast-grep 不可用，已降级为词法分析")
    let t = confidenceText(degraded)
    @Assert(t.contains("已降级"))
    let j = Json.pretty(confidenceJson(degraded))
    @Assert(j.contains("已降级"))
    let p = confidenceLlmPrompt(degraded, "demo")
    @Assert(p.contains("词法"))
    // 三个出口都要说出「这不是全量」
    @Assert(t.contains("ast-grep"))
    @Assert(j.contains("astUsed"))
    @Assert(p.contains("词法"))
}


/// M5：文本出口必须报分母（分析几个文件）与语义边界。
@Test
func testConfidenceTextStatesScopeAndBoundary(): Unit {
    let t = confidenceText(confReportFixture(true, "ast-grep 已启用"))
    @Assert(t.contains("分析 2 文件"))
    @Assert(t.contains("不是正确性证明"))
    @Assert(t.contains("分数"))
}


/// M5：LLM 提示词必须按维度分节，且每条带证据。
@Test
func testConfidenceLlmPromptGroupsByDimension(): Unit {
    let p = confidenceLlmPrompt(confReportFixture(true, "ast-grep 已启用"), "demo")
    @Assert(p.contains("项目：demo"))
    @Assert(p.contains("## 预检维度分"))
    @Assert(p.contains("结构"))
    @Assert(p.contains("证据："))
    // 红线必须在（不许只复读预检结论）
    @Assert(p.contains("红线"))
    @Assert(p.contains("## 输出格式"))
}


/// M3 回归：C/C++ 的 opaque 前置声明不许被报成「空类型」。
/// ast-grep 对 `struct Fwd;` / `typedef struct Fwd FwdT;` 都跨 1 行命中 type 规则，
/// 而判据 `methods == 0 && lines <= 3` 把每个前置声明都扣 3 分 ——
/// opaque forward decl 是 C 头文件的惯用法，系统性拖低 C/C++ 仓库分数。
@Test
func testForwardDeclarationIsNotReportedAsEmptyType(): Unit {
    // ⚠️ 必须用**真实 CST 形态**：tree-sitter 的 `;` 是 struct_specifier 的兄弟节点，
    // ast-grep 命中的 text 是 `struct Fwd`——**不带分号**。旧测试手写 "struct Fwd;"
    // （集成中不会出现的输入），把恒假的死代码判据 endsWith(";") 钉成了绿的
    // （复审 2026-10-10）。
    @Assert(isForwardDeclaration("struct Fwd"))
    @Assert(isForwardDeclaration("typedef struct Fwd FwdT"))
    // 整行文本（带分号）同样要认得
    @Assert(isForwardDeclaration("struct Fwd;"))
    // 有成员表就不是前置声明；真正的空类型仍然要报（判据不许放宽到恒真）
    @Assert(!isForwardDeclaration("struct Empty { }"))
    @Assert(!isForwardDeclaration("struct Empty {}"))

    let nodes = ArrayList<AstNode>()
    // 真实 CST 形态：不带分号
    nodes.add(AstNode("a.h", 3, 3, "type", "struct Fwd"))
    nodes.add(AstNode("a.h", 4, 4, "type", "struct Fwd"))   // typedef 内层的 struct_specifier
    nodes.add(AstNode("a.cj", 5, 5, "type", "struct Empty {}"))
    let findings = ArrayList<Finding>()
    detectTypeSignals(nodes, findings)
    var reported = ArrayList<String>()
    for (f in findings) {
        if (flawId(f.kind) == "empty-type") { reported.add(f.symbol) }
    }
    @Assert(reported.size == 1)
    @Assert(reported[0] == "Empty")

    // M3 同族漏网（终审实测）：stub 判定也不许抓前置声明——EmptyType 修了，
    // StubBody 从另一个出口继续误报
    let stubNodes = ArrayList<AstNode>()
    stubNodes.add(AstNode("a.h", 3, 3, "type", "struct Fwd"))
    let stubFindings = ArrayList<Finding>()
    detectFromAst(stubNodes, stubFindings, CapDropCounter())
    for (f in stubFindings) {
        @Assert(f.symbol != "Fwd")
    }
}


/// 终审漏网回归：.c 临时副本的路径映回不许产生双重扩展名。
/// 实测：同一份报告里词法路径 findings 是 t.c、AST 路径却是 t.c.c——
/// 编码名已含 .c，还原后再拼一次 ".c" 就重复。
@Test
func testCAstPathMapsBackWithoutDoubleExtension(): Unit {
    // 编码可逆且无碰撞（旧 "/"→"__" 方案的两个碰撞源）
    @Assert(unsanitizePathName(sanitizePathToName("t.c")) == "t.c")
    @Assert(unsanitizePathName(sanitizePathToName("a/b.c")) == "a/b.c")
    @Assert(unsanitizePathName(sanitizePathToName("a%2Fb.c")) == "a%2Fb.c")
    @Assert(unsanitizePathName(sanitizePathToName("a__b.c")) == "a__b.c")
    @Assert(sanitizePathToName("a/b.c") != sanitizePathToName("a__b.c"))

    // parseOneAstNode 的映回走全链路
    let savedScan = AST_SCAN_ROOT
    let savedCpp = C_AS_CPP_ROOT
    try {
        AST_SCAN_ROOT = "/tmp/fake-root"
        C_AS_CPP_ROOT = "/tmp/cambium-c-as-cpp-999"
        let item = Json.obj()
        Json.set(item, "file", Json.of("/tmp/cambium-c-as-cpp-999/sub%2Ft.c.cpp"))
        Json.set(item, "ruleId", Json.of("fn"))
        Json.set(item, "text", Json.of("int f(void) { return 0; }"))
        let start = Json.obj()
        Json.set(start, "line", Json.of(1))
        Json.set(start, "column", Json.of(0))
        let end = Json.obj()
        Json.set(end, "line", Json.of(1))
        Json.set(end, "column", Json.of(20))
        let range = Json.obj()
        Json.set(range, "start", start)
        Json.set(range, "end", end)
        Json.set(item, "range", range)
        let out = ArrayList<AstNode>()
        parseOneAstNode(item, out)
        @Assert(out.size == 1)
        @Assert(out[0].file == "sub/t.c")
    } finally {
        AST_SCAN_ROOT = savedScan
        C_AS_CPP_ROOT = savedCpp
    }
}


/// 代码图谱的 Web 导出（与 arch 同纪律：引擎单独跑或被 agent 驱动时
/// 只产出本 HTML，无其他渲染通道；绘制一律走平台 Canvas API 公共子集）。
/// 内嵌数据必须就是 `graph tree --json` 的同一份契约。
/// 2026-10-11 三轮重构：三个并列 tab（模块/调用树/热力图）合并为单一
/// 「代码图谱」画布——热力呈现就是代码图谱本身的着色系统，不再是独立视图。
/// 旧断言 `data-view="graph"` / `data-view="heat"`（顶栏三按钮）随形态
/// **显式退役**（不是漏改）：并列视图分发没有了，单画布以
/// `data-canvas="codegraph"` 标记钉住。
@Test
func testTreeCanvasHtmlExport(): Unit {
    let root = writeTree()
    try {
        let g = buildGraph(root)
        let conf = analyzeConfidence(g, false)
        let html = treeCanvasHtml(g, 8, false, conf)
        // 单画布版：codegraph 标记 / 旧视图按钮不得残留 / 侧栏 / 数据内嵌
        // （2026-10-12 参考稿重设计：详情侧栏从 data-pane 分隔条布局改为
        // .sidebar 固定栅格——data-pane 标记随之显式退役）
        @Assert(html.contains("data-canvas=\"codegraph\""))
        @Assert(!html.contains("data-view="))
        @Assert(!html.contains("vtabs"))
        @Assert(html.contains("class=\"sidebar\""))
        @Assert(html.contains("<canvas"))
        @Assert(html.contains("CambiumCodeGraph") || html.contains("functionEdges"))
        @Assert(html.contains("referenceEdges"))
        @Assert(html.contains("archRefEdges"))
        @Assert(html.contains("depthOmitted"))
        @Assert(html.contains("codeSnippets"))
        @Assert(html.contains("confidence"))
        @Assert(html.contains("langThemes"))
        @Assert(!html.contains("<script src"))
    } finally {
        removeTree(root)
    }
}


/// 树形交付物的**样式契约**：保证「下一次引擎生成的代码图谱和现在的一样」。
/// 三层锁：
///   ① 确定性——同一项目两次生成交付物逐字节一致（引擎承诺的可复现性）；
///   ② 样式锁定——**不同项目**的 <style> 块与驱动 JS 必须完全相同
///      （样式/交互只由引擎代码决定，不随数据漂移；改样式 = 必须过这条测试）；
///   ③ 结构标记——本轮定稿的设计决策逐项钉死（pill 徽标 / 过滤态覆盖表 /
///      L0 锚点行 / 档位色 / 命中高亮 / 置信度 tab），以及 finding 数据契约
///      （label/dim/evidence 六字段，树节点内嵌与 confidence 内嵌同口径）。
@Test
func testTreeHtmlStyleContract(): Unit {
    func extractBlock(html: String, open: String, close: String, last: Bool): String {
        var a = -1
        var from = 0
        while (true) {
            let hit = indexOfStrFrom(html, open, from)
            if (hit < 0) { break }
            a = hit
            from = hit + open.size
            if (!last) { break }
        }
        if (a < 0) { return "" }
        let bodyFrom = a + open.size
        let b = indexOfStrFrom(html, close, bodyFrom)
        if (b < 0) { return "" }
        // 边界都是 ASCII 标签，UTF-8 切片安全
        return html[bodyFrom..b]
    }

    let root1 = writeTree()
    let root2 = testRoot()
    try {
        // 第二个 fixture：不同目录结构 + 不同语言（ts），代表「另一个项目」
        ensureDir("${root2}/src")
        writeFileAtomic("${root2}/src/only.ts",
            "export function one(a: number): number { return a + 1; }\n")
        let g1 = buildGraph(root1)
        let g2 = buildGraph(root2)

        // ① 确定性：同输入两次生成逐字节一致
        let htmlA = treeCanvasHtml(g1, 8, false, analyzeConfidence(g1, false))
        let htmlB = treeCanvasHtml(g1, 8, false, analyzeConfidence(g1, false))
        @Assert(htmlA == htmlB)

        // ② 样式锁定：不同项目的 <style> 与驱动 JS（最后一个 <script>）完全相同
        let html2 = treeCanvasHtml(g2, 8, false, analyzeConfidence(g2, false))
        let css1 = extractBlock(htmlA, "<style>", "</style>", false)
        let css2 = extractBlock(html2, "<style>", "</style>", false)
        @Assert(css1 != "")
        @Assert(css1 == css2)
        let js1 = extractBlock(htmlA, "<script>", "</script>", true)
        let js2 = extractBlock(html2, "<script>", "</script>", true)
        @Assert(js1 != "")
        @Assert(js1 == js2)

        // ③a 结构标记：本轮定稿的设计决策（改任何一项都应自觉过来看这条）
        // 2026-10-12 参考稿整体重设计（AI 置信度关系图）：旧「模块卡片/文件球/
        // 符号球」三视图退役，换成层级作用域钻取 + 关系驱动分层散带布局 +
        // 端口路由贝塞尔边 + 呼吸氛围。以下逐项钉住新形态的承重接缝。
        @Assert(css1.contains("@keyframes auroraDrift"))  // 呼吸氛围（画布 aurora）
        @Assert(css1.contains(".minimap"))                // 小地图
        @Assert(!css1.contains(".vtabs"))                 // 三按钮 tab 条退役：顶栏无视图切换
        @Assert(css1.contains(".canvas-wrap"))            // 主画布区
        @Assert(js1.contains("function rollUp"))          // roll-up（容器疑点聚合，子树口径）
        @Assert(js1.contains("confidenceColor"))          // 置信度三档色（低红/中黄/高绿）
        @Assert(js1.contains("boundaryOf:"))              // 跨作用域边界披露文案
        @Assert(js1.contains("function cntOf"))           // 徽标计数（与侧栏同口径）
        // 确定性散带布局 + 端口路由（参考稿算法逐段移植，零随机零时间）
        @Assert(js1.contains("function layoutGraph"))
        @Assert(js1.contains("function mapCurrentGraph"))
        @Assert(js1.contains("function settleScatterLayer"))
        @Assert(js1.contains("function routeWorldEdges"))
        @Assert(js1.contains("function drawNode"))
        @Assert(js1.contains("function drawEdge"))
        @Assert(js1.contains("function drawMini"))
        // 一眼可读两支柱（用户验收五轮定稿）：① 边色 = 来源节点身份色
        //（与卡左色条同色，hueCss/hueOf 同源）；② 关系驱动的网格重排
        //（barySweepGrid：强关联卡换到相邻格位，连线变短变直）
        @Assert(js1.contains("function barySweepGrid"))
        @Assert(js1.contains("function hueOf"))
        @Assert(js1.contains("function hueCss"))
        @Assert(js1.contains("hueCss(hueOf(data))"))   // 卡左色条 = 身份色
        @Assert(js1.contains("hueCss(hueOf(srcNode))"))  // 线色 = 来源身份色
        // 旧形态标记退役，不得残留
        @Assert(!js1.contains("buildCallTree"))
        @Assert(!js1.contains("drawGraph"))
        @Assert(!js1.contains("layoutBubbles"))
        @Assert(!js1.contains("drawModules"))
        @Assert(!js1.contains("hitCell"))
        @Assert(js1.contains("getContext('2d')"))      // Canvas 2D（非 SVG/DOM 拼）
        @Assert(htmlA.contains("data-canvas=\"codegraph\""))  // 单画布标记
        @Assert(!htmlA.contains("data-view="))         // 旧视图按钮退役
        @Assert(htmlA.contains("<canvas"))             // 一切通过 canvas 画
        @Assert(htmlA.contains("id=\"canvasWrap\""))   // 主画布容器
        @Assert(htmlA.contains("data-tab=\"confidence\""))  // 置信度 tab（侧栏六 tab）
        // CANVAS2D_SUBSET 纪律（export.cj）：HTML 驱动只许调子集内方法，
        // 同一渲染逻辑才能逐项映射到各平台原生 Canvas（SwiftUI/Qt/仓颉）。
        // 子集外方法一票否决——这是负向断言，往驱动里加新绘制手段必先过这里。
        @Assert(!js1.contains("quadraticCurveTo"))
        @Assert(!js1.contains("measureText"))
        @Assert(!js1.contains("clearRect"))
        @Assert(!js1.contains("createRadialGradient"))
        @Assert(!js1.contains("ctx.save"))
        @Assert(!js1.contains("ctx.restore"))

        // ③b 数据契约：注入一条已知 finding，内嵌函数级数据必须带全六字段
        let conf = analyzeConfidence(g1, false)
        conf.findings.add(Finding(HighComplexity, "util/text.cj",
            7, "trimAll", "契约测试：圈复杂度注入"))
        let fg = functionGraphData(g1, conf, false)
        var sawFinding = false
        for (fn in Json.arrAt(fg, "functions")) {
            for (f in Json.arrAt(fn, "findings")) {
                sawFinding = true
                @Assert(Json.has(f, "kind"))
                @Assert(Json.has(f, "label"))     // 人类可读标签（胶囊文案）
                @Assert(Json.has(f, "dim"))       // 分组维度（tab 分节键）
                @Assert(Json.has(f, "evidence"))  // 自足证据（不打开编辑器可判读）
                @Assert(Json.has(f, "weight"))
                @Assert(Json.has(f, "line"))
                @Assert(Json.strAt(f, "label", "") != "")
            }
        }
        @Assert(sawFinding)
        // 交付物整体内嵌同样带 label（confidence 内嵌与函数级同口径）
        let htmlWithF = treeCanvasHtml(g1, 8, false, conf)
        @Assert(htmlWithF.contains("\"label\""))
        @Assert(htmlWithF.contains("契约测试：圈复杂度注入"))
    } finally {
        removeTree(root1)
        removeTree(root2)
    }
}


/// 调用边的**确信度分层**（codereviewgraph 的 edge confidence 概念落地）：
/// 每条边必须自报它是怎么解析出来的——direct=同文件 / resolved=跨文件且
/// 名字唯一命中 / guessed=重名仅按名匹配（词法近似取首个定义的固有不确定）。
/// 页面把 guessed 画成虚线：不确定的关系必须看起来不确定，
/// 而不是披着确定边的外皮混进图里。热力图着色的按文件罚分表同理：
/// confidence 内嵌必须带 `files`（引擎罚分表原样下发，客户端不许重算第二份口径）。
///
/// T2 回归（第二波）：同文件可见定义**优先于**全库重名判定。原实现
/// defs.size>1 一票判 guessed 且边目标取按序首个定义——同文件调用遇任意
/// 同名定义被画成虚线、边指向另一处文件的定义，与 direct 语义自述矛盾。
@Test
func testFunctionEdgeTierDisclosure(): Unit {
    let root = testRoot()
    try {
        ensureDir("${root}/a")
        ensureDir("${root}/b")
        // helper 在 a 与 b 各有一份定义 → 对 helper 的跨文件调用是 guessed
        writeFileAtomic("${root}/a/helper.cj", """
package a

public func helper(): Int64 { return other() + onlyB() }
public func other(): Int64 { return 1 }

public class Util {
    public static func twice(x: Int64): Int64 { return x * 2 }
}

// 类型限定调用 `Util.twice(` ⇒ direct（限定名 Util.twice 在全工程符号表里唯一对应）
public func useUtil(): Int64 { return Util.twice(3) }
""")
        writeFileAtomic("${root}/b/helper.cj", """
package b

public func helper(): Int64 { return 2 }
""")
        writeFileAtomic("${root}/b/only.cj", """
package b

public func onlyB(): Int64 { return 3 }
""")
        // T2 夹具：implUse 与 helper **同文件**（b/impl.cj），而 helper
        // 全库共三处定义（a/helper.cj / b/helper.cj / b/impl.cj）。
        // 原实现在此夹具上判 guessed 虚线、边指向按序首个 a/helper.cj。
        writeFileAtomic("${root}/b/impl.cj", """
package b

public func helper(): Int64 { return 20 }
public func implUse(): Int64 { return helper() }
""")
        writeFileAtomic("${root}/main.cj", """
package main

public func entry(): Int64 { return helper() }
""")
        let g = buildGraph(root)
        let conf = analyzeConfidence(g, false)
        let fg = functionGraphData(g, conf, false)
        var sawDirect = false
        var sawResolved = false
        var sawGuessed = false
        for (e in Json.arrAt(fg, "functionEdges")) {
            let tier = Json.strAt(e, "tier", "")
            @Assert(tier == "direct" || tier == "resolved" || tier == "guessed")
            if (tier == "direct") { sawDirect = true }
            if (tier == "resolved") { sawResolved = true }
            if (tier == "guessed") { sawGuessed = true }
        }
        @Assert(sawDirect)    // a/useUtil → Util.twice（类型限定命中：`Util.twice(`）
        @Assert(sawResolved)  // a/helper → a/other（同文件唯一）与 a/helper → b/onlyB（跨文件唯一）
        @Assert(sawGuessed)   // main/entry → helper（无同文件定义，三处重名全部连边）
        // T2 断言：同文件调用遇全库重名 ⇒ 边指向同文件定义，且**不是** guessed。
        // 推翻旧断言「tier == direct」：本轮起 tier 的语义是
        //   direct = 限定命中（`Type.name(` / `self.name(` / 类型体内省略 this 的自身成员），
        //   resolved = 裸名唯一（同文件 / 全工程 / 同模块恰一个）。
        // 同文件唯一的裸调用从 direct 改判 resolved——T2 守的行为「同文件定义优先于
        // 全库重名」没变，变的只是这个行为落在哪一档。
        var sawSameFileResolved = false
        for (e in Json.arrAt(fg, "functionEdges")) {
            let from = Json.strAt(e, "from", "")
            if (from.startsWith("f:b/impl.cj:") && from.endsWith(":implUse")) {
                @Assert(Json.strAt(e, "tier", "") == "resolved")
                let to = Json.strAt(e, "to", "")
                @Assert(to.startsWith("f:b/impl.cj:"))
                @Assert(to.endsWith(":helper"))
                sawSameFileResolved = true
            }
        }
        @Assert(sawSameFileResolved)   // 前提：这条边真的存在（否则空转绿）
        // 按文件罚分表内嵌（热力图着色的唯一口径来源）
        let emb = confidenceEmbedJson(conf, false)
        @Assert(Json.has(emb, "files"))
    } finally {
        removeTree(root)
    }
}


// MARK: - 审查回归（audit-2026-10-11）：图谱核心 G1..G8

/// G1 回归：Go **带接收者**的方法声明不许把接收者变量名抽成符号。
/// `func (r *Rect) Area() float64` tokenize 后 tokens[1] 是接收者名 r——
/// scanDeclLine 的 Some(kind) 分支无条件取 tokens[i+1]，方法真名整体消失、
/// r 成了符号；连锁后果是方法声明行的 `Area(` 形态被报「幻觉 API」
/// （defFiles 里没有 Area），健康 Go 文件被打低分。
/// 走真实路径：buildGraph（scanSource）+ analyzeConfidence。
@Test
func testGoReceiverMethodRealNameIsExtracted(): Unit {
    let root = "${tempDirPath()}/cambium-go-recv-${getpid()}-${nowMillis()}"
    ensureDir(root)
    writeFileAtomic("${root}/shape.go", """
package main

import "fmt"

type Rect struct {
    w float64
    h float64
}

func (r *Rect) Area() float64 {
    return r.w * r.h
}

func (q *Rect) Perimeter() float64 {
    return 2 * (q.w + q.h)
}

func (b *Rect) Dump() {
    fmt.Println("rect")
}
""")
    try {
        let g = buildGraph(root)
        // 符号表：含方法真名，不含接收者变量名
        // （r 不在单字符豁免名单 i/j/k/n/x/y/s/t/e/v/f/p/q/w——未修时
        //  它还会从 suspicious-name 出口再假指控一次）
        var names = ArrayList<String>()
        for (f in g.files) {
            for (s in f.symbols) { names.add(s.name) }
        }
        @Assert(names.contains("Rect"))
        @Assert(names.contains("Area"))
        @Assert(names.contains("Perimeter"))
        @Assert(names.contains("Dump"))
        @Assert(!names.contains("r"))
        @Assert(!names.contains("q"))
        @Assert(!names.contains("b"))
        // 健康 Go 文件：零 unresolved-call（未修时 Area/Perimeter/Dump 的
        // 声明行被报幻觉 API）、零 suspicious-name（未修时 r/b 是单字符符号）
        let rep = analyzeConfidence(g, false)
        for (f in rep.findings) {
            match (f.kind) {
                case UnresolvedCall => @Assert(false)
                case SuspiciousName => @Assert(false)
                case _ => ()
            }
        }
    } finally {
        removePathIfExists(root)
    }
}


/// G2 回归：未解析调用检测不许扫注释与字符串，语言关键字不算调用。
/// `if(x)` / `while(` / `for(` / `malloc(sizeof(int))` / 注释与字符串里的
/// `call(` 都被指控过「幻觉 API」。真幻觉名必须照报（判据不许放宽到空转）。
/// 走真实路径：buildGraph（第二遍位置感知扫描）+ analyzeConfidence。
@Test
func testUnresolvedCallIgnoresKeywordsCommentsAndStrings(): Unit {
    let root = "${tempDirPath()}/cambium-unres-${getpid()}-${nowMillis()}"
    ensureDir(root)
    writeFileAtomic("${root}/k.c", """
#include <stdlib.h>

int step(int v) {
    if(v > 3) { v = v - 1; }
    while(v > 0) { v = v - 2; }
    for(int i = 0; i < 3; i = i + 1) { v = v + 4; }
    void *p = malloc(64 * sizeof(int));
    char *s = "call(1) inside string";
    int t = v; /* call(2) inside block comment */
    ghost_thing(v);
    return v;
}
""")
    try {
        let g = buildGraph(root)
        for ((_, name, _) in g.unresolvedCalls) {
            @Assert(name != "if")
            @Assert(name != "for")
            @Assert(name != "while")
            @Assert(name != "sizeof")
            @Assert(name != "call")
        }
        // 真幻觉名照报（负向防线）
        var ghost = false
        for ((_, name, _) in g.unresolvedCalls) {
            if (name == "ghost_thing") { ghost = true }
        }
        @Assert(ghost)
        // 出口同口径：confidence 的 findings 里没有关键词指控
        let rep = analyzeConfidence(g, false)
        var ghostFinding = false
        for (f in rep.findings) {
            match (f.kind) {
                case UnresolvedCall =>
                    @Assert(f.symbol != "if")
                    @Assert(f.symbol != "for")
                    @Assert(f.symbol != "while")
                    @Assert(f.symbol != "sizeof")
                    @Assert(f.symbol != "call")
                    if (f.symbol == "ghost_thing") { ghostFinding = true }
                case _ => ()
            }
        }
        @Assert(ghostFinding)
    } finally {
        removePathIfExists(root)
    }
}


/// G3 回归（detectPointerRisks）：多行块注释里的 malloc 不许计入
/// 「疑似内存泄漏」。走真实路径：buildGraph + analyzeConfidence。
@Test
func testPointerRiskIgnoresCommentedMalloc(): Unit {
    let root = "${tempDirPath()}/cambium-ptr-${getpid()}-${nowMillis()}"
    ensureDir(root)
    writeFileAtomic("${root}/commented.c", """
#include <stdlib.h>

/*
void *leak(void) {
    return malloc(1024);
}
*/
""")
    writeFileAtomic("${root}/live.c", """
#include <stdlib.h>

int leak(void) {
    void *p = malloc(64);
    return 0;
}
""")
    try {
        let rep = analyzeConfidence(buildGraph(root), false)
        var commentedRisk = false
        var liveRisk = false
        for (f in rep.findings) {
            match (f.kind) {
                case PointerRisk =>
                    if (f.file == "commented.c") { commentedRisk = true }
                    if (f.file == "live.c") { liveRisk = true }
                case _ => ()
            }
        }
        // 注释掉的 malloc 不报；活代码的 malloc/free 不配对照报（负向防线）
        @Assert(!commentedRisk)
        @Assert(liveRisk)
    } finally {
        removePathIfExists(root)
    }
}


/// G3 回归（checkLockCalls）：持锁区间里的**多行块注释**内的调用不许被报
/// 死锁。AST 节点无法在沙箱稳定产出（ast-grep 依赖环境），沿用
/// testForwardDeclarationIsNotReportedAsEmptyType 的同包直调检测器先例。
@Test
func testLockCallCheckIgnoresCommentedCalls(): Unit {
    let fnText = "func guarded() {\n" +
        "    mu.lock()\n" +
        "    /*\n" +
        "    foo(1)\n" +
        "    bar(2)\n" +
        "    */\n" +
        "    known(3)\n" +
        "    mu.unlock()\n" +
        "}\n"
    let n = AstNode("g.cj", 1, 9, "fn", fnText)
    let findings = ArrayList<Finding>()
    let perFile = HashMap<String, Int64>()
    // lock 在第 2 行、unlock 在第 8 行——注释块（3..6 行）在持锁区间内
    checkLockCalls(n, 2, 8, findings, perFile, CapDropCounter())
    var sawKnown = false
    for (f in findings) {
        match (f.kind) {
            case LockUnknownCall =>
                @Assert(f.symbol != "foo")
                @Assert(f.symbol != "bar")
                if (f.symbol == "known") { sawKnown = true }
            case _ => ()
        }
    }
    // 活代码的持锁调用照报（负向防线）
    @Assert(sawKnown)
}


/// G3 回归（patchconf 三处）：多行块注释里的声明不许变成 patchconf 实体。
/// 走真实路径：writeTree + buildGraph + analyzePatchConfidence。
@Test
func testPatchConfidenceIgnoresDeclsInsideBlockComment(): Unit {
    let root = writeTree()
    try {
        let graph = buildGraph(root)
        let diff = "--- a/flow/new.cj\n+++ b/flow/new.cj\n@@ -1,2 +1,8 @@\n" +
            " package q\n" +
            "+/*\n" +
            "+public func commented_out(t: Text): Bool {\n" +
            "+    return true\n" +
            "+}\n" +
            "+*/\n" +
            "+public func liveOne(t: Text): Bool {\n" +
            "+    return true\n" +
            "+}\n"
        let pc = analyzePatchConfidence(graph, diff)
        for (e in pc.entities) {
            @Assert(e.name != "commented_out")
        }
        // 活代码的声明照常成为实体（负向防线）
        var hasLive = false
        for (e in pc.entities) {
            if (e.name == "liveOne") { hasLive = true }
        }
        @Assert(hasLive)
    } finally {
        removeTree(root)
    }
}


/// G4 回归：圈复杂度对原始函数体行计分支——注释与字符串里的英文散文
/// （"if the value…"、"a || b"）被算成决策点，纯注释函数被判「圈复杂度 13」。
/// 走真实路径：buildGraph + analyzeConfidence（detectSemanticIssues）。
@Test
func testComplexityIgnoresCommentedBranches(): Unit {
    let root = "${tempDirPath()}/cambium-cc-${getpid()}-${nowMillis()}"
    ensureDir(root)
    writeFileAtomic("${root}/quiet.cj", """
package p

func quiet(): Int64 {
/*
if a { ... }
if a { ... } if a { ... } if a { ... } if a { ... } if a { ... }
if a { ... } if a { ... } if a { ... } if a { ... } if a { ... }
a || b || a || b
*/
    return 1
}

func busy(): Int64 {
    if (a > 1) { return 2 }
    if (a > 2) { return 3 }
    if (a > 3) { return 4 }
    if (a > 4) { return 5 }
    if (a > 5) { return 6 }
    if (a > 6) { return 7 }
    if (a > 7) { return 8 }
    if (a > 8) { return 9 }
    if (a > 9) { return 10 }
    if (a > 10) { return 11 }
    if (a > 11) { return 12 }
    return 13
}
""")
    try {
        let rep = analyzeConfidence(buildGraph(root), false)
        var quietHigh = false
        var busyHigh = false
        for (f in rep.findings) {
            match (f.kind) {
                case HighComplexity =>
                    if (f.symbol == "quiet") { quietHigh = true }
                    if (f.symbol == "busy") { busyHigh = true }
                case _ => ()
            }
        }
        // 纯注释函数（12 行块注释 + 1 行 return）不是高复杂度
        @Assert(!quietHigh)
        // 真分支函数照报（负向防线：11 个 if ⇒ cc = 12 > 阈值）
        @Assert(busyHigh)
    } finally {
        removePathIfExists(root)
    }
}


/// G5 回归：只有字段没有方法的类型不是空类型。
/// 原实现用 mayDeclare（声明关键词）数成员，字段对它不可见——
/// `type Rect struct { w, h float64 }` 被指控「没有任何成员——占位类型
/// 或被掏空」。AST 节点沿用同包直调检测器先例（ast-grep 依赖环境）。
@Test
func testFieldTypeOnlyStructIsNotEmpty(): Unit {
    let nodes = ArrayList<AstNode>()
    nodes.add(AstNode("shape.go", 3, 3, "type", "type Rect struct { w, h float64 }"))
    nodes.add(AstNode("point.h", 5, 5, "type", "struct Point { int x; int y; }"))
    nodes.add(AstNode("hollow.cj", 7, 7, "type", "class Hollow {}"))
    let findings = ArrayList<Finding>()
    detectTypeSignals(nodes, findings)
    for (f in findings) {
        if (flawId(f.kind) == "empty-type") {
            @Assert(f.symbol != "Rect")
            @Assert(f.symbol != "Point")
        }
    }
    // 真空类型照报（判据不许放宽到恒不报；既有 testForwardDeclaration… 同守）
    var hollow = false
    for (f in findings) {
        if (flawId(f.kind) == "empty-type" && f.symbol == "Hollow") { hollow = true }
    }
    @Assert(hollow)
}


// MARK: - 审查回归（第二波）：treehtml 单元（热力图口径 / tier 解析 /
// 分隔线拖拽 / depth 双数据域 / 图例 unreadableDirs 消费）

/// 从 treeCanvasHtml 真实产物提取驱动 JS（最后一个 <script> 块）。
/// JS 行为在仓颉测试里没有浏览器执行路径——按样式契约测试（d3918c9）的
/// 先例，对**完整生成路径的产物**做结构断言，而不是拿手搓 JS 夹具冒充。
private func driverJsOf(html: String): String {
    var a = -1
    var from = 0
    while (true) {
        let hit = indexOfStrFrom(html, "<script>", from)
        if (hit < 0) { break }
        a = hit
        from = hit + 8
    }
    if (a < 0) { return "" }
    let bodyFrom = a + 8
    let b = indexOfStrFrom(html, "</script>", bodyFrom)
    if (b < 0) { return "" }
    // 边界都是 ASCII 标签，UTF-8 切片安全
    return html[bodyFrom..b]
}


/// 从 treeCanvasHtml 产物提取内嵌 payload（window.__CODEGRAPH__ = {…};）并解析。
/// 提取失败返回空对象——调用方第一条前提断言（键存在）即红，不会空转绿。
private func treePayloadOf(html: String): JsonValue {
    let marker = "window.__CODEGRAPH__ = "
    let a = indexOfStrFrom(html, marker, 0)
    if (a < 0) { return Json.obj() }
    let from2 = a + marker.size
    let semi = indexOfStrFrom(html, ";\n</script>", from2)
    if (semi <= from2) { return Json.obj() }
    match (Json.parse(html[from2..semi])) {
        case Some(j) => return j
        case None => return Json.obj()
    }
}


/// 驱动 JS 的剥注释（// 与 /* */）。源码断言前必剥——解释性注释里引用
/// 标识符会把「关键点存在」断言变成假绿（不变量 30/47 同一条纪律）。
/// ⚠️ 已知边界：stripCjCommentEx 只跟踪**双引号**字符串，驱动 LANG 表的
/// `lineCm: '//'`（单引号串，8 处）会被当行注释剥掉行尾（kws 关键字表部分）。
/// 这无害的前提是：**被断言的标识符一个都不许写在 LANG 表的 kws 行尾**——
/// 往那几行加断言目标前先挪位置，否则断言静默空转。驱动无模板串、
/// 无跨行块注释序列（`/*`），行状态机逐行独立，不会卡状态。
private func jsNoComment(js: String): String {
    let sb = StringBuilder()
    var blk = CjStripState.Normal
    for (r in js.split("\n")) {
        let (l, nb) = stripCjCommentEx(r, blk)
        blk = nb
        sb.append(l)
        sb.append("\n")
    }
    return sb.toString()
}


/// T1 回归：热力图文件格的 ⚠ 徽标与悬停必须与点击后的 tab / 详情同口径
/// （rollN = 整棵子树，含符号级 findings）。原实现只数直属 fileFindings——
/// 绝大多数 finding 按行号归属到符号体，纯符号级罚分的文件格「颜色说有
/// 罚分、徽标说没有」（43e57a1 修过的同族在新出口复发）。
/// 判据是语义级的：cntOf 容器分支必须用子树口径，且驱动里不许再出现
/// 「数直属 fileFindings 长度」的取数点（数据构建处只 push / forEach，
/// 不会被这条误伤）。
@Test
func testTreeHeatBadgeCountsSubtreeNotDirectFindings(): Unit {
    let root = writeTree()
    try {
        let g = buildGraph(root)
        let js = driverJsOf(treeCanvasHtml(g, 0, false, analyzeConfidence(g, false)))
        // 前提守卫（不变量 22）：提取成功、归属与 roll-up 的数据构建仍在
        @Assert(js.contains("function cntOf"))
        @Assert(js.contains("fileFindings.push"))
        @Assert(js.contains("n.fileFindings.forEach"))
        // cntOf 函数体：容器（file/dir）分支必须返回 rollN
        let a = indexOfStrFrom(js, "function cntOf", 0)
        @Assert(a >= 0)
        let b = indexOfStrFrom(js, "function ", a + 1)
        @Assert(b > a)
        let body = js[a..b]
        @Assert(body.contains("rollN"))
        @Assert(!body.contains("fileFindings.length"))
        // 悬停 tooltip 同口径：全驱动不许再数直属 fileFindings 的长度
        //（该取数点只可能出现在徽标 / tooltip，负向断言精确覆盖缺陷）
        @Assert(!js.contains("fileFindings.length"))
    } finally {
        removeTree(root)
    }
}


/// T3 回归：分隔线拖拽 / 双击复位改变详情栏宽度 ⇒ stage 宽度随之变化，
/// 画布必须 resizeCanvas()+draw()。原实现只改宽度、画布不重设尺寸不重画
/// ——canvas 按旧宽渲染并溢出，反向盖住详情栏，除窗口 resize 外无自愈。
@Test
func testTreeDividerResizeRedrawsCanvas(): Unit {
    let root = writeTree()
    try {
        let g = buildGraph(root)
        let js = driverJsOf(treeCanvasHtml(g, 0, false, analyzeConfidence(g, false)))
        // 2026-10-12 参考稿重设计：旧「拖拽分隔条调侧栏宽度」随 data-pane
        // 布局显式退役（参考稿为固定 368px 栅格侧栏）。保留的契约是
        // 「窗口尺寸变化必须重排 + 重画」——pin resize 监听 → resize() →
        // layoutGraph + fitView 这条链（拖拽没有了，重排红线还在）。
        let a = indexOfStrFrom(js, "window.addEventListener('resize'", 0)
        @Assert(a >= 0)
        let seg = js[a..]
        // 前提：监听体内真的接了重排链，而不是空监听
        //（layoutGraph 在 resize() 内部被调用；fitView 必须在监听链上）
        @Assert(seg.contains("resizeTimer"))
        @Assert(seg.contains("resize()"))
        @Assert(seg.contains("fitView()"))
    } finally {
        removeTree(root)
    }
}


/// T4 回归（契约D）：--depth 必须同时约束文件树域与函数域。
/// 原实现 functionGraphData 遍历全部文件——同一份 HTML 两个数据域口径
/// 不同：depth 外符号画得出、悬停有反馈，而点击 / 回车 / 搜索 / 公开 API
/// setFocus 全部静默无反应。走真实路径：treeCanvasHtml 产物里提取内嵌
/// JSON（经 jsonSafeForEmbed）再解析，断言两域文件集一致、边端点全部落在
/// 函数清单之内（callee 候选同样被 depth 过滤，否则边指向不存在的端点）。
@Test
func testTreeHtmlFunctionDomainMatchesDepth(): Unit {
    let root = writeTree()
    try {
        // 深度 2 的文件（depth=1 时被剪）+ 根目录 entry 调深度外符号
        ensureDir("${root}/flow/inner")
        writeFileAtomic("${root}/flow/inner/deep.cj", """
package cambium.flow.inner

public func deepThing(): Int64 { return 1 }
""")
        writeFileAtomic("${root}/entry.cj", """
package cambium

public func entryCall(): Int64 { return deepThing() }
""")
        let g = buildGraph(root)
        let conf = analyzeConfidence(g, false)
        func payloadOf(html: String): JsonValue {
            let marker = "window.__CODEGRAPH__ = "
            let a = indexOfStrFrom(html, marker, 0)
            @Assert(a >= 0)
            let from2 = a + marker.size
            // 产物拼接是 <json>;\n</script>——结束标记必须带换行才贴得上
            let semi = indexOfStrFrom(html, ";\n</script>", from2)
            @Assert(semi > from2)
            match (Json.parse(html[from2..semi])) {
                case Some(j) => return j
                case None => @Assert(false)
            }
            return Json.obj()
        }
        let dj = payloadOf(treeCanvasHtml(g, 1, false, conf))
        // 前提：夹具真的触发了截断（否则「一致」是空转绿——不变量 41）
        @Assert(Json.intAt(dj, "depth", -1) == 1)
        @Assert(Json.intAt(dj, "depthOmitted", 0) >= 1)
        let fileSet = HashMap<String, Bool>()
        for (f in Json.arrAt(dj, "files")) {
            fileSet[Json.strAt(f, "path", "")] = true
        }
        @Assert(!fileSet.contains("flow/inner/deep.cj"))
        let fnFiles = HashMap<String, Bool>()
        var sawDeepFn = false
        match (Json.getOr(dj, "functionGraph")) {
            case JObj(_) =>
                // ⊆：函数域不许超出文件树（depth 外文件不产函数 / 实码）
                for (fn in Json.arrAt(Json.getOr(dj, "functionGraph"), "functions")) {
                    let p = Json.strAt(fn, "file", "")
                    @Assert(fileSet.contains(p))
                    fnFiles[p] = true
                    if (p == "flow/inner/deep.cj") { sawDeepFn = true }
                }
                @Assert(!sawDeepFn)
                // 边端点全部落在函数清单里：entryCall→deepThing（深度 0 调
                // 深度 2）这条边不该存在——to 端不在可见数据域
                let ids = HashMap<String, Bool>()
                for (fn in Json.arrAt(Json.getOr(dj, "functionGraph"), "functions")) {
                    ids[Json.strAt(fn, "id", "")] = true
                }
                for (e in Json.arrAt(Json.getOr(dj, "functionGraph"), "functionEdges")) {
                    @Assert(ids.contains(Json.strAt(e, "from", "")))
                    @Assert(ids.contains(Json.strAt(e, "to", "")))
                }
                // 一致：文件树里每个有符号的文件都有函数节点（entry.cj 在内）
                @Assert(fnFiles.contains("entry.cj"))
                for (f in Json.arrAt(dj, "files")) {
                    if (Int64(Json.arrAt(f, "symbols").size) > 0) {
                        @Assert(fnFiles.contains(Json.strAt(f, "path", "")))
                    }
                }
            case _ => @Assert(false)
        }
        // 对外签名保持全量（契约D：cli.cj / mcp.cj 的既有调用面零改动）：
        // 深度 2 文件的函数与「深度 0 调深度 2」的边都还在（过滤只发生在
        // maxDepth>0，不许把全量路径误杀）
        let full = functionGraphData(g, conf, false)
        var sawDeepInFull = false
        for (fn in Json.arrAt(full, "functions")) {
            if (Json.strAt(fn, "file", "") == "flow/inner/deep.cj") { sawDeepInFull = true }
        }
        @Assert(sawDeepInFull)
        var sawEntryEdge = false
        for (e in Json.arrAt(full, "functionEdges")) {
            if (Json.strAt(e, "from", "").endsWith(":entryCall") && Json.strAt(e, "to", "").endsWith(":deepThing")) {
                sawEntryEdge = true
            }
        }
        @Assert(sawEntryEdge)
    } finally {
        removeTree(root)
    }
}


/// T5 回归（契约A 页面侧）：图例必须消费 D.unreadableDirs——非空 = 有
/// 子树没读到，图谱不是全量。「读不到」与「没有」是两个状态，页面不许把
/// 读不到渲染成没有。核心侧恒发两键由 archfix_test R6 钉住；这条钉住
/// 页面消费点：renderLegend 读 D.unreadableDirs（note 样式，对齐 truncated
/// 披露），截断时（数组只发前 N 条）数量必须带 ≥ 下界前缀。
@Test
func testTreeLegendConsumesUnreadableDirs(): Unit {
    let root = writeTree()
    try {
        let g = buildGraph(root)
        let html = treeCanvasHtml(g, 0, false, analyzeConfidence(g, false))
        let js = driverJsOf(html)
        // 前提：数据侧恒发两键（契约A 引擎侧），页面拿到的是完整 HTML
        @Assert(html.contains("\"unreadableDirs\""))
        @Assert(html.contains("\"unreadableDirsTruncated\""))
        // 图例警示文案随 T 表注入（中文态）；消费点在 integrityNotes 里：
        // 读 D.unreadableDirs，note 样式披露（旧 renderLegend 随参考稿重设计退役）
        @Assert(js.contains("个目录读不到"))
        let a = indexOfStrFrom(js, "function integrityNotes", 0)
        @Assert(a >= 0)
        let b = indexOfStrFrom(js, "function ", a + 1)
        @Assert(b > a)
        let seg = js[a..b]
        @Assert(seg.contains("D.unreadableDirs"))
        @Assert(seg.contains("D.unreadableDirsTruncated"))
        @Assert(seg.contains("noteUnread"))
        @Assert(seg.contains("class=\"note\""))
    } finally {
        removeTree(root)
    }
}


/// L3 回归：patchconf 的 entity 关系**前瞻循环**原先对上下文行不推进
/// lookState（主循环推进），块注释横跨「上下文行 → 新增行」时两遍状态发散，
/// 注释残段里的调用被算进关系分。修法：与主循环同一套推进纪律
/// （删除行跳过不推进；上下文行推进、只不产出）。
/// 走真实路径：writeTree + buildGraph + analyzePatchConfidence。
@Test
func testPatchLookaheadAdvancesStateOnContextLines(): Unit {
    let root = writeTree()
    try {
        let graph = buildGraph(root)
        // 注释开始于**上下文行**（" /*"），新增行 main(None) 整行在注释内：
        // 主循环按状态 3 剥掉；前窥循环（修复前状态 0）会把 main( 当活代码。
        let diff = "--- a/flow/new.cj\n+++ b/flow/new.cj\n@@ -1,3 +1,11 @@\n" +
            " package q\n" +
            "+public func live(t: Text): Bool {\n" +
            "+    return runUpdate(t)\n" +
            "+}\n" +
            " /*\n" +
            "+main(None)\n" +
            "+*/\n" +
            "+public func tail(t: Text): Bool {\n" +
            "+    return true\n" +
            "+}\n"
        let pc = analyzePatchConfidence(graph, diff)
        var sawLive = false
        var sawRunUpdateRel = false
        for (e in pc.entities) {
            if (e.name != "live") { continue }
            sawLive = true
            for ((_, target, _) in e.relations) {
                if (target.contains("runUpdate")) { sawRunUpdateRel = true }
                // 注释残段里的 main 不许算进关系（两遍状态发散的后果）
                @Assert(!target.contains("main"))
            }
        }
        @Assert(sawLive)
        // 负向防线：前窥机制本身还在工作——活代码里的 runUpdate 必须算进关系
        @Assert(sawRunUpdateRel)
    } finally {
        removeTree(root)
    }
}


/// L4：flawId 死分支删除后的出口契约钉住（语义层 5 kind 的 id 唯一且稳定；
/// 不可达的重复分支删除是零行为变化，这条防的是 id 字符串被顺手改掉）。
@Test
func testFlawIdCoversSemanticKindsOnce(): Unit {
    @Assert(flawId(HighComplexity) == "high-complexity")
    @Assert(flawId(ParameterAbuse) == "parameter-abuse")
    @Assert(flawId(DeadBranch) == "dead-branch")
    @Assert(flawId(MixedResponsibility) == "mixed-responsibility")
    @Assert(flawId(NearDuplicate) == "near-duplicate")
}


/// capped 契约测试的夹具：一个含 6 个（= CONF_MAX_PER_KIND_PER_FILE）单行
/// 空体函数的仓颉文件——每文件恰好产出 StubBody×6 + Orphan×6，两个上限都
/// **恰好达限而未超**。tag 让函数名跨文件不同（防 NearDuplicate 的同体哈希
/// 干扰计数）。
private func sixStubFile(tag: String): String {
    let sb = StringBuilder()
    sb.append("package p\n\n")
    var k: Int64 = 1
    while (k <= CONF_MAX_PER_KIND_PER_FILE) {
        sb.append("public func s${k}${tag}() { }\n")
        k += 1
    }
    return sb.toString()
}


/// L5 回归（契约C 引擎侧）：cappedKind / cappedTotal 的真值来自**丢弃发生的
/// 判定点**（CapDropCounter / 截断分支），不是拿截断后的结果集反推——
/// 「恰好 6 条同类」与「第 7 条被丢弃」在结果集里同形，反推会把恰好达限
/// 误报成「超出已汇总」。三场景：恰好达限 → 双 false；第 7 条触发每类丢弃 →
/// 仅 cappedKind；多文件堆总量超 CONF_MAX_FINDINGS 而每类不丢 → 仅 cappedTotal。
/// 走真实路径：buildGraph + analyzeConfidence。
@Test
func testConfidenceCappedFlagsComeFromRealDrops(): Unit {
    // 场景一：恰好 6 条同类（两个类别都达限未超）
    let root6 = "${tempDirPath()}/cambium-cap6-${getpid()}-${nowMillis()}"
    ensureDir(root6)
    writeFileAtomic("${root6}/exactly.cj", sixStubFile(""))
    // 场景二：第 7 条触发每文件每类丢弃
    let root7 = "${tempDirPath()}/cambium-cap7-${getpid()}-${nowMillis()}"
    ensureDir(root7)
    writeFileAtomic("${root7}/over.cj", sixStubFile("") + "public func s7() { }\n")
    // 场景三：每文件恰不超限、多文件把总量堆过 CONF_MAX_FINDINGS
    let rootT = "${tempDirPath()}/cambium-capT-${getpid()}-${nowMillis()}"
    ensureDir(rootT)
    let filesNeeded = CONF_MAX_FINDINGS / (2 * CONF_MAX_PER_KIND_PER_FILE) + 2
    var i: Int64 = 0
    while (i < filesNeeded) {
        writeFileAtomic("${rootT}/f${i}.cj", sixStubFile("f${i}"))
        i += 1
    }
    try {
        // 场景一：恰好 6 条 → 双 false（页面拿结果集反推会误报 true 的那种）
        let rep6 = analyzeConfidence(buildGraph(root6), false)
        @Assert(!rep6.cappedKind)
        @Assert(!rep6.cappedTotal)
        // 前提守卫（不变量 18：断言前先确认场景真的成立）：两类都恰好 6 条——
        // 少于 6 条时「未超限」是空转绿
        var stub6: Int64 = 0
        var orph6: Int64 = 0
        for (f in rep6.findings) {
            match (f.kind) {
                case StubBody => stub6 += 1
                case Orphan => orph6 += 1
                case _ => ()
            }
        }
        @Assert(stub6 == CONF_MAX_PER_KIND_PER_FILE)
        @Assert(orph6 == CONF_MAX_PER_KIND_PER_FILE)

        // 场景二：第 7 条触发每类丢弃 → cappedKind=true，总量远未达上限 → false
        let rep7 = analyzeConfidence(buildGraph(root7), false)
        @Assert(rep7.cappedKind)
        @Assert(!rep7.cappedTotal)

        // 场景三：总量超 CONF_MAX_FINDINGS（每文件 12 条 × 35 文件 = 420 > 400）
        // 而每文件每类恰好 6 条不丢弃 → 仅 cappedTotal 置位
        let repT = analyzeConfidence(buildGraph(rootT), false)
        @Assert(repT.cappedTotal)
        @Assert(!repT.cappedKind)
        @Assert(Int64(repT.findings.size) == CONF_MAX_FINDINGS)   // 截断到上限
    } finally {
        removePathIfExists(root6)
        removePathIfExists(root7)
        removePathIfExists(rootT)
    }
}


// MARK: - 模块层 × 分级 × 置信度指数（三视图改造的回归）

/// 分级纯函数三态（30/600 边界）。口径：文件数与符号数**都不超**阈值 →
/// compact（代码级）；任一严格超 → layered（模块级）。边界归属：恰好等于
/// 阈值 = 不超 = compact（「超」是严格大于）。阈值常量改动必须过这条 +
/// 页面披露文案（tierLf/tierLs/tierC 同步改，否则「分级：…（N 文件 > 30）」
/// 的数字与真阈值脱节）。
@Test
func testTierOfBoundaries(): Unit {
    @Assert(COMPACT_MAX_FILES == 30)
    @Assert(COMPACT_MAX_SYMBOLS == 600)
    @Assert(tierOf(0, 0) == "compact")
    @Assert(tierOf(30, 600) == "compact")    // 恰好达限 = 不超
    @Assert(tierOf(0, 600) == "compact")
    @Assert(tierOf(31, 0) == "layered")      // 文件数严格超
    @Assert(tierOf(0, 601) == "layered")     // 符号数严格超
    @Assert(tierOf(30, 601) == "layered")    // 一维超即 layered
    @Assert(tierOf(31, 601) == "layered")
}


/// 模块层数据的口径同源（走真实路径：treeCanvasHtml 产物提取内嵌 JSON）：
///   · 模块集合 == 对夹具全文件取 moduleOfPath 的集合（划分同源，不许第二份）；
///   · 每模块 confIndex == confidenceScore(penalty, files)（公式同源）；
///   · penalty / findings == conf.files / conf.findings 按模块聚合（输入同源）；
///   · 七键恒发（0 也发）——零罚分/无疑点是「这个模块可信」的证据；
///   · fileModules 逐文件 == moduleOfPath（下钻与热力图标签的单一口径来源）；
///   · graphModuleEdges == archRefEdges 按模块对聚合（架构口径，禁 refEdges），
///     无自模块对，from↑ → to↑ 全序。
@Test
func testTreeModuleLayerPayload(): Unit {
    let root = writeTree()
    try {
        let g = buildGraph(root)
        let conf = analyzeConfidence(g, false)
        let dj = treePayloadOf(treeCanvasHtml(g, 0, false, conf))
        // 前提守卫：提取成功（否则下面全部空转）
        @Assert(Json.has(dj, "files"))
        // 期望值独立重算（与引擎各自的代码路径对账）
        let expectMods = HashMap<String, Int64>()
        for (f in g.files) {
            let m = moduleOfPath(f.relPath)
            match (expectMods.get(m)) {
                case Some(v) => expectMods[m] = v + 1
                case None => expectMods[m] = 1
            }
        }
        @Assert(expectMods.size >= 2)   // 前提：夹具真的有 ≥2 个模块
        let expectPen = HashMap<String, Int64>()
        for ((path, pen) in conf.files) {
            let m = moduleOfPath(path)
            match (expectPen.get(m)) {
                case Some(v) => expectPen[m] = v + pen
                case None => expectPen[m] = pen
            }
        }
        let expectFnd = HashMap<String, Int64>()
        for (fd in conf.findings) {
            let m = moduleOfPath(fd.file)
            match (expectFnd.get(m)) {
                case Some(v) => expectFnd[m] = v + 1
                case None => expectFnd[m] = 1
            }
        }
        // graphModules：集合相等 + 键恒发 + 三条口径逐模块对账
        let seen = HashMap<String, Bool>()
        var totalFiles: Int64 = 0
        var totalSymbols: Int64 = 0
        var totalLines: Int64 = 0
        for (mo in Json.arrAt(dj, "graphModules")) {
            let id = Json.strAt(mo, "id", "")
            @Assert(!id.isEmpty())
            seen[id] = true
            // 七键恒发（0 也发；缺键会被读成旧版本没有该字段）
            @Assert(Json.has(mo, "id"))
            @Assert(Json.has(mo, "files"))
            @Assert(Json.has(mo, "symbols"))
            @Assert(Json.has(mo, "lines"))
            @Assert(Json.has(mo, "penalty"))
            @Assert(Json.has(mo, "findings"))
            @Assert(Json.has(mo, "confIndex"))
            let fc = Json.intAt(mo, "files", -1)
            match (expectMods.get(id)) {
                case Some(v) => @Assert(fc == v)   // 划分同源：模块集合与计数一致
                case None => @Assert(false)
            }
            let pen = Json.intAt(mo, "penalty", -1)
            var expPen: Int64 = 0
            match (expectPen.get(id)) {
                case Some(v) => expPen = v
                case None => ()
            }
            @Assert(pen == expPen)                 // 罚分聚合 == conf.files 输入
            var expFnd: Int64 = 0
            match (expectFnd.get(id)) {
                case Some(v) => expFnd = v
                case None => ()
            }
            @Assert(Json.intAt(mo, "findings", -1) == expFnd)
            // 口径同源：confIndex 必须 == confidenceScore(penalty, files)
            @Assert(Json.intAt(mo, "confIndex", -1) == confidenceScore(pen, fc))
            totalFiles += fc
            totalSymbols += Json.intAt(mo, "symbols", 0)
            totalLines += Json.intAt(mo, "lines", 0)
        }
        var expectCount: Int64 = 0
        for ((m, _) in expectMods) {
            expectCount += 1
            @Assert(seen.contains(m))
        }
        @Assert(Int64(seen.size) == expectCount)
        // 聚合完整性：模块计数加回 == 全量文件事实
        @Assert(totalFiles == Int64(g.files.size))
        var expSymbols: Int64 = 0
        var expLines: Int64 = 0
        for (f in g.files) {
            expSymbols += Int64(f.symbols.size)
            expLines += f.lines
        }
        @Assert(totalSymbols == expSymbols)
        @Assert(totalLines == expLines)
        // fileModules：逐文件 == moduleOfPath（下钻/热力图标签查的是这一份）
        match (Json.getOr(dj, "fileModules")) {
            case JObj(_) =>
                let fm = Json.getOr(dj, "fileModules")
                for (f in Json.arrAt(dj, "files")) {
                    let p = Json.strAt(f, "path", "")
                    @Assert(Json.strAt(fm, p, "@@missing@@") == moduleOfPath(p))
                }
            case _ => @Assert(false)
        }
        // graphModuleEdges：== archRefEdges 按模块对聚合；无自模块对；全序
        let expectEdges = HashMap<String, Int64>()
        for ((from, to, w) in g.archRefEdges) {
            let a = moduleOfPath(from)
            let b = moduleOfPath(to)
            if (a == b) { continue }
            let key = a + "\u{1f}" + b
            match (expectEdges.get(key)) {
                case Some(v) => expectEdges[key] = v + w
                case None => expectEdges[key] = w
            }
        }
        @Assert(expectEdges.size >= 1)   // 前提：夹具真的有跨模块架构引用
        var prevKey = ""
        var edgeCount: Int64 = 0
        for (e in Json.arrAt(dj, "graphModuleEdges")) {
            @Assert(Json.has(e, "from"))
            @Assert(Json.has(e, "to"))
            @Assert(Json.has(e, "w"))
            let a = Json.strAt(e, "from", "")
            let b = Json.strAt(e, "to", "")
            @Assert(a != b)
            let key = a + "\u{1f}" + b
            @Assert(key >= prevKey)      // from↑ → to↑ 全序（M11 纪律）
            prevKey = key
            match (expectEdges.get(key)) {
                case Some(v) => @Assert(Json.intAt(e, "w", -1) == v)
                case None => @Assert(false)
            }
            edgeCount += 1
        }
        @Assert(edgeCount == Int64(expectEdges.size))
    } finally {
        removeTree(root)
    }
}


/// 模块边最小夹具（数据侧 d）：两模块各一文件，b 调 a 的顶格公开函数
/// → 恰一条模块边 b→a 且 w ≥ 1；模块集合 = {a, b}；自模块对不成边。
@Test
func testTreeModuleEdgeFromTinyFixture(): Unit {
    let root = testRoot()
    try {
        ensureDir("${root}/a")
        ensureDir("${root}/b")
        writeFileAtomic("${root}/a/api.cj", """
package a

public func aThing(): Int64 { return 1 }
""")
        writeFileAtomic("${root}/b/use.cj", """
package b

public func useThing(): Int64 { return aThing() }
""")
        let g = buildGraph(root)
        // 前提守卫：架构口径真的解析出了跨文件引用（否则「恰一条」空转绿）
        @Assert(g.archRefEdges.size >= 1)
        let dj = treePayloadOf(treeCanvasHtml(g, 0, false, analyzeConfidence(g, false)))
        @Assert(Json.has(dj, "graphModuleEdges"))
        let es = Json.arrAt(dj, "graphModuleEdges")
        @Assert(es.size == 1)
        @Assert(Json.strAt(es[0], "from", "") == "b")
        @Assert(Json.strAt(es[0], "to", "") == "a")
        @Assert(Json.intAt(es[0], "w", 0) >= 1)
        // 模块集合 = {a, b}（对夹具全文件取 moduleOfPath 的同一集合）
        let mods = Json.arrAt(dj, "graphModules")
        @Assert(mods.size == 2)
        let ids = HashMap<String, Bool>()
        for (m in mods) { ids[Json.strAt(m, "id", "")] = true }
        @Assert(ids.contains("a"))
        @Assert(ids.contains("b"))
    } finally {
        removeTree(root)
    }
}


/// 单画布两级 + 分级入口（走真实产物）：
///   · 顶栏无视图按钮（单画布标记 + 分级 chip + 面包屑容器）；
///   · 驱动消费 graphModules/graphModuleEdges/fileModules/confIndex、
///     模块层绘制（drawModules/drawMCard/drawMEdge）、层级往返（enterCode/
///     backToModules/paintCrumb + 面包屑接线）、代码层文件过滤查引擎下发的
///     划分表（FM[fe.path]）——源码断言，剥注释后仍须命中（不变量 30）；
///   · 分级入口逻辑（layered → 模块层 / compact → 代码层）：DEFAULT_LEVEL
///     判定 + 初始化落点 state.level = DEFAULT_LEVEL + 两阈值键恒发；
///   · compact 夹具（writeTree）projectTier=compact；layered 夹具
///     （31 文件 > 30）projectTier=layered，tierFiles 与阈值键恒发对账。
///   旧名 testTreeThreeViewsAndTierDefault：三视图按钮与调用树下钻
///   （pickModuleFocus/GMIDX[dm]）随单画布重构**显式退役**，不是漏改。
@Test
func testTreeTierEntryAndModuleLayer(): Unit {
    let root = writeTree()
    let big = testRoot()
    try {
        let g = buildGraph(root)
        let conf = analyzeConfidence(g, false)
        let html = treeCanvasHtml(g, 0, false, conf)
        // 单画布标记 + 分级 chip + 面包屑容器（旧 data-view 三按钮已退役；
        // 2026-10-12 参考稿重设计：tier-chip/mcrumb 改为 topbar tierChip 与
        // 画布脚注 breadcrumbs）
        @Assert(html.contains("data-canvas=\"codegraph\""))
        @Assert(!html.contains("data-view="))
        @Assert(html.contains("id=\"tierChip\""))
        @Assert(html.contains("id=\"breadcrumbs\""))
        // 驱动关键点（剥注释后断言；抓不到 = 断言空转，先红在前提上）
        let js = jsNoComment(driverJsOf(html))
        @Assert(js.contains("D.graphModules"))
        @Assert(js.contains("D.graphModuleEdges"))
        @Assert(js.contains("D.fileModules"))
        @Assert(js.contains("D.archRefEdges"))      // 文件级调用边数据源
        @Assert(js.contains("confIndex"))           // 模块指数走引擎下发值
        @Assert(js.contains("function layoutGraph"))     // 分层散带布局入口
        @Assert(js.contains("function mapCurrentGraph")) // 作用域 → 可见图映射
        @Assert(js.contains("function drawNode"))        // 节点卡片绘制
        @Assert(js.contains("function drawEdge"))        // 关系边绘制（端口路由）
        @Assert(js.contains("function confidenceColor")) // 置信度三档色阶
        @Assert(js.contains("function enterScope"))      // 点卡片/双击 → 子图
        @Assert(js.contains("function updateBreadcrumbs"))  // 面包屑链
        @Assert(js.contains("FM[fe.path]"))         // 文件归属查引擎下发的划分表
        @Assert(js.contains("D.compactMaxFiles"))
        @Assert(js.contains("D.compactMaxSymbols"))
        // 分级披露：tier 文案三态（layered 文件超限 / 符号超限 / compact）
        @Assert(js.contains("D.projectTier === 'layered'"))
        @Assert(js.contains("T.tierLf"))
        @Assert(js.contains("T.tierLs"))
        @Assert(js.contains("T.tierC"))
        // 入口落点：初始作用域恒为 project（参考稿语义；旧 DEFAULT_LEVEL 退役）
        @Assert(js.contains("var scopeId = 'project'"))
        // 图例：置信度三档 + 关系线型（call 实线 / guessed 虚线）
        @Assert(js.contains("lgLo"))
        @Assert(js.contains("lgMid"))
        @Assert(js.contains("lgHi"))
        // 图例线语义：线色 = 来源节点（身份色左色条）· 虚线 = 词法不确定
        @Assert(js.contains("lgSrc"))
        @Assert(js.contains("T.lgSrc"))
        // compact 夹具：分级 = 代码级，阈值键恒发，tierFiles 与文件集对账
        let dj = treePayloadOf(html)
        @Assert(Json.strAt(dj, "projectTier", "") == "compact")
        @Assert(Json.has(dj, "projectTier"))
        @Assert(Json.has(dj, "compactMaxFiles"))
        @Assert(Json.has(dj, "compactMaxSymbols"))
        @Assert(Json.intAt(dj, "compactMaxFiles", -1) == 30)
        @Assert(Json.intAt(dj, "compactMaxSymbols", -1) == 600)
        @Assert(Json.intAt(dj, "tierFiles", -1) == Int64(g.files.size))
        // layered 夹具：31 个单文件模块（> COMPACT_MAX_FILES）→ 模块级
        var i: Int64 = 0
        while (i <= 30) {
            let dir = "${big}/m${i}"
            ensureDir(dir)
            let sb = StringBuilder()
            sb.append("package m")
            sb.append(i.toString())
            sb.append("\n\npublic func f")
            sb.append(i.toString())
            sb.append("(): Int64 { return ")
            sb.append(i.toString())
            sb.append(" }\n")
            writeFileAtomic(dir + "/f.cj", sb.toString())
            i += 1
        }
        let gb = buildGraph(big)
        @Assert(Int64(gb.files.size) == 31)   // 前提：夹具真的超过阈值
        let djb = treePayloadOf(treeCanvasHtml(gb, 0, false, analyzeConfidence(gb, false)))
        @Assert(Json.strAt(djb, "projectTier", "") == "layered")
        @Assert(Json.intAt(djb, "tierFiles", -1) == 31)
        @Assert(Json.has(djb, "graphModules"))
        @Assert(Json.arrAt(djb, "graphModules").size == 31)
    } finally {
        removeTree(root)
        removeTree(big)
    }
}


/// 单画布产物的结构标记（规格 a）：三视图退役后，产物必须只有一张画布，
/// 且关系散带布局、绘制与路由入口都在。历代退役形态的符号是残留探测器
///（tidy tree / treemap / 模块卡片 / 文件球）——出现任何一个都说明旧视图
/// 没删干净。
@Test
func testTreeSingleCanvasArtifactMarkers(): Unit {
    let root = writeTree()
    try {
        let g = buildGraph(root)
        let html = treeCanvasHtml(g, 0, false, analyzeConfidence(g, false))
        // 单一画布：无 .vtabs / data-view 三按钮；画布容器带 codegraph 标记
        @Assert(!html.contains("vtabs"))
        @Assert(!html.contains("data-view="))
        @Assert(html.contains("data-canvas=\"codegraph\""))
        @Assert(html.contains("<canvas"))
        let js = jsNoComment(driverJsOf(html))
        // 参考稿形态的承重入口：作用域映射 → 分层散带 → 端口路由 → 绘制
        @Assert(js.contains("function mapCurrentGraph"))
        @Assert(js.contains("function layoutGraph"))
        @Assert(js.contains("function settleScatterLayer"))
        @Assert(js.contains("function routeWorldEdges"))
        @Assert(js.contains("function drawNode"))
        @Assert(js.contains("function drawEdge"))
        @Assert(js.contains("function drawMini"))
        @Assert(js.contains("function confScore"))
        // 呼吸动效总闸（reduced-motion 直通终帧）
        @Assert(js.contains("function setBreathEnabled"))
        // 历代退役形态：tidy tree / 模块卡片 / 文件球 / treemap 命中函数
        @Assert(!js.contains("buildCallTree"))
        @Assert(!js.contains("layoutCallTree"))
        @Assert(!js.contains("drawGNode"))
        @Assert(!js.contains("drawGEdge"))
        @Assert(!js.contains("drawModules"))
        @Assert(!js.contains("buildBubbles"))
        @Assert(!js.contains("layoutBubbles"))
        // 旧命中函数名残留 = hover 引用未定义函数（ReferenceError，
        // 2026-10-12 实测抓过一次 hitCell）
        @Assert(!js.contains("hitCell"))
        // 旧三视图分发退役
        @Assert(!js.contains("drawHeat"))
        @Assert(!js.contains("state.view"))
    } finally {
        removeTree(root)
    }
}


/// 文件节点颜色 = confidenceColor(confidenceScore(罚分, 1))（规格 c）：
/// confidence.cj 公开公式的「单文件视角」，驱动侧 confScore 必须是它的
/// 唯一实现——页面另造第二份色阶口径 = 同名不同义的指数（43 号教训的同族）。
/// 源码断言，剥注释后仍须命中（不变量 30：剥注释前断言会假绿）。
@Test
func testTreeFileCellColorUsesConfidenceScoreFormula(): Unit {
    // 引擎侧公式对齐锚点：同一罚分的单文件指数（驱动公式必须与它同值）
    @Assert(confidenceScore(0, 1) == 100)
    @Assert(confidenceScore(20, 1) == 50)    // density=20=S ⇒ 100·S/(S+S)=50
    @Assert(confidenceScore(60, 1) == 25)
    let root = writeTree()
    try {
        let g = buildGraph(root)
        let js = jsNoComment(driverJsOf(treeCanvasHtml(g, 0, false, analyzeConfidence(g, false))))
        // 前提守卫（不变量 22）：公式实现与调用点真的在产物里
        @Assert(js.contains("function confScore"))
        @Assert(js.contains("confScore(HEAT[fe.path] || 0, 1)"))
        // 文件节点置信度调用点：confScore(HEAT[路径] || 0, 1)（2026-10-12
        // 参考稿重设计：scoreHex 退役，色阶出口统一为 confidenceColor）
        @Assert(js.contains("confidenceColor("))
        // 公式体与 confidence.cj:607 对齐：n 下限 1、标度 20、floor 截断、0..100 夹取
        let a = indexOfStrFrom(js, "function confScore", 0)
        @Assert(a >= 0)
        let b = indexOfStrFrom(js, "function ", a + 1)
        @Assert(b > a)
        let body = js[a..b]
        @Assert(body.contains("files < 1 ? 1 : files"))
        @Assert(body.contains("/ (CONF_SCALE + density)"))
        @Assert(body.contains("Math.floor"))
        @Assert(body.contains("sc > 100"))
        @Assert(body.contains("sc < 0"))
        // 全驱动唯一实现：confScore 只定义一次（第二份 = 口径漂移）
        @Assert(countOf(js, "function confScore") == 1)
        // 模块卡片指数走引擎下发值（confIndex），页面不重算模块级第二份
        @Assert(js.contains("m.confIndex"))
        @Assert(!js.contains("confScore(m."))
    } finally {
        removeTree(root)
    }
}


/// 符号级关系源码锁：文件作用域必须画出符号间调用边（FG.functionEdges），
/// guessed（词法不确定）边必须虚线且动画；本作用域外的端点聚合成 boundary
/// 节点而不是静默丢弃。符号级索引是代码图谱的原子层——画布只画到文件级 =
/// 「符号级索引」名不副实（用户验收原话：还是文件级别的索引哦）。
/// 2026-10-12 参考稿重设计：旧「符号层第三视图」（drawSyms/enterSyms）退役，
/// 同一语义改为「文件作用域内的符号节点 + 边界聚合」。
@Test
func testTreeSymbolLayerDrillAndEdges(): Unit {
    let root = writeTree()
    try {
        let g = buildGraph(root)
        let js = jsNoComment(driverJsOf(treeCanvasHtml(g, 0, false, analyzeConfidence(g, false))))
        // 前提守卫（不变量 22）：被断言的接缝真的在产物里
        @Assert(js.contains("FG.functionEdges"))
        // 符号节点进作用域：file 节点的 children = 符号 id（mapCurrentGraph 消费）
        @Assert(js.contains("SYM_OF_FILE"))
        // 符号置信度 = 同一个公式的符号视角（罚分 Σ 符号内 finding 权重）
        @Assert(js.contains("confScore(pen, 1)"))
        // guessed 边独立类型且虚线动画（行军蚁 lineDashOffset）——不确定要看得出来
        @Assert(js.contains("'guessed' ? 'guessed' : 'call'"))
        // 颜色经 cv 取（嵌入模式下走宿主令牌），独立打开时回落到原来的黄
        @Assert(js.contains("guessed: { label: T.relGuessed, color: cv('yellow', '#ffc857'), dash: [5, 4] }"))
        @Assert(js.contains("setLineDash(rel.dash)"))
        @Assert(js.contains("lineDashOffset"))
        // 作用域外的被调方 = boundary 节点聚合（不得静默丢边），带软上限
        @Assert(js.contains("function ensureBoundary"))
        @Assert(js.contains("boundaryUsed"))
        // 下钻接缝：双击进入子图（时间窗判双击）；单击只选中
        @Assert(js.contains("function handleDoubleClick"))
        @Assert(js.contains("function enterScope"))
        @Assert(js.contains("lastClickTime"))
        // 阈值滑块 = 置信度过滤（节点隐藏 + 边强度下限）
        @Assert(js.contains("n.confidence < threshold"))
        @Assert(js.contains("strengthOf"))
    } finally {
        removeTree(root)
    }
}



// MARK: - SQLite 图库/置信度库（graph db / confidence db）
//
// 【为什么是自由调用夹具】边的来源是**解析后的调用点**（resolve.cj）：裸调用
// `trimAll(` 在全工程（同语言）恰有一个同名定义 ⇒ resolved，断言钉的就是这一档。
// 夹具不写成接收者调用 `t.trimAll()`：接收者按**裸名**解析，行为相同但这条测试
// 想钉的是最朴素的「跨文件唯一命中」形态，多一个接收者只会让失败原因变含糊
//（不变量 22 的形态：抓到 0 个 = 检查不存在——所以先断言夹具真的有节点和边）。
func dbTreeFixture(): String {
    let root = testRoot()
    ensureDir("${root}/util")
    ensureDir("${root}/flow")
    writeFileAtomic("${root}/util/text.cj", """
package cambium.util

public func trimAll(s: String): String {
    return s
}
""")
    writeFileAtomic("${root}/flow/update.cj", """
package cambium.flow

import cambium.util.*

public func runUpdate(): Bool {
    return trimAll("  x  ").isEmpty()
}
""")
    return root
}


@Test
func testGraphDbWriteRoundTrip(): Unit {
    let root = dbTreeFixture()
    try {
        let graph = buildGraph(root)
        // 词法置信度（不依赖 ast-grep 是否安装）：functionGraphData 需要
        // 一份 ConfidenceReport 才能构造——这是公开签名，不是绕路
        let conf = analyzeConfidence(graph, false)
        let payload = functionGraphData(graph, conf, true)
        let fns = match (Json.get(payload, "functions")) {
            case Some(JArr(a)) => a
            case _ => ArrayList<JsonValue>()
        }
        let eds = match (Json.get(payload, "functionEdges")) {
            case Some(JArr(a)) => a
            case _ => ArrayList<JsonValue>()
        }
        // 前提守卫（不变量 18）：夹具必须真的有节点和边，否则下面的
        // round-trip 断言全部空转着变绿
        @Assert(Int64(fns.size) >= 2)
        @Assert(Int64(eds.size) >= 1)

        let dbPath = root + "/codegraph.db"
        @Assert(graphDbWrite(dbPath, graph, payload))

        // 用同一绑定层**只读**重开：写入器产出的库不依赖写权限也可读
        let ro1 = SqliteDb.openReadonly(dbPath)
        @Assert(ro1.isSome())
        let db = ro1.getOrThrow()
        // 行数对齐：nodes == functions 数、edges == functionEdges 数
        @Assert(dbScalar(db, "SELECT COUNT(*) FROM nodes") == Int64(fns.size).toString())
        @Assert(dbScalar(db, "SELECT COUNT(*) FROM edges") == Int64(eds.size).toString())
        // meta 与表行数自洽（agent 速览数字必须对得上表）
        @Assert(dbScalar(db, "SELECT value FROM meta WHERE key='generator'") == GRAPH_DB_GENERATOR)
        @Assert(dbScalar(db, "SELECT value FROM meta WHERE key='symbols'") == Int64(fns.size).toString())
        @Assert(dbScalar(db, "SELECT value FROM meta WHERE key='files'") == Int64(graph.files.size).toString())
        // 按名找符号（idx_nodes_name 服务的查询）
        @Assert(dbScalar(db, "SELECT COUNT(*) FROM nodes WHERE name='trimAll'") == "1")
        // 「查 X 的 callers」：A 调 B ⇒ B 的 callers 含 A（边方向：src=调用方）
        @Assert(dbScalar(db,
            "SELECT COUNT(*) FROM edges e JOIN nodes c ON e.src=c.id JOIN nodes f ON e.dst=f.id WHERE f.name='trimAll' AND c.name='runUpdate'") == "1")
        // tier 确信度分层：跨文件且全库唯一 → resolved
        @Assert(dbScalar(db,
            "SELECT e.tier FROM edges e JOIN nodes c ON e.src=c.id JOIN nodes f ON e.dst=f.id WHERE f.name='trimAll'") == "resolved")
        db.close()

        // 幂等：单文件产物语义——已存在则先删重建，重写后行数不变
        @Assert(graphDbWrite(dbPath, graph, payload))
        let ro2 = SqliteDb.openReadonly(dbPath)
        @Assert(ro2.isSome())
        let db2 = ro2.getOrThrow()
        // ⚠️ 必须用**新连接**查：旧连接的 fd 指向已被 unlink 的旧 inode
        @Assert(dbScalar(db2, "SELECT COUNT(*) FROM nodes") == Int64(fns.size).toString())
        @Assert(dbScalar(db2, "SELECT COUNT(*) FROM edges") == Int64(eds.size).toString())
        db2.close()
    } finally {
        removeTree(root)
    }
}


@Test
func testConfidenceDbWriteRoundTrip(): Unit {
    let root = testRoot()
    try {
        // testRoot() 只返回路径不建目录；sqlite 的 CREATE 只建文件不建父目录
        ensureDir(root)
        // 手工报告（完全确定）：注入的 evidence 必须原样回到列里
        let findings = ArrayList<Finding>()
        findings.add(Finding(MagicNumber, "a.cj", 3, "v", "magic 17 used 3 times"))
        findings.add(Finding(TodoResidue, "a.cj", 9, "w", "TODO fix later"))
        let byKind = ArrayList<(FlawKind, Int64)>()
        byKind.add((MagicNumber, 1))
        byKind.add((TodoResidue, 1))
        let files = ArrayList<(String, Int64)>()
        files.add(("a.cj", 5))
        let dims = ArrayList<(ConfDimension, Int64, Int64, Int64)>()
        dims.add((DimStructure, 5, 2, 80))
        let report = ConfidenceReport(root, 66, findings, false,
            "按调用方要求跳过语法树（--no-ast），仅词法级分析", 2,
            byKind, files, dims, cappedKind: true, cappedTotal: false)

        let dbPath = root + "/confidence.db"
        @Assert(confidenceDbWrite(dbPath, report))

        let ro = SqliteDb.openReadonly(dbPath)
        @Assert(ro.isSome())
        let db = ro.getOrThrow()
        // meta.score 与报告一致；限流披露按真值落库
        @Assert(dbScalar(db, "SELECT value FROM meta WHERE key='score'") == report.score.toString())
        @Assert(dbScalar(db, "SELECT value FROM meta WHERE key='ast_used'") == "0")
        @Assert(dbScalar(db, "SELECT value FROM meta WHERE key='capped_kind'") == "1")
        @Assert(dbScalar(db, "SELECT value FROM meta WHERE key='capped_total'") == "0")
        @Assert(dbScalar(db, "SELECT value FROM meta WHERE key='root'") == root)
        // findings 行数一致
        @Assert(dbScalar(db, "SELECT COUNT(*) FROM findings") == "2")
        // 注入 finding 的 evidence 原样在列（kind/dim/weight 同口径）
        @Assert(dbScalar(db, "SELECT evidence FROM findings WHERE file='a.cj' AND line=3") == "magic 17 used 3 times")
        @Assert(dbScalar(db, "SELECT kind FROM findings WHERE line=9") == "todo-residue")
        @Assert(dbScalar(db, "SELECT dim FROM findings WHERE line=3") == "function")
        @Assert(dbScalar(db, "SELECT weight FROM findings WHERE line=3") == "3")
        // dimensions / files 行数
        @Assert(dbScalar(db, "SELECT COUNT(*) FROM dimensions") == "1")
        @Assert(dbScalar(db, "SELECT score FROM dimensions WHERE dim='structure'") == "80")
        @Assert(dbScalar(db, "SELECT penalty FROM files WHERE file='a.cj'") == "5")
        db.close()

        // 幂等：重写后行数不变
        @Assert(confidenceDbWrite(dbPath, report))
        let ro2 = SqliteDb.openReadonly(dbPath)
        @Assert(ro2.isSome())
        let db2 = ro2.getOrThrow()
        @Assert(dbScalar(db2, "SELECT COUNT(*) FROM findings") == "2")
        db2.close()
    } finally {
        removeTree(root)
    }
}


/// store_meta round-trip：写 → 读 probe/update_count/generated_at/depth。
/// 旧式 graphDbWrite（无 store_meta 行）读出 updateCount = -1（无记录）；
/// 库不存在 → None。
@Test
func testStoreMetaRoundTrip(): Unit {
    let root = writeTree()
    let dbPath = "${root}.db"
    try {
        let g = buildGraph(root)
        let probe = sourceProbeNow(root)
        let rows = ArrayList<(String, JsonValue)>()
        rows.add(("source_probe", probe.toJson()))
        rows.add(("update_count", Json.of(3)))
        rows.add(("generated_at", Json.of("2026-10-12T00:00:00+08:00")))
        rows.add(("depth", Json.of(2)))
        @Assert(graphDbWriteWithMeta(dbPath, g, functionGraphData(g, analyzeConfidence(g, false), false), rows))
        match (indexMetaRead(dbPath)) {
            case Some(m) =>
                @Assert(m.updateCount == 3)
                @Assert(m.generatedAt == "2026-10-12T00:00:00+08:00")
                @Assert(m.depth == 2)
                match (m.probe()) {
                    case Some(back) => @Assert(probeMatches(back, probe))
                    case None => @Assert(false)
                }
            case None => @Assert(false)
        }
        // 数值键以 INTEGER 落库，TEXT 读侧也能取回（sqlite 自动转换）
        let ro = SqliteDb.openReadonly(dbPath)
        @Assert(ro.isSome())
        let db = ro.getOrThrow()
        var ucText = ""
        let stOpt = db.prepare("SELECT value FROM store_meta WHERE key = 'update_count'")
        @Assert(stOpt.isSome())
        let st = stOpt.getOrThrow()
        if (st.stepHasRow()) { ucText = st.columnText(0) }
        st.finalize()
        db.close()
        @Assert(ucText == "3")
        // 旧式写入（无 store_meta 行）：表在、行不在 → 无记录语义
        @Assert(graphDbWrite(dbPath, g, functionGraphData(g, analyzeConfidence(g, false), false)))
        match (indexMetaRead(dbPath)) {
            case Some(m) =>
                @Assert(m.updateCount == -1)
                @Assert(m.probeText.isEmpty())
                @Assert(m.payloadShape == 0)      // 没有这一行 = 0（更早的构建写的）
            case None => @Assert(false)
        }
        // 库不存在
        removePathIfExists(dbPath)
        @Assert(indexMetaRead(dbPath).isNone())
    } finally {
        removePathIfExists(dbPath)
        removeTree(root)
    }
}


/// `index gen --format json` 的键集 = INDEX_JSON_KEYS（11 契约键 + 新增恒发键），
/// 投影不多不少；11 契约键的值与 fullGraphJson 同源同值。
@Test
func testIndexContractJsonKeySetIsExactlyDeclared(): Unit {
    let root = writeTree()
    try {
        let g = buildGraph(root)
        let conf = analyzeConfidence(g, false)
        let payload = indexPayloadForStore(g, 6, conf, sourceProbeNow(root), 0, "T0", false)
        let contract = indexContractJson(payload)
        // 键集精确相等：多一个少一个都红（投影按清单来，清单只有一份）
        var got: Int64 = 0
        match (contract) {
            case JObj(m) =>
                for ((k, _) in m) {
                    got += 1
                    @Assert(INDEX_JSON_KEYS.contains(k))
                }
            case _ => @Assert(false)
        }
        @Assert(got == Int64(INDEX_JSON_KEYS.size))
        for (k in INDEX_JSON_KEYS) {
            @Assert(Json.has(contract, k))
        }
        // 11 契约键与 fullGraphJson 同源同值（键名不动 = 机读出口零破坏）
        let full = fullGraphJson(g, 6)
        for (k in ["root", "files", "importEdges", "referenceEdges", "truncated",
                   "skipped", "oversizeSkipped", "unreadableDirs",
                   "unreadableDirsTruncated", "depth", "depthOmitted"]) {
            @Assert(Json.pretty(Json.getOr(contract, k)) == Json.pretty(Json.getOr(full, k)))
        }
        @Assert(Json.intAt(contract, "updateCount", -1) == 0)
        @Assert(Json.intAt(contract, "tierFiles", -1) == Int64(Json.arrAt(full, "files").size))
        // 持久化 payload 比出口多渲染域键（functionGraph 等），但不串进出口
        @Assert(Json.has(payload, "functionGraph"))
        @Assert(!Json.has(contract, "functionGraph"))
        @Assert(!Json.has(contract, "confidence"))
        @Assert(!Json.has(contract, "langThemes"))
    } finally {
        removeTree(root)
    }
}


/// renderIndexHtml 两段拆分的行为锁：
/// ① 纯函数确定性——同 payload + 同 conf 同 confMissing ⇒ 逐字节一致；
/// ② updateCount/generatedAt 内嵌注释与读取器 round-trip；无 updateCount
///    的 payload（兼容面）没有注释，读取器 None；
/// ③ conf 覆盖改变产物；confMissing 打标记且图例文案在场；
/// ④ treeCanvasHtml ≡ indexPayload + renderIndexHtml 的组合（旧签名零漂移）。
@Test
func testRenderIndexHtmlTwoStageContract(): Unit {
    let root = writeTree()
    try {
        let g = buildGraph(root)
        let conf = analyzeConfidence(g, false)
        let probe = sourceProbeNow(root)
        let p0 = indexPayloadForStore(g, 6, conf, probe, 0, "T0", false)
        let h1 = renderIndexHtml(p0, None<JsonValue>, false, false)
        let h2 = renderIndexHtml(indexPayloadForStore(g, 6, conf, probe, 0, "T0", false), None<JsonValue>, false, false)
        // ① 确定性：同输入重建 payload 再渲染，逐字节一致
        @Assert(h1 == h2)
        // ② 注释内嵌 + 读取器
        @Assert(h1.contains("updateCount=0"))
        @Assert(h1.contains("generatedAt=T0"))
        @Assert(renderIndexEmbeddedUpdateCount(h1) == Some<Int64>(0))
        @Assert(renderIndexEmbeddedGeneratedAt(h1) == "T0")
        @Assert(renderIndexEmbeddedGeneratedAt("<html>plain</html>") == "")
        let h5 = renderIndexHtml(indexPayloadForStore(g, 6, conf, probe, 5, "T5", false), None<JsonValue>, false, false)
        @Assert(renderIndexEmbeddedUpdateCount(h5) == Some<Int64>(5))
        // 无标记的文本（旧产物形状）→ None，绝不猜成 0
        @Assert(renderIndexEmbeddedUpdateCount("<html>plain</html>").isNone())
        // 兼容面（treeCanvasHtml）：payload 无 updateCount → 无注释 → 读取器 None
        let compat = treeCanvasHtml(g, 6, false, conf)
        @Assert(renderIndexEmbeddedUpdateCount(compat).isNone())
        // ④ 兼容面 ≡ 两段组合（临时 payload + 无覆盖 + 无标记）
        @Assert(compat == renderIndexHtml(indexPayload(g, 6, conf, false), None<JsonValue>, false, false))
        // ③ conf 覆盖改变产物（注入一个明显不同的置信度对象）
        let fake = Json.obj()
        Json.set(fake, "score", Json.of(42))
        Json.set(fake, "astUsed", Json.of(false))
        Json.set(fake, "astNote", Json.of("覆盖测试"))
        Json.set(fake, "cappedTotal", Json.of(false))
        Json.set(fake, "cappedKind", Json.of(false))
        Json.set(fake, "files", JArr(ArrayList<JsonValue>()))
        Json.set(fake, "findings", JArr(ArrayList<JsonValue>()))
        let hOverlay = renderIndexHtml(indexPayloadForStore(g, 6, conf, probe, 0, "T0", false), Some<JsonValue>(fake), false, false)
        @Assert(hOverlay != h1)
        @Assert(hOverlay.contains("覆盖测试"))
        // confMissing：payload 打标记 + 图例文案在场（不伪造分数）
        let hMissing = renderIndexHtml(indexPayloadForStore(g, 6, conf, probe, 0, "T0", false), None<JsonValue>, false, true)
        @Assert(hMissing != h1)
        @Assert(hMissing.contains("confMissing"))
        @Assert(hMissing.contains("无置信度数据"))
    } finally {
        removeTree(root)
    }
}


// MARK: - 行首 `*` 的代码行不是块注释续行（阶段二 · 扫描器修复）

/// 修前 stripCode / stripLineComment / stripComment 都按「行首是 `*`」猜这一行是块注释
/// 续行并整行剥掉。`*errOut = f(x);` 这类解引用赋值于是从所有词法事实里消失：调用点
/// 不采；符号级孤儿检测（referencedNames）看不到这次调用，**被调用的函数反被报成
/// orphan**（探针工程实测 SecretStore::saveFailure）。是否在块注释里由跨行状态决定。
/// 正控：真在 `/* … */` 里的续行（带不带 `*` 前缀）照旧剥掉。
@Test
func testStarPrefixedCodeLineIsNotAComment(): Unit {
    // ── stripCode：块注释外，行首 `*` 是代码（无引号快路径 / 有引号慢路径一致）──
    let (code, st0) = stripCode("    *errOut = saveFailure(err && 1);", 0)
    @Assert(code.contains("saveFailure("))
    @Assert(st0 == 0)
    let (code2, _) = stripCode("    *s = \"x\"; saveFailure(2); // tail", 0)
    @Assert(code2.contains("saveFailure(2);"))
    @Assert(!code2.contains("tail"))

    // ── 正控：块注释里的行由状态剥掉（续行不带 `*` 也一样），闭合后恢复 ──
    let block = ["int a = 1; /* open", " * fakeCall(1) and { a brace",
        "   no star prefix either, fakeCall(2)", " */", "*errOut = saveFailure(3);"]
    var st: Int64 = 0
    let kept = ArrayList<String>()
    for (line in block) {
        let (t, next) = stripCode(line, st)
        st = next
        kept.add(t)
    }
    @Assert(kept[0] == "int a = 1; ")
    @Assert(kept[1] == "" && kept[2] == "" && kept[3] == "")
    @Assert(kept[4].contains("saveFailure(3);"))
    @Assert(st == 0)
    let (d1, n1) = stripCode("/* doc", 0)
    let (d2, n2) = stripCode(" * more doc fakeCall(9)", n1)
    @Assert(d1 == "" && d2 == "")
    @Assert(n2 == 3)
    let (d3, n3) = stripCode(" */ *errOut = saveFailure(4);", n2)
    @Assert(d3.contains("saveFailure(4);"))
    @Assert(n3 == 0)

    // ── stripComment 族（无字符串状态，供「使用证据」与 AST 路径用）──
    @Assert(stripComment("    *errOut = saveFailure(1);").contains("saveFailure("))
    let (c1, b1) = stripCommentTracked("/* doc", false)
    @Assert(c1 == "" && b1)
    let (c2, b2) = stripCommentTracked(" * more doc", b1)
    @Assert(c2 == "" && b2)
    let (c3, b3) = stripCommentTracked("   no star, still comment", b2)
    @Assert(c3 == "" && b3)
    let (c4, b4) = stripCommentTracked(" */ *errOut = saveFailure(2);", b3)
    @Assert(c4.contains("saveFailure(2);") && !b4)
    let (c5, b5) = stripCommentTracked("    *errOut = saveFailure(3); // tail", b4)
    @Assert(c5.contains("saveFailure(3);") && !c5.contains("tail") && !b5)
    // AST 路径的两个消费方跟着走状态：整块注释 = 空体；`*out = …` 是代码
    @Assert(removeCommentsAndBlanks("{\n    /* TODO\n       implement\n    */\n}\n") == "")
    @Assert(removeCommentsAndBlanks("{\n    *out = saveFailure(1);\n}\n").contains("saveFailure"))
    // 修前「不带 * 的注释续行」被当成代码数进去（7 被计为魔法数字）
    @Assert(countMagicNumbers("/* note 42\n   plain continuation 7\n */\nint a = 3;") == 1)

    // ── 端到端：调用点进了索引，名字算被引用，不再报孤儿 ──
    let root = testRoot()
    try {
        writeFileAtomic("${root}/star.c", """
/* header comment
 * fakeCall(1)
   unusedHelper mentioned in a comment line without star prefix
 */
int saveFailure(int code)
{
    return code;
}

int unusedHelper(int v)
{
    return v;
}

int caller(int *errOut)
{
    *errOut = saveFailure(1);
    return 0;
}
""")
        let g = buildGraph(root)
        var sawCall = false
        for (s in g.callSites) {
            @Assert(s.name != "fakeCall")
            if (s.name == "saveFailure") {
                sawCall = true
                @Assert(s.line == 17)
                @Assert(s.tier == "resolved")
                @Assert(s.dst == "f:star.c:5:saveFailure")
            }
        }
        @Assert(sawCall)
        @Assert(g.referencedNames.contains("saveFailure"))
        // 注释里的提及（带不带 `*` 前缀）都不算使用
        @Assert(!g.referencedNames.contains("unusedHelper"))
        let rep = analyzeConfidence(g, false)
        var orphanUnused = false
        for (f in rep.findings) {
            if (flawId(f.kind) == "orphan" && f.symbol == "saveFailure") { @Assert(false) }
            if (flawId(f.kind) == "orphan" && f.symbol == "unusedHelper") { orphanUnused = true }
        }
        @Assert(orphanUnused)
    } finally {
        removeTree(root)
    }
}


// MARK: - 疑点挂符号键（阶段二 A）

/// finding 带符号键 id / qual：与 codegraph.db 的 nodes.sid 是同一个键、同一个格式
/// （同一次 scanSource、同一个 SymDecl.id 公式），置信度 / 热力图 / 索引靠它对账。
///
/// 挂靠规则：① 疑点位置上正好是同名声明 ⇒ 它自己；② 否则疑点所在的最内层符号
/// （幻觉调用挂到调用它的函数上）；都不是 ⇒ 空串（不编句柄）。
/// 键集恒定：confidenceJson / confidenceEmbedJson（中英）/ functionGraph 内嵌三个出口、
/// 有疑点与空报告两种数据状态，finding 对象的键集都等于 FINDING_JSON_KEYS。
@Test
func testFindingsCarrySymbolKeysSharedWithIndex(): Unit {
    let root = testRoot()
    try {
        writeFileAtomic("${root}/a.h", "int deadHelper(int v);\n")
        writeFileAtomic("${root}/a.c", """
// TODO: wire this into the tray
int deadHelper(int v)
{
    return v;
}

int worker(int *out)
{
    *out = ghostCall(7);
    return 0;
}
""")
        let g = buildGraph(root)
        // 索引侧的键：同一份符号表、同一个公式
        let idWorker = "f:a.c:7:worker"
        let idDead = "f:a.c:2:deadHelper"
        let indexIds = HashSet<String>()
        for (fe in g.files) {
            for (s in fe.symbols) { indexIds.add(s.id(fe.relPath)) }
        }
        @Assert(indexIds.contains(idWorker))
        @Assert(indexIds.contains(idDead))

        // ── 挂靠规则（单元）──
        let fs = ArrayList<Finding>()
        fs.add(Finding(TodoResidue, "a.c", 1, "", "x"))               // 文件头：不在任何符号里
        fs.add(Finding(UnresolvedCall, "a.c", 9, "ghostCall", "x"))   // 在 worker 里
        fs.add(Finding(Orphan, "a.c", 2, "deadHelper", "x"))          // 同名声明
        fs.add(Finding(Orphan, "a.h", 1, "deadHelper", "x"))          // 原型行：声明处也是符号
        fs.add(Finding(MagicNumber, "gone.c", 3, "v", "x"))           // 文件不在图里
        attachSymbolKeys(g, fs)
        @Assert(fs[0].symId == "" && fs[0].qual == "")
        @Assert(fs[1].symId == idWorker && fs[1].qual == "worker")
        @Assert(fs[2].symId == idDead && fs[2].qual == "deadHelper")
        @Assert(fs[3].symId == "f:a.h:1:deadHelper" && fs[3].qual == "deadHelper")
        @Assert(fs[4].symId == "" && fs[4].qual == "")

        // ── 端到端：检测器产出的 finding 自动带上，且挂上的 id 索引里一定有 ──
        let rep = analyzeConfidence(g, false)
        var sawDead = false
        var sawGhost = false
        for (f in rep.findings) {
            if (!f.symId.isEmpty()) { @Assert(indexIds.contains(f.symId)) }
            if (flawId(f.kind) == "orphan" && f.file == "a.c" && f.symbol == "deadHelper") {
                sawDead = true
                @Assert(f.symId == idDead && f.qual == "deadHelper")
            }
            if (flawId(f.kind) == "unresolved-call" && f.symbol == "ghostCall") {
                sawGhost = true
                @Assert(f.symId == idWorker && f.qual == "worker")
            }
        }
        @Assert(sawDead)
        @Assert(sawGhost)

        // ── 键集恒定：三个出口 × 中英 × 有疑点 ──
        let keysText = joinStrings(FINDING_JSON_KEYS, " ")
        let exits = ArrayList<JsonValue>()
        exits.add(confidenceJson(rep))
        exits.add(confidenceEmbedJson(rep, false))
        exits.add(confidenceEmbedJson(rep, true))
        exits.add(functionGraphData(g, rep, false))
        var checked: Int64 = 0
        for (e in exits) {
            if (Json.has(e, "findings")) {
                for (o in Json.arrAt(e, "findings")) {
                    @Assert(keysAre(o, keysText))
                    checked += 1
                }
            }
            if (Json.has(e, "functions")) {
                for (fn in Json.arrAt(e, "functions")) {
                    for (o in Json.arrAt(fn, "findings")) {
                        @Assert(keysAre(o, keysText))
                        checked += 1
                    }
                }
            }
        }
        // 夹具里有 4 条带符号的 finding（孤儿检测不重复报原型，见 testOrphanUsesCallEvidenceAndSkipsDeclTwins）：
        // 三个出口各 4 条 + 符号节点内嵌 2 条
        @Assert(checked >= 14)
        // 空报告：findings 是空数组（键照样在）
        let empty = ConfidenceReport(root, 100, ArrayList<Finding>(), false, "",
            Int64(g.files.size), ArrayList<(FlawKind, Int64)>(), ArrayList<(String, Int64)>(),
            ArrayList<(ConfDimension, Int64, Int64, Int64)>())
        @Assert(Json.arrAt(confidenceJson(empty), "findings").size == 0)
        @Assert(Json.arrAt(confidenceEmbedJson(empty, false), "findings").size == 0)

        // ── confidence.db：findings 表带 sid / qual，与 JSON 同源 ──
        let dbPath = root + "/confidence.db"
        @Assert(confidenceDbWrite(dbPath, rep))
        let ro = SqliteDb.openReadonly(dbPath).getOrThrow()
        @Assert(dbScalar(ro, "SELECT value FROM meta WHERE key='generator'") == "moongit confidence db v2")
        @Assert(dbScalar(ro, "SELECT sid || '|' || qual FROM findings WHERE kind='unresolved-call'") == idWorker + "|worker")
        @Assert(dbScalar(ro, "SELECT sid || '|' || qual FROM findings WHERE kind='orphan' AND file='a.c'") == idDead + "|deadHelper")
        // 定位不到：列在、值是空串（不是 NULL——键集与类型都不随数据漂）
        @Assert(dbScalar(ro, "SELECT COUNT(*) FROM findings WHERE sid IS NULL OR qual IS NULL") == "0")
        @Assert(dbScalar(ro, "SELECT COUNT(*) FROM findings WHERE sid = ''") == "1")
        ro.close()
    } finally {
        removeTree(root)
    }
}


// MARK: - 热力图定位串与复制（阶段二 D）

/// render/index.html（treehtml.cj 生成）的定位与复制钩子。
///   ① 符号节点带成员级三键 qual / col / sig（id / line 原有）——恒发；
///   ② 详情面板的定位区：定位串 相对路径:行:列（一键复制）、限定名、签名、「复制符号 ID」；
///   ③ 复制带兜底：file:// 页面没有剪贴板权限——navigator.clipboard 不可用 / 被拒时走
///      隐藏 textarea + execCommand('copy')；
///   ④ 疑点按符号键绑到节点上（finding.id 优先，行号只作退路）；
///   ⑤ 持久化产物里没有本机绝对路径：页面数据不内嵌 root（项目目录）。graph tree 的临时
///      payload（兼容面）不变，root 仍是 graph tree --json / index gen --json 的契约键；
///   ⑥ 复用判定的两个内嵌标记不受影响。
/// 真实渲染与剪贴板行为由客户端 WebView 实拍验证（本机没有浏览器）；这里钉的是产物
/// 含这些钩子，以及两种语言面各自的文案。
@Test
func testIndexHtmlSymbolLocatorAndCopyHooks(): Unit {
    let root = testRoot()
    try {
        writeFileAtomic("${root}/a/util.kt", """
package a

class Util {
    fun twice(x: Int): Int {
        return x * 2
    }
}
""")
        let g = buildGraph(root)
        let rep = analyzeConfidence(g, false)
        let payload = indexPayloadForStore(g, 0, rep, sourceProbeNow(root), 0, "2026-11-25T00:00:00Z", false)
        // ① 成员级三键
        var sawTwice = false
        for (fn in Json.arrAt(Json.getOr(payload, "functionGraph"), "functions")) {
            @Assert(Json.has(fn, "qual") && Json.has(fn, "col") && Json.has(fn, "sig"))
            if (Json.strAt(fn, "id", "") == "f:a/util.kt:4:twice") {
                sawTwice = true
                @Assert(Json.strAt(fn, "qual", "") == "Util.twice")
                @Assert(Json.intAt(fn, "col", 0) == 9)
                @Assert(Json.strAt(fn, "sig", "") == "fun twice(x: Int): Int")
            }
        }
        @Assert(sawTwice)
        // 契约键 root 在 payload 里（index gen --json 的出口照发）
        @Assert(Json.strAt(payload, "root", "") == root)

        // ② ③ ④ ⑤ ⑥
        let html = renderIndexHtml(payload, None<JsonValue>, false)
        @Assert(html.contains("function locatorSection"))
        // 文案走 T 表（驱动里的注释是静态中文，两种语言面都有——断言锚在 T 表的键值上）
        @Assert(html.contains("copySymbolId: \"复制符号 ID\""))
        @Assert(html.contains("locator: \"定位串\""))
        @Assert(html.contains("qualName: \"限定名\""))
        @Assert(html.contains("data-copy="))
        @Assert(html.contains("navigator.clipboard.writeText"))
        @Assert(html.contains("document.execCommand('copy')"))
        @Assert(html.contains("createElement('textarea')"))
        @Assert(html.contains("clip-fallback"))
        @Assert(html.contains("NODES[f.id].file === fe.path"))   // 按符号键绑疑点（行号只作退路）
        @Assert(!html.contains(root))
        @Assert(!html.contains("\"root\""))
        match (renderIndexEmbeddedUpdateCount(html)) {
            case Some(n) => @Assert(n == 0)
            case None => @Assert(false)
        }
        @Assert(renderIndexEmbeddedGeneratedAt(html) == "2026-11-25T00:00:00Z")
        // 确定性
        @Assert(html == renderIndexHtml(payload, None<JsonValue>, false))

        // ⑤ 兼容面：临时 payload 的形状不变（root 仍在）
        let compat = treeCanvasHtml(g, 0, false, rep)
        @Assert(compat.contains("\"root\""))
        @Assert(compat.contains(root))

        // 英文面
        let en = renderIndexHtml(indexPayloadForStore(g, 0, rep, sourceProbeNow(root), 0, "2026-11-25T00:00:00Z", true),
            None<JsonValue>, true)
        @Assert(en.contains("copySymbolId: \"Copy symbol ID\""))
        @Assert(en.contains("qualName: \"Qualified name\""))
        @Assert(!en.contains("copySymbolId: \"复制符号 ID\""))
    } finally {
        removeTree(root)
    }
}

/// 单值查询 helper。prepare/step 失败时返回带原因的占位文本——
/// 断言会以「值不相等」失败并直接看到原因，而不是静默空串。
func dbScalar(db: SqliteDb, sql: String): String {
    let stOpt = db.prepare(sql)
    if (stOpt.isNone()) { return "<prepare failed: ${sql}>" }
    let st = stOpt.getOrThrow()
    if (!st.stepHasRow()) {
        st.finalize()
        return "<no row: ${sql}>"
    }
    let v = st.columnText(0)
    st.finalize()
    return v
}

/// M2 源码守卫：AST 批**全部失败**时必须降级（返回 None），
/// 不能返回 Some(空列表) 让调用方报 astUsed=true。
///
/// 为什么不用行为断言：这条路径需要「ast-grep 能跑但每个批次都失败」，
/// 而测试沙箱里要么 ast-grep 不在、要么全部文件都是仓颉（无 tree-sitter 语法）
/// —— 批次数为 0，分支根本进不去。测不了的路径就用源码守卫钉住接缝，
/// 并在注释里如实说明这是源码级保证、不是行为级保证。
@Test
func __lintAstBatchFailureDegradesInsteadOfClaimingSuccess(): Unit {
    let raw = readFileTextChecked("src/dendro/confidence_ast.cj").getOrThrow()
    let sb = StringBuilder()
    var blk = CjStripState.Normal
    for (r in raw.split("\n")) {
        let (l, nb) = stripCjCommentEx(r, blk)
        blk = nb
        sb.append(l)
        sb.append("\n")
    }
    let code = sb.toString()
    // 判据是「全部批失败 ⇒ return None」这个组合
    let guard = code.indexOf("failedBatches == totalBatches")
    @Assert(guard.isSome())
    let after = code[guard.getOrThrow()..]
    let none = after.indexOf("return None")
    @Assert(none.isSome())
    // 同一个 if 块内就要 return None，不许隔到别的分支
    @Assert(none.getOrThrow() < 200)
    // 且清理临时目录必须发生在返回之前（用完即清）
    @Assert(after.indexOf("cleanupAstTmpDirs", 0).isSome())
}

/// G7：阈值只许住在 confidence.cj 的常量区——判据与证据文案都从常量派生
/// （confidence_detect.cj 文件头的纪律）。裸字面量判据 = 「一处改了另一处
/// 忘了」的漂移源。为什么读源断言：AST 路径需要 ast-grep 环境，行为测试
/// 在沙箱里覆盖不到它；「两条路径同值」由「引用同一个常量」结构性保证。
/// ⚠️ 先剥注释再匹配（不变量 30：解释性注释长得和缺陷一模一样）。
@Test
func __lintConfidenceThresholdsComeFromConstants(): Unit {
    let raw = readFileTextChecked("src/dendro/confidence_detect.cj").getOrThrow()
    let sb = StringBuilder()
    var blk = CjStripState.Normal
    for (r in raw.split("\n")) {
        let (l, nb) = stripCjCommentEx(r, blk)
        blk = nb
        sb.append(l)
        sb.append("\n")
    }
    let code = sb.toString()
    // 判据引用常量：魔法数在 AST 与词法两条路径都引用（≥2 处 = 同值有接缝保证）
    @Assert(countOf(code, ">= CONF_MAGIC_NUMBERS") >= 2)
    @Assert(countOf(code, ">= CONF_COMMENTED_CODE_LINES") >= 1)
    @Assert(countOf(code, "> CONF_COMPLEXITY") >= 1)
    @Assert(countOf(code, "> CONF_PARAMS") >= 1)
    // 裸字面量判据绝迹（防止改回硬编码）
    @Assert(countOf(code, "magic >= 3") == 0)
    @Assert(countOf(code, "bodyMagic >= 3") == 0)
    @Assert(countOf(code, "codeLines >= 3") == 0)
    @Assert(countOf(code, "cc > 10") == 0)
    @Assert(countOf(code, "pCount > 5") == 0)
    // 证据文案也从常量派生（阈值数字不许手抄第二份）：
    // 拼接构造避免本测试自身的字符串插值吃掉花括号
    @Assert(code.contains("$" + "{CONF_MAGIC_NUMBERS}"))
    @Assert(code.contains("$" + "{CONF_COMPLEXITY}"))
    @Assert(code.contains("$" + "{CONF_PARAMS}"))
}

/// 源码守卫：finding 的 JSON 对象只有 findingJson 一个构造点（confidence.cj）。
/// 「形状只有一份」靠抄是守不住的——三个出口各拼一份，漏一处就分叉，而各自的
/// 测试都只验自己那一份（AGENTS.md 不变量 60）。任何一个出口重新开始手拼
/// `Json.set(o, "evidence", …)`，这里就红。
@Test
func __lintFindingJsonHasOneProducer(): Unit {
    let producers = ArrayList<String>()
    // 品牌升级后置信度文件在 Dendro 包（src/dendro），图谱文件仍在 src/graph——两处都要扫
    for (path in ["src/dendro/confidence.cj", "src/dendro/confidence_render.cj", "src/dendro/treehtml.cj",
                  "src/dendro/db.cj", "src/dendro/rendertext.cj",
                  "src/graph/db.cj", "src/graph/render.cj", "src/graph/export.cj", "src/graph/query.cj",
                  "src/graph/archscene.cj", "src/graph/arch.cj"]) {
        let rel = basename(path)
        let raw = readFileTextChecked(path).getOrThrow()
        var blk = CjStripState.Normal
        for (r in raw.split("\n")) {
            let (l, nb) = stripCjCommentEx(r, blk)
            blk = nb
            if (l.contains("\"evidence\"") && l.contains("Json.set(")) { producers.add(rel) }
        }
    }
    @Assert(producers.size == 1)
    @Assert(producers[0] == "confidence.cj")
}


/// 图谱两页的嵌入布局（2026-11-27，用户：「右侧的 tab 太大占位，需要让整张图和窗口大小进行动态调整」）。
/// 浏览器行为在仓颉测试里没有执行路径——按样式契约测试的先例，对**完整生成路径的产物**做结构断言：
/// 每条断言对应一个真实截图里看到的毛病。
@Test
func testGraphEmbedPanelIsFluidAndCollapsible(): Unit {
    let root = writeTree()
    try {
        let g = buildGraph(root)
        let html = treeCanvasHtml(g, 8, false, analyzeConfidence(g, false))
        // ① 报告面板的宽度跟视口走（原先定宽 340，再窄也占 280）：三档宽度 + 860 以下不占一列
        @Assert(html.contains("grid-template-columns:minmax(0,1fr) var(--e-side-w,340px)"))
        @Assert(html.contains("@media(max-width:1440px){html[data-embed=\"page\"]{--e-side-w:304px}"))
        @Assert(html.contains("@media(max-width:1120px){html[data-embed=\"page\"]{--e-side-w:272px}"))
        @Assert(!html.contains("grid-template-columns:minmax(0,1fr) 340px"))
        @Assert(!html.contains("grid-template-columns:minmax(0,1fr) 280px"))
        @Assert(!html.contains("minmax(0,1.3fr) minmax(0,0.9fr)"))   // 上下排：画布只剩两百来像素高
        // ② 可收起：收起态画布占满、底条横贯；窄视口下面板是盖在画布上的抽屉
        @Assert(html.contains("html[data-embed=\"page\"].side-off .sidebar{display:none}"))
        @Assert(html.contains("html[data-embed=\"page\"].side-off .main{grid-template-columns:minmax(0,1fr)}"))
        @Assert(html.contains(".sidebar{position:absolute;top:0;right:0;bottom:var(--e-foot-h,32px);width:min(320px,88vw)"))
        // ③ 驱动：按视口定默认（窄 = 收起）、手动开合记进 localStorage、点节点即展开
        @Assert(html.contains("function embSideDrawer() { return window.innerWidth < 861; }"))
        @Assert(html.contains("embSetSide(embSideWanted ? embSideWanted === 'off' : embSideDrawer(), false)"))
        @Assert(html.contains("localStorage.setItem(EMB_SIDE_KEY, embSideWanted)"))
        @Assert(html.contains("if (EMB_ON && embSideOff()) { embSetSide(false, false); }"))
        @Assert(html.contains("if (EMB_ON && embSideDrawer()) { embSetSide(true, false); }"))
        // ④ 画布上的操作提示停几秒后淡出；tab 条放不下时横向滚动 + 右缘渐隐
        @Assert(html.contains("html[data-embed=\"page\"] .canvas-msg{animation:embMsgFade .6s ease 7s forwards}"))
        @Assert(html.contains("mask-image:linear-gradient(90deg,#000 calc(100% - 18px),transparent)"))
        // ⑤ 读数与分数同一个口径：项目级疑点数取引擎的全量；截断的披露只用引擎带确切数字的那一句
        @Assert(html.contains("if (typeof CONF.findingsTotal === 'number') { NODES.project.rollN = CONF.findingsTotal; }"))
        @Assert(html.contains("if (typeof CONF.penaltyTotal === 'number') { totalPen = CONF.penaltyTotal; }"))
        @Assert(html.contains("typeof CONF.findingsTotal !== 'number') { notes.push(T.capNote); }"))
        // 部分文件降级时 astUsed 仍为 true：说明照常进披露（原先只在完全没语法树时才展示）
        @Assert(html.contains("/降级|失败|剔除|丢弃|截断|degrad|failed|dropped|truncat/i.test(CONF.astNote)"))

        // 架构图：卡内文字跟着卡片缩放；放不下就逐行让位；窄视口命令条收成一行
        let arch = archCanvasHtml(buildArch(g), false)
        @Assert(arch.contains("var ts = Math.max(0.72, Math.min(1.2, h / ch)); var tiny = h < 44;"))
        @Assert(arch.contains("y + (tiny ? h / 2 + 4 : 22 * ts)"))
        @Assert(arch.contains("if ((isArch() || isRole()) && !tiny) {"))
        @Assert(arch.contains("if (isArch() && m.roleMix && h >= 60) {"))
        // 泳道标签是文字：用宿主给的文字级颜色
        @Assert(arch.contains("(p.textCols && p.textCols[L.layer]) ? p.textCols[L.layer] : p.cols[L.layer]"))
        @Assert(arch.contains("@media(max-width:1180px){"))
        @Assert(arch.contains("html[data-embed=\"page\"] #bar .sub{display:none}"))
        @Assert(arch.contains("html[data-embed=\"page\"] #health{flex-wrap:nowrap;white-space:nowrap;overflow-x:auto"))
    } finally {
        removeTree(root)
    }
}
