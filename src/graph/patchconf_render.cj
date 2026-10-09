// graph/patchconf_render.cj — 三层架构的出口：algorithm.json / skill / merge / final.json。
//
// 【合并规则（评审设计，简单可审计）】
//   算法层 entities  → 原样保留（source: algorithm）
//   Agent resolved   → 用 Agent 值，confidence × 0.9（source: agent）
//   Agent unresolved → alerts 计负分（source: agent, verdict: unresolved）
//   Agent ambiguous  → confidence 0.5
//   Agent 没处理     → deferred，0.5，报告中列出
//   overall 重算 = 全部 entities 的加权均值（算法项权重 1.0）
package moongit.graph

import std.collection.*
import std.convert.*
import moongit.util.*

// MARK: - Layer 1 出口：algorithm.json

public func patchConfidenceJson(pc: PatchConfidence): JsonValue {
    let sig = Json.obj()
    for ((sid, v) in pc.signals) {
        Json.set(sig, sid, Json.of(v))
    }
    for (sid in pc.nullSignals) {
        Json.set(sig, sid, Json.null())
    }
    let ents = ArrayList<JsonValue>()
    for (e in pc.entities) {
        let o = Json.obj()
        Json.set(o, "id", Json.of(e.id))
        Json.set(o, "kind", Json.of(e.kind))
        Json.set(o, "confidence", Json.of(e.confidence))
        let rs = ArrayList<JsonValue>()
        for ((t, target, c) in e.relations) {
            let r = Json.obj()
            Json.set(r, "type", Json.of(t))
            Json.set(r, "target", Json.of(target))
            Json.set(r, "confidence", Json.of(c))
            rs.add(r)
        }
        Json.set(o, "relations", JArr(rs))
        ents.add(o)
    }
    let uncs = ArrayList<JsonValue>()
    for (u in pc.uncertain) {
        let o = Json.obj()
        Json.set(o, "id", Json.of(u.id))
        Json.set(o, "issue", Json.of(uncId(u.kind)))
        Json.set(o, "detail", Json.of(u.detail))
        Json.set(o, "candidates", Json.strArray(u.candidates.toArray()))
        let ctx = Json.obj()
        Json.set(ctx, "file", Json.of(u.file))
        Json.set(ctx, "line", Json.of(u.line))
        Json.set(o, "context_ref", ctx)
        uncs.add(o)
    }
    let diag = Json.obj()
    Json.set(diag, "total_entities", Json.of(pc.totalEntities))
    Json.set(diag, "total_relations", Json.of(pc.totalRelations))
    Json.set(diag, "parse_errors", Json.of(pc.parseErrors))
    Json.set(diag, "patch_files", Json.of(pc.patchFiles))
    Json.set(diag, "added_lines", Json.of(pc.addedLines))
    Json.set(diag, "null_signals", Json.strArray(pc.nullSignals.toArray()))
    Json.set(diag, "null_signals_note", Json.of(
        "null 信号 = 词法层无法可靠计算（如 S7 契约一致率需接口实现对照）；不进 overall 均值"))
    let o = Json.obj()
    Json.set(o, "schema", Json.of("moongit-patch-confidence/1"))
    Json.set(o, "overall", Json.of(pc.overall))
    Json.set(o, "signals", sig)
    Json.set(o, "entities", JArr(ents))
    Json.set(o, "uncertain", JArr(uncs))
    Json.set(o, "diagnostics", diag)
    return o
}

// MARK: - Layer 2：skill 文本

