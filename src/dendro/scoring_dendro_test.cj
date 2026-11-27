// scoring_dendro_test.cj —— 置信度「分数与输出」批的判据：上限只管列不列出、不管罚多少分；
// 总量与覆盖面进每一个 JSON 出口；降级说明把缺失的类别列全；补丁置信度的裁决词表归一、
// S10 不重复计入均值。每条都钉住「改坏之后会红」的那个守卫（负控见 PLAN / AGENTS 的记录）。

package cambium.dendro

import cambium.util.*
import std.collection.*
import std.convert.*
import std.env.*
import std.fs.*
import std.posix.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import cambium.graph.*

func scoringRoot(): String {
    return "${tempDirPath()}/cambium-score-${getpid()}-${nowMillis()}-${testRootSeq.fetchAdd(1)}"
}

/// n 个空函数的仓颉文件（每个函数 = 1 条 stub-body + 1 条 orphan，各 12 分）。
func emptyFuncsFile(tag: String, n: Int64): String {
    let sb = StringBuilder()
    sb.append("package p\n\n")
    var k: Int64 = 1
    while (k <= n) {
        sb.append("public func s${k}${tag}() { }\n")
        k += 1
    }
    return sb.toString()
}

/// 报告里某一类的计数（byKind；没有 = 0）。
func kindCount(rep: ConfidenceReport, kid: String): Int64 {
    for ((k, v) in rep.byKind) {
        if (flawId(k) == kid) { return v }
    }
    return 0
}

/// 每文件每类上限丢弃的条目照样罚分：原先只按列出的条目求和，一个文件里第 7 条孤儿起不罚分。
@Test
func testScoreCountsDroppedAndUnlistedFindings(): Unit {
    let root6 = scoringRoot()
    let root7 = scoringRoot()
    ensureDir(root6)
    ensureDir(root7)
    writeFileAtomic("${root6}/exactly.cj", emptyFuncsFile("", CONF_MAX_PER_KIND_PER_FILE))
    writeFileAtomic("${root7}/over.cj", emptyFuncsFile("", CONF_MAX_PER_KIND_PER_FILE + 1))
    try {
        let rep6 = analyzeConfidence(buildGraph(root6), false)
        let rep7 = analyzeConfidence(buildGraph(root7), false)
        // 对照组：恰好 6 个函数 = 12 条，罚分 144
        @Assert(rep6.findingsTotal == 12)
        @Assert(rep6.penaltyTotal == 144)
        @Assert(rep6.score == confidenceScore(144, 1))
        // 7 个函数 = 14 条；列出的只有 12 条（stub、orphan 各被每文件上限丢 1 条）
        @Assert(rep7.findingsTotal == 14)
        @Assert(Int64(rep7.findings.size) == 12)
        @Assert(rep7.penaltyTotal == 168)
        @Assert(rep7.cappedKind)
        @Assert(rep7.cappedTotal == false)
        @Assert(rep7.score == confidenceScore(168, 1))
        // 多一个空函数必须更掉分（原先两个仓库同分：第 7 条不罚）
        @Assert(rep7.score < rep6.score)
        // 聚合表吃的是全部检出的条目，不是列出的那些
        @Assert(kindCount(rep7, "stub-body") == 7)
        @Assert(kindCount(rep7, "orphan") == 7)
    } finally {
        removePathIfExists(root6)
        removePathIfExists(root7)
    }
}

/// 总量上限（400 条）只影响列不列出：分数、总量、按类别计数都按全部检出的算。
@Test
func testTotalCapOnlyHidesFindingsFromTheList(): Unit {
    let root = scoringRoot()
    ensureDir(root)
    let filesNeeded = CONF_MAX_FINDINGS / (2 * CONF_MAX_PER_KIND_PER_FILE) + 2
    var i: Int64 = 0
    while (i < filesNeeded) {
        writeFileAtomic("${root}/f${i}.cj", emptyFuncsFile("f${i}", CONF_MAX_PER_KIND_PER_FILE))
        i += 1
    }
    try {
        let rep = analyzeConfidence(buildGraph(root), false)
        let total = filesNeeded * 2 * CONF_MAX_PER_KIND_PER_FILE
        @Assert(total > CONF_MAX_FINDINGS)
        @Assert(Int64(rep.findings.size) == CONF_MAX_FINDINGS)
        @Assert(rep.cappedTotal)
        @Assert(rep.findingsTotal == total)
        @Assert(rep.penaltyTotal == total * flawWeight(StubBody))
        @Assert(rep.score == confidenceScore(total * flawWeight(StubBody), filesNeeded))
        // 披露里说清「罚分已计入总分」
        @Assert(rep.astNote.contains("罚分已计入总分"))
        @Assert(rep.astNote.contains("${total - CONF_MAX_FINDINGS} 条"))
    } finally {
        removePathIfExists(root)
    }
}

