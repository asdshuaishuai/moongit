// db.cj（Dendro）—— 置信度报告库：单文件 SQLite（confidence.db）。
//
// 从图谱包的 db.cj 剥离：它吃的是 ConfidenceReport（Dendro 的类型），归属置信度这一层。
// 图库（codegraph.db / index.db）仍在图谱包。库的 generator 值保持历史字面量不变——
// 它写进已有库的 meta 表，引擎按它判库新旧（「改名字，不改身份」）。

package cambium.dendro

import std.collection.*
import cambium.util.*
import cambium.graph.*

/// confidence db 的 meta.generator（同上）。
/// v2（阶段二 A）：findings 表增 sid / qual 两列——疑点挂靠符号的稳定 id 与限定名，
/// 与 codegraph.db 的 nodes.sid 同一个键（`SELECT … FROM findings f JOIN nodes` 跨库
/// 对账时按 sid = nodes.sid）。两列追加在表尾，既有列的位置不变。
public let CONFIDENCE_DB_GENERATOR: String = "moongit confidence db v2"

// B. 置信度报告库（cambium dendro db）
//
//   meta(key, value)   score / files_analyzed / ast_used / ast_note /
//                      capped_kind / capped_total / findings_total / penalty_total / root
//   findings(id, kind, file, line, symbol, weight, dim, evidence, sid, qual)
//                       sid / qual = 挂靠符号键（阶段二 A；定位不到为空串，列照样在）
//   dimensions(dim, label, penalty, findings, score)
//   files(file, penalty)                   罚分表原样
// ─────────────────────────────────────────────────────────────────

/// 把 ConfidenceReport 全量写进单文件 SQLite。成功 true；失败
/// Log.warn + false。
public func confidenceDbWrite(path: String, report: ConfidenceReport): Bool {
    removePathIfExists(path)
    removePathIfExists(path + "-wal")
    removePathIfExists(path + "-shm")
    let dbOpt = SqliteDb.open(path)
    if (dbOpt.isNone()) { return false }
    let db = dbOpt.getOrThrow()
    var ok = true
    try {
        let ddl: Array<String> = [
            "CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT)",
            "CREATE TABLE findings(id INTEGER PRIMARY KEY, kind TEXT, file TEXT, line INTEGER, symbol TEXT, weight INTEGER, dim TEXT, evidence TEXT, sid TEXT, qual TEXT)",
            "CREATE TABLE dimensions(dim TEXT PRIMARY KEY, label TEXT, penalty INTEGER, findings INTEGER, score INTEGER)",
            "CREATE TABLE files(file TEXT PRIMARY KEY, penalty INTEGER)",
        ]
        for (s in ddl) {
            if (!db.exec(s)) { ok = false; break }
        }
        if (ok) {
            ok = confidenceDbFill(db, report)
        }
    } finally {
        db.close()
    }
    return ok
}

func confidenceDbFill(db: SqliteDb, report: ConfidenceReport): Bool {
    // ── meta（bool 写 "1"/"0"：TEXT 列、对 SQL 用户可读也可比较）──
    let stMetaOpt = db.prepare("INSERT INTO meta(key, value) VALUES(?, ?)")
    if (stMetaOpt.isNone()) { return false }
    let stMeta = stMetaOpt.getOrThrow()
    func putMeta(k: String, v: String): Bool {
        if (!stMeta.bindText(1, k)) { return false }
        if (!stMeta.bindText(2, v)) { return false }
        if (!stMeta.stepFinish()) { return false }
        stMeta.reset()
        return true
    }
    func boolText(b: Bool): String {
        if (b) { return "1" }
        return "0"
    }
    var ok = true
    ok = ok && putMeta("generator", CONFIDENCE_DB_GENERATOR)
    ok = ok && putMeta("score", report.score.toString())
    ok = ok && putMeta("files_analyzed", report.filesAnalyzed.toString())
    ok = ok && putMeta("ast_used", boolText(report.astUsed))
    ok = ok && putMeta("ast_note", report.astNote)
    ok = ok && putMeta("capped_kind", boolText(report.cappedKind))
    ok = ok && putMeta("capped_total", boolText(report.cappedTotal))
    ok = ok && putMeta("findings_total", report.findingsTotal.toString())
    ok = ok && putMeta("penalty_total", report.penaltyTotal.toString())
    ok = ok && putMeta("root", report.root)
    stMeta.finalize()
    if (!ok) { return false }

    // ── findings（显式 id 1..N：两次写入逐字节可 diff，不靠 rowid 隐式自增）──
    let stFOpt = db.prepare("INSERT INTO findings(id, kind, file, line, symbol, weight, dim, evidence, sid, qual) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
    if (stFOpt.isNone()) { return false }
    let stF = stFOpt.getOrThrow()
    var fid: Int64 = 0
    for (f in report.findings) {
        fid += 1
        var row = stF.bindInt(1, fid)
        row = row && stF.bindText(2, flawId(f.kind))
        row = row && stF.bindText(3, f.file)
        row = row && stF.bindInt(4, f.line)
        row = row && stF.bindText(5, f.symbol)
        row = row && stF.bindInt(6, flawWeight(f.kind))
        row = row && stF.bindText(7, dimensionId(flawDimension(f.kind)))
        row = row && stF.bindText(8, f.evidence)
        // 挂靠符号键（与 findingJson 的 id / qual 同源：都读 Finding 的 symId / qual）
        row = row && stF.bindText(9, f.symId)
        row = row && stF.bindText(10, f.qual)
        row = row && stF.stepFinish()
        if (!row) { stF.finalize(); return false }
        stF.reset()
    }
    stF.finalize()

    // ── dimensions ──
    // label 固定中文（dimensionLabel(d, false)）：写入必须确定（同一报告
    // 两次写入逐字节一致），语言是显示层的事——消费方可拿 dim id 自行映射。
    let stDOpt = db.prepare("INSERT INTO dimensions(dim, label, penalty, findings, score) VALUES(?, ?, ?, ?, ?)")
    if (stDOpt.isNone()) { return false }
    let stD = stDOpt.getOrThrow()
    for (d in report.dimensions) {
        var row = stD.bindText(1, dimensionId(d[0]))
        row = row && stD.bindText(2, dimensionLabel(d[0], false))
        row = row && stD.bindInt(3, d[1])
        row = row && stD.bindInt(4, d[2])
        row = row && stD.bindInt(5, d[3])
        row = row && stD.stepFinish()
        if (!row) { stD.finalize(); return false }
        stD.reset()
    }
    stD.finalize()

    // ── files（罚分表原样：引擎已按罚分降序，写入不再重排）──
    let stPFOpt = db.prepare("INSERT INTO files(file, penalty) VALUES(?, ?)")
    if (stPFOpt.isNone()) { return false }
    let stPF = stPFOpt.getOrThrow()
    for (pf in report.files) {
        var row = stPF.bindText(1, pf[0])
        row = row && stPF.bindInt(2, pf[1])
        row = row && stPF.stepFinish()
        if (!row) { stPF.finalize(); return false }
        stPF.reset()
    }
    stPF.finalize()
    return true
}

// ─────────────────────────────────────────────────────────────────