/// Agent Skill 定义（评审原文的结构落地）。工具映射到本引擎已有的 CLI/MCP 面。
public func patchConfidenceSkill(projectName: String): String {
    let sb = StringBuilder()
    sb.append("# Skill: Code Confidence Review (Layer 2)\n\n")
    sb.append("## 目标\n")
    sb.append("读取 algorithm.json（`moongit graph patchconf ${projectName} --patch <diff>` 的输出）")
    sb.append("中的 `uncertain` 列表，逐项判断其真实置信度，输出 agent.json。\n\n")
    sb.append("## 可用工具（本引擎映射）\n")
    sb.append("- `read_file(path, start, end)` → 宿主的文件读取工具\n")
    sb.append("- `grep(pattern, path)` → 宿主的搜索工具\n")
    sb.append("- `list_symbols(module)` → `moongit graph tree ${projectName} --json`（全量图）或 `graph symbol ${projectName} <名>`\n")
    sb.append("- `get_signature(symbol)` → `moongit graph symbol ${projectName} <名>`（输出含 file:line，再 read_file 取签名）\n")
    sb.append("- `run_algorithm(rel_id)` → `moongit graph patchconf ${projectName} --patch <diff>` 重跑\n\n")
    sb.append("## 处理流程\n")
    sb.append("对 `uncertain` 中每一项：\n")
    sb.append("1. 读 `context_ref`（file + line）附近的代码\n")
    sb.append("2. 用 grep / list_symbols / get_signature 收集必要上下文\n")
    sb.append("3. 给出判断（见输出格式）\n\n")
    sb.append("## 输出格式（严格 JSON，写为 agent.json）\n")
    sb.append("```json\n")
    sb.append("{\"task\": \"layer2_review\", \"items\": [\n")
    sb.append("  {\"id\": \"<uncertain.id 原样回填>\",\n")
    sb.append("   \"verdict\": \"resolved|unresolved|ambiguous\",\n")
    sb.append("   \"value\": \"解析出的目标（resolved 时）\",\n")
    sb.append("   \"confidence\": 0.0,\n")
    sb.append("   \"reason\": \"一句话说明\",\n")
    sb.append("   \"evidence_refs\": [\"file.py:42\"]}\n")
    sb.append("]}\n")
    sb.append("```\n\n")
    sb.append("## 原则\n")
    sb.append("- 不确定就标 ambiguous，不要硬猜\n")
    sb.append("- 必须有 evidence_refs；没有证据的结论 confidence ≤ 0.5\n")
    sb.append("- 不要重做 entities 里已有的项\n")
    sb.append("- 不要修改任何文件\n")
    sb.append("- 完成后用合并器出终稿：`moongit graph patchconf --merge algorithm.json agent.json`\n")
    return sb.toString()
}

// MARK: - Layer 3：合并器

/// 合并结果
public class MergedConfidence {
    public let overall: Float64
    public let entities: ArrayList<JsonValue>   // 合并后的实体列表（含来源标记）
    public let alerts: ArrayList<(String, String, String)>   // (level, type, detail)
    public let certainCount: Int64
    public let reviewedCount: Int64
    public let deferredCount: Int64

    public init(overall: Float64, entities: ArrayList<JsonValue>,
                alerts: ArrayList<(String, String, String)>,
                certainCount: Int64, reviewedCount: Int64, deferredCount: Int64) {
        this.overall = overall
        this.entities = entities
        this.alerts = alerts
        this.certainCount = certainCount
        this.reviewedCount = reviewedCount
        this.deferredCount = deferredCount
    }
}