/// 降级说明把语法树独有的 7 类信号逐类列全（原先只说「吞错与重复体」）；
/// 两个 JSON 出口（confidenceJson / 内嵌与快照形态）都带总量与覆盖面。
@Test
func testDegradedNoteListsEveryUnavailableKind(): Unit {
    let root = scoringRoot()
    ensureDir(root)
    writeFileAtomic("${root}/a.cj", "package p\n\npublic func used(): Int64 { return 1 }\n\npublic func caller(): Int64 { return used() }\n")
    try {
        let rep = analyzeConfidence(buildGraph(root), false)
        let seven = ["swallowed-error", "duplicate-body", "unused-variable", "empty-type", "god-class",
            "lock-imbalance", "lock-unknown-call"]
        for (k in seven) {
            @Assert(rep.astNote.contains(k))
        }
        @Assert(rep.coverage.kindsUnavailable.size == 7)
        @Assert(rep.coverage.astFiles == 0)
        @Assert(rep.coverage.lexicalFiles == 1)
        let j = confidenceJson(rep)
        for (k in ["findingsTotal", "penaltyTotal", "coverage"]) {
            @Assert(Json.has(j, k))
        }
        @Assert(Json.intAt(j, "findingsTotal", -1) == rep.findingsTotal)
        @Assert(Json.intAt(j, "penaltyTotal", -1) == rep.penaltyTotal)
        let cov = Json.getOr(j, "coverage")
        @Assert(Int64(Json.arrAt(cov, "kindsUnavailable").size) == 7)
        // 内嵌 / 快照形态（confidence gen 持久化、render index --confidence 消费的那一份）
        let e = confidenceEmbedJson(rep, false)
        for (k in ["findingsTotal", "penaltyTotal", "coverage", "cappedKind", "cappedTotal"]) {
            @Assert(Json.has(e, k))
        }
        @Assert(Json.has(Json.getOr(e, "coverage"), "astBatchesFailed"))
        // 文本出口说「共 N 条」而不是拿列出的条数冒充总数
        @Assert(confidenceText(rep).contains("共 ${rep.findingsTotal} 条"))
    } finally {
        removePathIfExists(root)
    }
}

/// 补丁置信度的裁决词表：任务书模板（resolved / unresolved / ambiguous）与 skill 配方
/// （confirm / dismiss / unsure）是同一个引擎里的两套词。合并器原先只认前一套。
@Test
func testPatchVerdictVocabularyIsNormalizedAndUnknownIsLoud(): Unit {
    @Assert(normalizeVerdict("confirm") == "unresolved")
    @Assert(normalizeVerdict("dismiss") == "resolved")
    @Assert(normalizeVerdict("unsure") == "ambiguous")
    @Assert(normalizeVerdict("resolved") == "resolved")
    @Assert(normalizeVerdict("unresolved") == "unresolved")
    @Assert(normalizeVerdict("ambiguous") == "ambiguous")
    @Assert(normalizeVerdict(" maybe ") == "unknown")

    let root = writeTree()
    try {
        let graph = buildGraph(root)
        let diff = "--- a/flow/update.cj\n+++ b/flow/update.cj\n@@ -1,3 +1,7 @@\n" +
            " package cambium.flow\n+\n+public func patchHelper(t: Text): Bool {\n" +
            "+    let ok = t.trimAll(\"x\")\n+    return ok && ghost_fn(t)\n+}\n"
        let pc = analyzePatchConfidence(graph, diff)
        var uid = ""
        for (u in pc.uncertain) {
            if (uncId(u.kind) == "unresolved_call" && u.id.contains("ghost_fn")) { uid = u.id }
        }
        @Assert(!uid.isEmpty())
        let alg = patchConfidenceJson(pc)
        // 「confirm」= 确有其事：必须按未解析（高警示）计入，而不是落成默认的 0.5
        let ag = Json.parse("{\"items\": [{\"id\": \"${uid}\", \"verdict\": \"confirm\", \"confidence\": 0.9}]}").getOrThrow()
        match (mergePatchConfidence(alg, ag)) {
            case Some(m) =>
                var seen = false
                for (e in m.entities) {
                    if (Json.strAt(e, "id", "") == uid) {
                        seen = true
                        @Assert(Json.strAt(e, "verdict", "") == "unresolved")
                        @Assert(Json.strAt(e, "source", "") == "agent")
                    }
                }
                @Assert(seen)
                var highAlert = false
                for ((level, _, _) in m.alerts) {
                    if (level == "high") { highAlert = true }
                }
                @Assert(highAlert)
            case None => @Assert(false)
        }
        // 认不出的裁决词：按无法判定计入，并且必须出警示（永不静默）
        let ag2 = Json.parse("{\"items\": [{\"id\": \"${uid}\", \"verdict\": \"maybe\", \"confidence\": 0.9}]}").getOrThrow()
        match (mergePatchConfidence(alg, ag2)) {
            case Some(m) =>
                var loud = false
                for ((_, _, detail) in m.alerts) {
                    if (detail.contains("未知的裁决词") && detail.contains("maybe")) { loud = true }
                }
                @Assert(loud)
                var verdict2 = ""
                for (e in m.entities) {
                    if (Json.strAt(e, "id", "") == uid) { verdict2 = Json.strAt(e, "verdict", "") }
                }
                @Assert(verdict2 == "unknown")
            case None => @Assert(false)
        }
        // S10 与 S1 同口径：照常出现在 signals 里，但不重复计入均值
        var s1: Float64 = -1.0
        var s10: Float64 = -1.0
        var sum: Float64 = 0.0
        var n: Int64 = 0
        for ((id, v) in pc.signals) {
            if (id == "S1") { s1 = v }
            if (id == "S10") {
                s10 = v
            } else {
                sum += v
                n += 1
            }
        }
        @Assert(s1 >= 0.0)
        @Assert(s10 == s1)
        @Assert(n > 0)
        let expected = sum / Float64(n)
        @Assert(pc.overall - expected < 0.000001 && expected - pc.overall < 0.000001)
    } finally {
        removeTree(root)
    }
}
