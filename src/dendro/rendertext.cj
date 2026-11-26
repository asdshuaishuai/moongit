// rendertext.cj（Dendro）—— 函数图谱的文本出口：吃图 + 置信度报告，出人读的文本。
// 吃 ConfidenceReport，所以归置信度这一层（从图谱包的 render.cj 剥离）。

package cambium.dendro

import std.collection.*
import cambium.util.*
import cambium.graph.*

/// 函数级图谱的文本摘要：总量 + 按权重降序的异常函数 Top。
/// 数据走 functionGraphData 同一构造器——文本与 JSON 永远同一份事实。
public func functionGraphText(graph: CodeGraph, findings: ConfidenceReport, en: Bool): String {
    let payload = functionGraphData(graph, findings, en)
    let fns = Json.arrAt(payload, "functions")
    let edges = Json.arrAt(payload, "functionEdges")
    var risk = ArrayList<JsonValue>()
    for (f in fns) {
        let fs = Json.arrAt(f, "findings")
        if (fs.size > 0) { risk.add(f) }
    }
    let sb = StringBuilder()
    if (en) {
        sb.append("function graph · ${Int64(fns.size)} functions · ${Int64(edges.size)} call edges · ${Int64(risk.size)} with findings\n")
    } else {
        sb.append("函数图谱 · ${Int64(fns.size)} 函数 · ${Int64(edges.size)} 调用边 · ${Int64(risk.size)} 个带疑点\n")
    }
    // Top-N 用选最大扫描而不是比较器排序：仓库里没有比较器排序先例，
    // std.sort 签名不确定；n≈几百、N=15，O(N·n) 完全够。
    let want = if (risk.size > 15) { 15 } else { risk.size }
    var picked: Int64 = 0
    while (picked < want && risk.size > 0) {
        var best: Int64 = 0
        var i: Int64 = 1
        while (i < Int64(risk.size)) {
            if (Json.intAt(risk[i], "weight", 0) > Json.intAt(risk[best], "weight", 0)) { best = i }
            i += 1
        }
        let f = risk[best]
        risk.remove(at: best)
        let fs = Json.arrAt(f, "findings")
        sb.append("  ${Json.strAt(f, "name", "?")}  ${Json.strAt(f, "file", "")}:${Json.intAt(f, "line", 0)}"
            + "  ⚠${Int64(fs.size)} w${Json.intAt(f, "weight", 0)}\n")
        picked += 1
    }
    if (risk.size > 0) {
        if (en) { sb.append("  … ${Int64(risk.size)} more (use --json for full payload)\n") }
        else { sb.append("  … 还有 ${Int64(risk.size)} 个（--json 拿全量）\n") }
    }
    return sb.toString()
}