/// 合并 algorithm.json + agent.json → final（规则见文件头注释）。
/// 任一输入解析失败返回 None（调用方报错，不静默降级）。
public func mergePatchConfidence(algorithm: JsonValue, agent: JsonValue): Option<MergedConfidence> {
    // agent items → id 索引
    let agentMap = HashMap<String, JsonValue>()
    let items = Json.arrAt(agent, "items")
    for (it in items) {
        let id = Json.strAt(it, "id", "")
        if (!id.isEmpty()) { agentMap[id] = it }
    }
    let entities = ArrayList<JsonValue>()
    let alerts = ArrayList<(String, String, String)>()
    var sum: Float64 = 0.0
    var n: Int64 = 0
    var reviewed: Int64 = 0
    var deferred: Int64 = 0
    // ① 算法层 entities：原样保留
    for (e in Json.arrAt(algorithm, "entities")) {
        let o = Json.obj()
        Json.set(o, "id", Json.getOr(e, "id"))
        Json.set(o, "confidence", Json.getOr(e, "confidence"))
        Json.set(o, "source", Json.of("algorithm"))
        Json.set(o, "relations", Json.getOr(e, "relations"))
        entities.add(o)
        sum += Json.numAt(e, "confidence", 0.0)
        n += 1
    }
    // ② uncertain：按 Agent 裁决合并
    for (u in Json.arrAt(algorithm, "uncertain")) {
        let uid = Json.strAt(u, "id", "")
        let issue = Json.strAt(u, "issue", "")
        let detail = Json.strAt(u, "detail", "")
        let o = Json.obj()
        Json.set(o, "id", Json.of(uid))
        Json.set(o, "issue", Json.of(issue))
        match (agentMap.get(uid)) {
            case Some(a) =>
                reviewed += 1
                let verdict = Json.strAt(a, "verdict", "ambiguous")
                var conf = Json.numAt(a, "confidence", 0.5)
                if (verdict == "resolved") {
                    conf = conf * 0.9   // Agent 值打折（评审规则）
                } else if (verdict == "ambiguous") {
                    conf = 0.5
                } else if (verdict == "unresolved") {
                    conf = Json.numAt(a, "confidence", 0.2)
                    alerts.add(("high", issue, "${detail} — agent 判定未解析"))
                }
                Json.set(o, "confidence", Json.of(conf))
                Json.set(o, "source", Json.of("agent"))
                Json.set(o, "verdict", Json.of(verdict))
                Json.set(o, "reason", Json.getOr(a, "reason"))
                Json.set(o, "evidence_refs", Json.getOr(a, "evidence_refs"))
                if (verdict == "ambiguous") {
                    alerts.add(("medium", issue, "${detail} — agent 无法判定"))
                }
                sum += conf
                n += 1
            case None =>
                deferred += 1
                Json.set(o, "confidence", Json.of(0.5))
                Json.set(o, "source", Json.of("deferred"))
                alerts.add(("low", issue, "${detail} — agent 未处理（deferred）"))
                sum += 0.5
                n += 1
        }
        entities.add(o)
    }
    let overall = if (n > 0) { sum / Float64(n) } else { 0.0 }
    return Some(MergedConfidence(overall, entities, alerts,
        Int64(Json.arrAt(algorithm, "entities").size), reviewed, deferred))
}

/// final.json 渲染
public func mergedConfidenceJson(m: MergedConfidence, algorithm: JsonValue): JsonValue {
    let ents = ArrayList<JsonValue>()
    for (e in m.entities) { ents.add(e) }
    let als = ArrayList<JsonValue>()
    for ((level, t, detail) in m.alerts) {
        let a = Json.obj()
        Json.set(a, "level", Json.of(level))
        Json.set(a, "type", Json.of(t))
        Json.set(a, "detail", Json.of(detail))
        als.add(a)
    }
    let diag = Json.obj()
    Json.set(diag, "certain_from_algorithm", Json.of(m.certainCount))
    Json.set(diag, "reviewed_by_agent", Json.of(m.reviewedCount))
    Json.set(diag, "deferred", Json.of(m.deferredCount))
    let src = Json.obj()
    Json.set(src, "algorithm", Json.of(true))
    Json.set(src, "agent", Json.of(m.reviewedCount > 0))
    let o = Json.obj()
    Json.set(o, "schema", Json.of("moongit-patch-confidence-merged/1"))
    Json.set(o, "overall", Json.of(m.overall))
    Json.set(o, "signals", Json.getOr(algorithm, "signals"))
    Json.set(o, "entities", JArr(ents))
    Json.set(o, "alerts", JArr(als))
    Json.set(o, "sources", src)
    Json.set(o, "diagnostics", diag)
    return o
}

/// final 的文本摘要
public func mergedConfidenceText(m: MergedConfidence): String {
    let sb = StringBuilder()
    sb.append("补丁置信度（终稿：算法 + Agent 复核）\n")
    sb.append("  overall ${m.overall}\n")
    sb.append("  算法确定 ${m.certainCount} · Agent 复核 ${m.reviewedCount} · 未处理 ${m.deferredCount}\n")
    if (Int64(m.alerts.size) > 0) {
        sb.append("\n告警：\n")
        for ((level, t, detail) in m.alerts) {
            sb.append("  [${level}] ${t}：${detail}\n")
        }
    }
    return sb.toString()
}
