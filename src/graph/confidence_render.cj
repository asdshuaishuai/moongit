// graph/confidence_render.cj — 置信度报告的三种出口：文本 / JSON / LLM 提示词包。
//
// 【llmPrompt 的定位】引擎 AI 无关（零 LLM 调用），但可以把**确定性事实 +
// 待复核问题**打包成一段可直接喂模型的提示词。语义分析（这函数到底对不对）
// 由上层 agent 执行 —— 引擎负责让那一步有据可依，不负责替它下结论。
package moongit.graph

import std.collection.*
import std.convert.*
import moongit.util.*

// MARK: - JSON

public func confidenceJson(r: ConfidenceReport): JsonValue {
    let fs = ArrayList<JsonValue>()
    for (f in r.findings) {
        let o = Json.obj()
        Json.set(o, "kind", Json.of(flawId(f.kind)))
        Json.set(o, "file", Json.of(f.file))
        Json.set(o, "line", Json.of(f.line))
        Json.set(o, "symbol", Json.of(f.symbol))
        Json.set(o, "evidence", Json.of(f.evidence))
        Json.set(o, "weight", Json.of(flawWeight(f.kind)))
        fs.add(o)
    }
    let ks = ArrayList<JsonValue>()
    for ((k, v) in r.byKind) {
        let o = Json.obj()
        Json.set(o, "kind", Json.of(flawId(k)))
        Json.set(o, "label", Json.of(flawLabel(k, false)))
        Json.set(o, "count", Json.of(v))
        Json.set(o, "weight", Json.of(flawWeight(k)))
        ks.add(o)
    }
    let o = Json.obj()
    Json.set(o, "root", Json.of(r.root))
    Json.set(o, "score", Json.of(r.score))
    Json.set(o, "findings", JArr(fs))
    Json.set(o, "byKind", JArr(ks))
    Json.set(o, "astUsed", Json.of(r.astUsed))
    Json.set(o, "astNote", Json.of(r.astNote))
    Json.set(o, "files", Json.of(r.filesAnalyzed))
    // 语义边界恒发：分数是结构级度量，不是正确性证明
    Json.set(o, "semantics", Json.of(
        "score = 100·S/(S+每文件疑点权重)（S=${Int64(CONF_SCORE_SCALE)}，与仓库规模无关），"
        + "是结构性疑点的汇总（0..100），不是正确性证明；"
        + "信号为词法+语法树级事实，不包含运行时行为与业务语义"))
    return o
}

// MARK: - 文本

public func confidenceText(r: ConfidenceReport): String {
    let sb = StringBuilder()
    sb.append("代码置信度 · ${r.root}\n")
    sb.append("  分数 ${r.score}/100 · ${Int64(r.findings.size)} 条疑点 · 分析 ${r.filesAnalyzed} 文件\n")
    sb.append("  ${r.astNote}\n")
    sb.append("  （分数是结构性疑点汇总，不是正确性证明）\n")
    if (r.findings.size == 0) {
        sb.append("\n未发现结构性疑点。\n")
        return sb.toString()
    }
    sb.append("\n按类别：\n")
    for ((k, v) in r.byKind) {
        sb.append("  ${flawLabel(k, false)} × ${v}（权重 ${flawWeight(k)}/条）\n")
    }
    sb.append("\n明细：\n")
    var lastId = ""
    for (f in r.findings) {
        let kid = flawId(f.kind)
        if (kid != lastId) {
            sb.append("\n【${flawLabel(f.kind, false)}】\n")
            lastId = kid
        }
        sb.append("  ${f.file}:${f.line}  ${f.evidence}\n")
    }
    sb.append("\n复核提示：moongit graph confidence <项目> --llm 生成 LLM 语义复核提示词\n")
    return sb.toString()
}

// MARK: - LLM 提示词包

/// 把确定性事实打包成一段可直接喂给模型的复核提示词。
/// 要求模型**逐条裁决**（确认/驳回/无法判定），并强制引用代码原文作为依据 ——
/// 防止模型顺着 findings 复读而不是独立核查。
public func confidenceLlmPrompt(r: ConfidenceReport, projectName: String): String {
    let sb = StringBuilder()
    sb.append("# 代码置信度复核任务\n\n")
    sb.append("项目：${projectName}\n")
    sb.append("结构化预检：${Int64(r.findings.size)} 条疑点（引擎词法/语法树级），")
    sb.append("启发式评分 ${r.score}/100。\n\n")
    sb.append("## 你的任务\n\n")
    sb.append("对下面每一条预检疑点**独立复核**，逐条给出裁决：\n")
    sb.append("- `confirm`：确认为真问题。必须引用**代码原文**（≤3 行）作为依据。\n")
    sb.append("- `dismiss`：误报。说明为什么（如：是协议实现、被反射调用、公共 API 等）。\n")
    sb.append("- `unsure`：无法从静态信息判定。说明缺什么信息。\n\n")
    sb.append("**红线**：不许只复述预检结论；每条裁决必须基于你自己读到的代码。\n")
    sb.append("最后给出：`realScore`（0-100，你复核后的置信度）、`topRisks`（最值得先修的 3 条）。\n\n")
    sb.append("## 预检疑点\n\n")
    var i: Int64 = 0
    for (f in r.findings) {
        i += 1
        if (i > 80) {
            sb.append("… 其余 ${Int64(r.findings.size) - 80} 条略（按类别聚合见 byKind）\n")
            break
        }
        sb.append("${i}. [${flawId(f.kind)}] ${f.file}:${f.line}\n")
        sb.append("   证据：${f.evidence}\n")
    }
    sb.append("\n## 输出格式\n\n")
    sb.append("```json\n")
    sb.append("{\"verdicts\": [{\"n\": 1, \"verdict\": \"confirm|dismiss|unsure\", ")
    sb.append("\"reason\": \"...\", \"quote\": \"代码原文\"}], ")
    sb.append("\"realScore\": 0-100, \"topRisks\": [\"...\", \"...\", \"...\"]}\n")
    sb.append("```\n")
    return sb.toString()
}
