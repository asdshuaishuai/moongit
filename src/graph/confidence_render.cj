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
    let dims = ArrayList<JsonValue>()
    for ((d, pen, cnt, dScore) in r.dimensions) {
        let dd = Json.obj()
        Json.set(dd, "id", Json.of(dimensionId(d)))
        Json.set(dd, "label", Json.of(dimensionLabel(d, false)))
        Json.set(dd, "penalty", Json.of(pen))
        Json.set(dd, "findings", Json.of(cnt))
        Json.set(dd, "score", Json.of(dScore))
        dims.add(dd)
    }
    let fl = ArrayList<JsonValue>()
    for (f in r.files) {
        let fo = Json.obj()
        Json.set(fo, "file", Json.of(f[0]))
        Json.set(fo, "penalty", Json.of(f[1]))
        fl.add(fo)
    }
    let o = Json.obj()
    Json.set(o, "root", Json.of(r.root))
    Json.set(o, "score", Json.of(r.score))
    Json.set(o, "dimensions", JArr(dims))
    // ⚠️ M4：这两个键原来**都叫 "files"** —— 罚分表（数组）先写，
    // filesAnalyzed（计数）后写，而 Json.set 同键就地覆盖 ⇒ JSON 出口里
    // 罚分表被静默丢掉。MCP codegraph_confidence 与 CLI --json 都只受这一份影响。
    // 罚分表可由 findings 重新聚合复原，所以原来是「中等严重度的契约缺陷」而非
    // 数据丢失，但两个含义共用一个键本身就是错：消费方无从同时拿到两者。
    Json.set(o, "penaltyByFile", JArr(fl))
    Json.set(o, "findings", JArr(fs))
    Json.set(o, "byKind", JArr(ks))
    Json.set(o, "astUsed", Json.of(r.astUsed))
    Json.set(o, "astNote", Json.of(r.astNote))
    Json.set(o, "filesAnalyzed", Json.of(r.filesAnalyzed))
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
    sb.append("\n按维度：\n")
    for ((d, pen, cnt, dScore) in r.dimensions) {
        sb.append("  ${dimensionLabel(d, false)}：${dScore}/100（罚分 ${pen} · ${cnt} 条）\n")
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
/// **按维度分节**（评审要求）：变量/函数/类型/指针/并发/结构各一节，
/// LLM 逐维度逐条裁决（confirm/dismiss/unsure），维度分让它知道预检
/// 认为哪里最弱。红线不变：必须引用代码原文，禁止复读预检结论。
public func confidenceLlmPrompt(r: ConfidenceReport, projectName: String): String {
    let sb = StringBuilder()
    sb.append("# 代码置信度复核任务\n\n")
    sb.append("项目：${projectName}\n")
    sb.append("引擎预检：总分 ${r.score}/100 · ${Int64(r.findings.size)} 条疑点（词法+语法树级）。\n\n")
    sb.append("## 预检维度分\n\n")
    for ((d, pen, cnt, dScore) in r.dimensions) {
        sb.append("- ${dimensionLabel(d, true)}：${dScore}/100（${cnt} findings）\n")
    }
    sb.append("\n## 你的任务\n\n")
    sb.append("按**维度分节**独立复核下面每一条预检疑点，逐条给出裁决：\n")
    sb.append("- `confirm`：确认为真问题。必须引用**代码原文**（≤3 行）作为依据。\n")
    sb.append("- `dismiss`：误报。说明为什么（协议实现/反射调用/公共 API/语言惯用法等）。\n")
    sb.append("- `unsure`：无法从静态信息判定。说明缺什么信息（运行时/业务语义）。\n\n")
    sb.append("**红线**：不许只复述预检结论；每条裁决必须基于你自己读到的代码。\n")
    sb.append("对并发维度额外要求：指出是否存在静态分析看不到的竞争窗口（如回调重入/异步序）。\n\n")
    sb.append("## 预检疑点（按维度）\n\n")
    // 按维度分节输出（≤80 条总量）
    var shown: Int64 = 0
    let LIMIT: Int64 = 80
    for ((d, _, _, _) in r.dimensions) {
        let did = dimensionId(d)
        var dimCount: Int64 = 0
        for (f in r.findings) {
            if (dimensionId(flawDimension(f.kind)) == did) { dimCount += 1 }
        }
        if (dimCount == 0) { continue }
        sb.append("### ${dimensionLabel(d, false)}（${dimCount} 条）\n\n")
        var i: Int64 = 0
        for (f in r.findings) {
            if (dimensionId(flawDimension(f.kind)) != did) { continue }
            i += 1
            shown += 1
            if (shown > LIMIT) { break }
            sb.append("${i}. [${flawId(f.kind)}] ${f.file}:${f.line}\n")
            sb.append("   证据：${f.evidence}\n")
        }
        sb.append("\n")
        if (shown > LIMIT) {
            sb.append("… 其余维度条目略（总量截断）\n")
            break
        }
    }
    sb.append("## 输出格式\n\n")
    sb.append("```json\n")
    sb.append("{\"dimensions\": {\"variable\": {\"verdicts\": [...], \"score\": 0-100}, ")
    sb.append("\"function\": {...}, \"type\": {...}, \"pointer\": {...}, ")
    sb.append("\"concurrency\": {...}, \"structure\": {...}}, ")
    sb.append("\"realScore\": 0-100, \"topRisks\": [\"...\", \"...\", \"...\"]}\n")
    sb.append("```\n")
    sb.append("verdicts 元素：{\"n\": 序号, \"verdict\": \"confirm|dismiss|unsure\", ")
    sb.append("\"reason\": \"...\", \"quote\": \"代码原文\"}\n")
    return sb.toString()
}
