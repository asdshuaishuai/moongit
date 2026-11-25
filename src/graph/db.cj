// graph/db.cj — 两个单文件 SQLite 写入器：符号级索引图库（graph db）
// 与置信度报告库（confidence db）。
//
// 【为什么是 SQLite】用户 directed 决策（2026-10-11）：agent 要
//「一条 SQL 查 callers / callees / 影响面」，不必打开 HTML。经系统
// libsqlite3 的 C 互操作实现（薄层 util/sqlite.cj；cjpm.toml 的
// link-option 追加 -lsqlite3），不引入任何第三方源码。
//
// 【单一口径】graph db 的 nodes/edges 全部来自 functionGraphData 的
// 返回值——它已是符号级节点与调用边的唯一构造点（含 tier 确信度分层），
// 本文件**只搬运，不重算**：没有第二份词法扫描、没有第二份 tier 判定。
// 置信度库同理：全部字段来自 ConfidenceReport 本体（flawId/flawWeight/
// dimensionId 等既有公开映射），分数不在写入时重算。
//
// 【幂等：单文件产物语义】目标文件已存在则**先删重建**——读库的人拿到的
// 永远是「最近一次写入」的完整快照，不存在旧数据混着新数据。-wal/-shm
// 残页一并清掉（journal_mode 保持默认 delete，残页不该有，防外部工具遗留）。
//
// 【meta 表的数字口径与表行数自洽】files = files 表行数（graph.files）、
// symbols = nodes 表行数（payload.functions）。meta 是给 agent 的速览，
// 数字必须能对上表，否则查询行数对不上 meta 会怀疑库坏了。
package moongit.graph

import std.collection.*
import std.convert.*
import moongit.util.*

/// graph db 的 meta.generator。schema 演进时递增版本（v1 → v2），
/// 读方据此判断能否信任键集。
///
/// v2（成员级索引）：nodes 增 sid / qual / end_line / col / sig / visibility /
/// decl_only 七列，新增 sites 表（每个调用点一行，含未解析的）。v1 库对 v2 读方
/// 是**过期**的——`indexDbIsCurrent` 是唯一判据，新鲜度判定（indexProbeFresh）
/// 据此把 v1 库当过期重建，而不是拿缺列的库去跑 v2 查询。
public let GRAPH_DB_GENERATOR: String = "moongit graph db v2"

/// confidence db 的 meta.generator（同上）。
/// v2（阶段二 A）：findings 表增 sid / qual 两列——疑点挂靠符号的稳定 id 与限定名，
/// 与 codegraph.db 的 nodes.sid 同一个键（`SELECT … FROM findings f JOIN nodes` 跨库
/// 对账时按 sid = nodes.sid）。两列追加在表尾，既有列的位置不变。
public let CONFIDENCE_DB_GENERATOR: String = "moongit confidence db v2"

// ─────────────────────────────────────────────────────────────────
// A0. store_meta —— index 的持久化元数据（codegraph.db 内）
//
//   store_meta(key, value)   source_probe / update_count / generated_at / depth
//
// 与 graph db 自己的 meta（generator/project/root/files/symbols）分开：
// meta 回答「这个库是谁写的、装了什么」，store_meta 回答「这份索引是
// 源码的第几版、和现在的源一不一致」。消费方不同（agent 速览 vs
// index update/render 的新鲜度判定），混一张表两边都会越权改对方的键。
// value 列不声明类型（SQLite 动态类型）：update_count 以 INTEGER 写入、
// 其余为 TEXT——读侧统一走 columnText（sqlite 自动转换），写作侧保留语义。
// ─────────────────────────────────────────────────────────────────

/// index 的持久化元数据（store_meta 的读出形态）。
/// updateCount < 0 = 库里没有记录（旧版 `graph db` 写的库 / 首版之前）。
public struct IndexMeta {
    public let probeText: String      // source_probe 原文（JSON）；无记录 = ""
    public let updateCount: Int64     // 无记录 = -1
    public let generatedAt: String    // 无记录 = ""
    public let depth: Int64           // 生成时的 --depth（重建时复用同一口径）；无记录 = -1

    public init(probeText: String, updateCount: Int64, generatedAt: String, depth: Int64) {
        this.probeText = probeText
        this.updateCount = updateCount
        this.generatedAt = generatedAt
        this.depth = depth
    }

    /// 探针是否可解析。False = 库里没有可用的探针记录——
    /// 「读不出来」不是「源没变」，调用方必须判过期重建。
    public func probe(): Option<SourceProbe> {
        if (probeText.isEmpty()) { return None }
        return sourceProbeFromText(probeText)
    }
}

/// store_meta 数值键的安全解析（Int64.parse 遇非数字抛异常，这里收口成
/// Option——元数据里的脏值按「无记录」处理，不许让读路径炸掉）。
func metaInt(s: String): Option<Int64> {
    let t = s.trimAscii()
    if (t.isEmpty()) { return None }
    try {
        return Some(Int64.parse(t))
    } catch (e: Exception) {
        return None
    }
}

/// 读 codegraph.db 的 store_meta。库不存在 / 打不开 / 表不存在（旧版库）
/// → None——调用方按「无记录」处理，不猜内容。
public func indexMetaRead(dbPath: String): Option<IndexMeta> {
    if (!fileExists(dbPath)) { return None }
    let dbOpt = SqliteDb.openReadonly(dbPath)
    if (dbOpt.isNone()) { return None }
    let db = dbOpt.getOrThrow()
    var probeText = ""
    var updateCount: Int64 = -1
    var generatedAt = ""
    var depth: Int64 = -1
    try {
        let stOpt = db.prepare("SELECT value FROM store_meta WHERE key = ?")
        if (stOpt.isNone()) { return None }
        let st = stOpt.getOrThrow()
        func readOne(k: String): String {
            var v = ""
            if (st.bindText(1, k) && st.stepHasRow()) {
                v = st.columnText(0)
            }
            st.reset()
            return v
        }
        probeText = readOne("source_probe")
        match (metaInt(readOne("update_count"))) {
            case Some(n) => updateCount = n
            case None => updateCount = -1
        }
        generatedAt = readOne("generated_at")
        match (metaInt(readOne("depth"))) {
            case Some(n) => depth = n
            case None => depth = -1
        }
        st.finalize()
    } finally {
        db.close()
    }
    return Some(IndexMeta(probeText, updateCount, generatedAt, depth))
}

// ─────────────────────────────────────────────────────────────────
// A. 符号级索引图库（moongit graph db）
//
//   meta(key, value)          generator / project / root / files / symbols
//   nodes(id, kind, name, file, line, lang, findings, max_weight,
//         sid, qual, end_line, col, sig, visibility, decl_only)      ← v2 新增后七列
//   edges(src, dst, tier, weight)          src/dst = nodes.id（调用方 → 被调方）
//   sites(src, dst, file, line, col, receiver, tier, name)           ← v2 新增
//         每个调用点 × 解析目标一行；未解析的 dst = 0，不在任何函数体内的 src = 0。
//         receiver 是接收者文本（"" = 自由调用）。name / tier 两列是比规格多出来的：
//         没有名字，「未解析调用」这一行就说不清调的是谁。
//   files(path, lang, lines, symbols)      graph.files 原样
//   索引：idx_nodes_name / idx_nodes_file / idx_nodes_sid(unique) / idx_nodes_qual /
//         idx_edges_src / idx_edges_dst / idx_sites_src / idx_sites_dst
//         —— agent 高频查询是「谁调我 / 我调谁 / 按名找符号 / 调用点在哪」
// ─────────────────────────────────────────────────────────────────

/// 把 functionGraphData 的返回值（functions/functionEdges/codeSnippets）
/// 与 graph.files 写进单文件 SQLite。成功 true；任何一步失败
/// Log.warn + false（数据库文件可能残缺——调用方应向用户报错，
/// 不要把它当成功传播）。
public func graphDbWrite(path: String, graph: CodeGraph, funcPayload: JsonValue): Bool {
    return graphDbWriteCore(path, graph, funcPayload, ArrayList<(String, JsonValue)>())
}

/// index gen 的写入面：graph db 同一套表 + store_meta 全套
///（source_probe / update_count / generated_at / depth）。
/// storeMeta 的键值对逐条写入；同名键 SQLite PRIMARY KEY 会拒绝重复——
/// 调用方保证不重复（构造点只有 index 重建一处）。
public func graphDbWriteWithMeta(path: String, graph: CodeGraph, funcPayload: JsonValue,
                                 storeMeta: ArrayList<(String, JsonValue)>): Bool {
    return graphDbWriteCore(path, graph, funcPayload, storeMeta)
}

func graphDbWriteCore(path: String, graph: CodeGraph, funcPayload: JsonValue,
                      storeMeta: ArrayList<(String, JsonValue)>): Bool {
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
            "CREATE TABLE store_meta(key TEXT PRIMARY KEY, value)",
            "CREATE TABLE nodes(id INTEGER PRIMARY KEY, kind TEXT, name TEXT, file TEXT, line INTEGER, lang TEXT, findings INTEGER, max_weight INTEGER, sid TEXT, qual TEXT, end_line INTEGER, col INTEGER, sig TEXT, visibility TEXT, decl_only INTEGER)",
            "CREATE TABLE edges(src INTEGER, dst INTEGER, tier TEXT, weight INTEGER)",
            "CREATE TABLE sites(src INTEGER, dst INTEGER, file TEXT, line INTEGER, col INTEGER, receiver TEXT, tier TEXT, name TEXT)",
            "CREATE TABLE files(path TEXT PRIMARY KEY, lang TEXT, lines INTEGER, symbols INTEGER)",
            "CREATE INDEX idx_nodes_name ON nodes(name)",
            "CREATE INDEX idx_nodes_file ON nodes(file)",
            "CREATE UNIQUE INDEX idx_nodes_sid ON nodes(sid)",
            "CREATE INDEX idx_nodes_qual ON nodes(qual)",
            "CREATE INDEX idx_edges_src ON edges(src)",
            "CREATE INDEX idx_edges_dst ON edges(dst)",
            "CREATE INDEX idx_sites_src ON sites(src)",
            "CREATE INDEX idx_sites_dst ON sites(dst)",
        ]
        for (s in ddl) {
            if (!db.exec(s)) { ok = false; break }
        }
        if (ok) {
            ok = graphDbFill(db, graph, funcPayload)
        }
        if (ok) {
            ok = storeMetaFill(db, storeMeta)
        }
    } finally {
        db.close()
    }
    return ok
}

/// store_meta 行填充。数值按 INTEGER 写（update_count 的语义类型），
/// 其余按 TEXT——读侧统一 columnText，sqlite 自动双向转换。
func storeMetaFill(db: SqliteDb, rows: ArrayList<(String, JsonValue)>): Bool {
    let stOpt = db.prepare("INSERT INTO store_meta(key, value) VALUES(?, ?)")
    if (stOpt.isNone()) { return false }
    let st = stOpt.getOrThrow()
    var ok = true
    for ((k, v) in rows) {
        var row = st.bindText(1, k)
        if (row) {
            match (v) {
                case JNum(n) =>
                    match (Json.asInt(JNum(n))) {
                        case Some(i) => row = st.bindInt(2, i)
                        case None => row = st.bindText(2, n.toString())
                    }
                case JStr(s) => row = st.bindText(2, s)
                case JBool(b) => row = st.bindText(2, if (b) { "1" } else { "0" })
                case JObj(_) => row = st.bindText(2, Json.pretty(v))
                case JArr(_) => row = st.bindText(2, Json.pretty(v))
                case JNull => row = st.bindText(2, "")
            }
        }
        row = row && st.stepFinish()
        if (!row) { st.finalize(); return false }
        st.reset()
    }
    st.finalize()
    return ok
}

/// 建表后的数据填充。失败早退（stmt 未 finalize 由 close 的 BUSY
/// 告警兜底——进程生命周期内可接受，正常路径全部 finalize）。
func graphDbFill(db: SqliteDb, graph: CodeGraph, funcPayload: JsonValue): Bool {
    let functions = match (Json.get(funcPayload, "functions")) {
        case Some(JArr(a)) => a
        case _ => ArrayList<JsonValue>()
    }
    let edgeItems = match (Json.get(funcPayload, "functionEdges")) {
        case Some(JArr(a)) => a
        case _ => ArrayList<JsonValue>()
    }

    // payload id（"f:file:line:name"）→ 整数主键（与 nodes 插入同序 1..N）
    let idMap = HashMap<String, Int64>()
    // 本次数据域里有节点的文件（--depth 截断时是 graph.files 的子集）
    let fileInPayload = HashSet<String>()
    var nextId: Int64 = 0
    for (f in functions) {
        nextId += 1
        idMap[Json.strAt(f, "id", "")] = nextId
        fileInPayload.add(Json.strAt(f, "file", ""))
    }

    // ── meta ──
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
    var ok = true
    ok = ok && putMeta("generator", GRAPH_DB_GENERATOR)
    ok = ok && putMeta("project", basename(graph.root))
    ok = ok && putMeta("root", graph.root)
    ok = ok && putMeta("files", Int64(graph.files.size).toString())
    ok = ok && putMeta("symbols", Int64(functions.size).toString())
    stMeta.finalize()
    if (!ok) { return false }

    // ── 成员级列的数据源：CodeGraph 的符号表（按稳定 id 对齐 payload 的节点）──
    // payload 的 functions[] 是渲染投影，成员级字段的唯一事实在 graph.files[].symbols。
    let symById = HashMap<String, SymDecl>()
    for (fe in graph.files) {
        for (sy in fe.symbols) { symById[sy.id(fe.relPath)] = sy }
    }

    // ── nodes ──
    let stNodeOpt = db.prepare("INSERT INTO nodes(id, kind, name, file, line, lang, findings, max_weight, sid, qual, end_line, col, sig, visibility, decl_only) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
    if (stNodeOpt.isNone()) { return false }
    let stNode = stNodeOpt.getOrThrow()
    for (f in functions) {
        // 同一 payload 产出的 id 一定在 idMap（同一循环建的表）；防御性 getOrThrow
        let sid = Json.strAt(f, "id", "")
        let id = idMap.get(sid).getOrThrow()
        let nFindings = match (Json.get(f, "findings")) {
            case Some(JArr(a)) => Int64(a.size)
            case _ => 0
        }
        var sy = SymDecl(Func, "", 0)
        match (symById.get(sid)) {
            case Some(v) => sy = v
            case None => ()
        }
        var row = stNode.bindInt(1, id)
        row = row && stNode.bindText(2, Json.strAt(f, "kind", ""))
        row = row && stNode.bindText(3, Json.strAt(f, "name", ""))
        row = row && stNode.bindText(4, Json.strAt(f, "file", ""))
        row = row && stNode.bindInt(5, Json.intAt(f, "line", 0))
        row = row && stNode.bindText(6, Json.strAt(f, "lang", ""))
        row = row && stNode.bindInt(7, nFindings)
        // weight = 该函数内疑点的最高档位（functionGraphData 的 maxW 既有口径）
        row = row && stNode.bindInt(8, Json.intAt(f, "weight", 0))
        row = row && stNode.bindText(9, sid)
        row = row && stNode.bindText(10, sy.qual)
        row = row && stNode.bindInt(11, sy.endLine)
        row = row && stNode.bindInt(12, sy.col)
        row = row && stNode.bindText(13, sy.sig)
        row = row && stNode.bindText(14, sy.visibility)
        row = row && stNode.bindInt(15, if (sy.declOnly) { 1 } else { 0 })
        row = row && stNode.stepFinish()
        if (!row) { stNode.finalize(); return false }
        stNode.reset()
    }
    stNode.finalize()

    // ── sites（调用点）──
    // 只收「文件在本次数据域里」的调用点：--depth 截断掉的文件里，调用方与被调方都
    // 不在 nodes 里，留下来只会是一批 src = 0 的孤儿行，把「有调用方」说成「没有」。
    // 例外：本来就没有任何符号的文件（顶层脚本、只有属性初始化器的文件）在 payload 里
    // 也没有节点，但它们的调用点是真实的「不在函数体内的调用」——照常入库。
    let symFiles = HashSet<String>()
    for (fe in graph.files) {
        if (fe.symbols.size > 0) { symFiles.add(fe.relPath) }
    }
    let stSiteOpt = db.prepare("INSERT INTO sites(src, dst, file, line, col, receiver, tier, name) VALUES(?, ?, ?, ?, ?, ?, ?, ?)")
    if (stSiteOpt.isNone()) { return false }
    let stSite = stSiteOpt.getOrThrow()
    for (site in graph.callSites) {
        if (!fileInPayload.contains(site.file) && symFiles.contains(site.file)) { continue }
        var src: Int64 = 0
        var dst: Int64 = 0
        match (idMap.get(site.caller)) {
            case Some(v) => src = v
            case None => ()
        }
        match (idMap.get(site.dst)) {
            case Some(v) => dst = v
            case None => ()
        }
        var row = stSite.bindInt(1, src)
        row = row && stSite.bindInt(2, dst)
        row = row && stSite.bindText(3, site.file)
        row = row && stSite.bindInt(4, site.line)
        row = row && stSite.bindInt(5, site.col)
        row = row && stSite.bindText(6, site.receiverText)
        row = row && stSite.bindText(7, site.tier)
        row = row && stSite.bindText(8, site.name)
        row = row && stSite.stepFinish()
        if (!row) { stSite.finalize(); return false }
        stSite.reset()
    }
    stSite.finalize()

    // ── edges ──
    let stEdgeOpt = db.prepare("INSERT INTO edges(src, dst, tier, weight) VALUES(?, ?, ?, ?)")
    if (stEdgeOpt.isNone()) { return false }
    let stEdge = stEdgeOpt.getOrThrow()
    for (e in edgeItems) {
        let src = idMap.get(Json.strAt(e, "from", ""))
        let dst = idMap.get(Json.strAt(e, "to", ""))
        // 端点不在 nodes ⇒ 跳过该边（词法数据自洽时不会发生；防御是为了
        // 「宁缺一行边」而不是写出一个悬空引用让 JOIN 查询静默丢行）
        if (src.isSome() && dst.isSome()) {
            var row = stEdge.bindInt(1, src.getOrThrow())
            row = row && stEdge.bindInt(2, dst.getOrThrow())
            row = row && stEdge.bindText(3, Json.strAt(e, "tier", "resolved"))
            row = row && stEdge.bindInt(4, Json.intAt(e, "w", 0))
            row = row && stEdge.stepFinish()
            if (!row) { stEdge.finalize(); return false }
            stEdge.reset()
        }
    }
    stEdge.finalize()

    // ── files（graph.files 原样：语言/行数/符号数）──
    let stFileOpt = db.prepare("INSERT INTO files(path, lang, lines, symbols) VALUES(?, ?, ?, ?)")
    if (stFileOpt.isNone()) { return false }
    let stFile = stFileOpt.getOrThrow()
    for (fe in graph.files) {
        var row = stFile.bindText(1, fe.relPath)
        row = row && stFile.bindText(2, fe.lang)
        row = row && stFile.bindInt(3, fe.lines)
        row = row && stFile.bindInt(4, Int64(fe.symbols.size))
        row = row && stFile.stepFinish()
        if (!row) { stFile.finalize(); return false }
        stFile.reset()
    }
    stFile.finalize()
    return true
}

// ─────────────────────────────────────────────────────────────────
// B. 置信度报告库（moongit confidence db）
//
//   meta(key, value)   score / files_analyzed / ast_used / ast_note /
//                      capped_kind / capped_total / root
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
// C. index 读路径（overview / query 的 SQL 聚合出口）
//
// 与写入器的单一口径关系：nodes/edges/files 全部由 graphDbFill 写入，
// 这里只 SELECT + 聚合，不重算任何词法事实。所有查询带 ORDER BY，
// 行序确定 ⇒ 出口逐字节确定（agent 对账前提，同构建纪律）。
// ─────────────────────────────────────────────────────────────────

/// nodes 表的读列清单（v2）。NodeRow 的字段与它**同序**——列下标只在这里出现一次。
let NODE_COLS: String = "id, sid, kind, name, qual, file, line, end_line, col, lang, sig, visibility, decl_only, findings, max_weight"

/// 一行符号（nodes 表的读出形态）。
struct NodeRow {
    let id: Int64
    let sid: String
    let kind: String
    let name: String
    let qual: String
    let file: String
    let line: Int64
    let endLine: Int64
    let col: Int64
    let lang: String
    let sig: String
    let visibility: String
    let declOnly: Bool
    let findings: Int64
    let maxWeight: Int64

    init(id: Int64, sid: String, kind: String, name: String, qual: String, file: String,
         line: Int64, endLine: Int64, col: Int64, lang: String, sig: String,
         visibility: String, declOnly: Bool, findings: Int64, maxWeight: Int64) {
        this.id = id
        this.sid = sid
        this.kind = kind
        this.name = name
        this.qual = qual
        this.file = file
        this.line = line
        this.endLine = endLine
        this.col = col
        this.lang = lang
        this.sig = sig
        this.visibility = visibility
        this.declOnly = declOnly
        this.findings = findings
        this.maxWeight = maxWeight
    }
}

func readNodeRow(st: SqliteStmt): NodeRow {
    return NodeRow(st.columnInt(0), st.columnText(1), st.columnText(2), st.columnText(3),
        st.columnText(4), st.columnText(5), st.columnInt(6), st.columnInt(7), st.columnInt(8),
        st.columnText(9), st.columnText(10), st.columnText(11), st.columnInt(12) != 0,
        st.columnInt(13), st.columnInt(14))
}

/// 「有效定义」判据的 SQL 片段：不是只有声明的符号，**或者**全工程（同语言）没有
/// 与它同 qual 的定义（纯接口方法、只有原型没有实现的声明仍然是可查的终点）。
/// 有定义的声明不单独算一个 def——它作为该定义的 decls 呈现。
let EFFECTIVE_DEF_SQL: String = "(n.decl_only = 0 OR NOT EXISTS (SELECT 1 FROM nodes d WHERE d.decl_only = 0 AND d.lang = n.lang AND d.qual = n.qual))"

/// 库是不是当前 schema。缺库 / 缺 meta 表 / generator 不是当前版本 ⇒ false。
/// 新鲜度判定（cli.indexProbeFresh）据它把旧版库当**过期**：v1 库的源探针可能
/// 与当前源一致，但它的 nodes 没有 sid/qual 列、也没有 sites 表——拿它跑 v2 查询
/// 只会得到一堆「查不到」的假答案。
public func indexDbIsCurrent(dbPath: String): Bool {
    if (!fileExists(dbPath)) { return false }
    let dbOpt = SqliteDb.openReadonly(dbPath)
    if (dbOpt.isNone()) { return false }
    let db = dbOpt.getOrThrow()
    var gen = ""
    try {
        let stOpt = db.prepare("SELECT value FROM meta WHERE key = 'generator'")
        if (stOpt.isSome()) {
            let st = stOpt.getOrThrow()
            if (st.stepHasRow()) { gen = st.columnText(0) }
            st.finalize()
        }
    } finally {
        db.close()
    }
    return gen == GRAPH_DB_GENERATOR
}

/// index overview 的统计（SQL 聚合，不是旧 overview 的全部投影）。
public struct IndexOverview {
    public let nodes: Int64
    public let edges: Int64
    public let files: Int64
    /// 符号按 kind 计数（kind ↑ 排定；空库 = 空数组恒发）
    public let byKind: ArrayList<(String, Int64)>
    /// 调用点总数（sites 表行数 = 每个「调用点 × 解析目标」一行）
    public let sites: Int64
    /// 未解析的调用点数（全工程无同名定义、且不是内建——外部依赖或拼错的名字）
    public let unresolved: Int64
    /// 按确信度分层的边数
    public let tierDirect: Int64
    public let tierResolved: Int64
    public let tierGuessed: Int64

    public init(nodes: Int64, edges: Int64, files: Int64, byKind: ArrayList<(String, Int64)>) {
        this(nodes, edges, files, byKind, 0, 0, 0, 0, 0)
    }

    public init(nodes: Int64, edges: Int64, files: Int64, byKind: ArrayList<(String, Int64)>,
                sites: Int64, unresolved: Int64, tierDirect: Int64, tierResolved: Int64,
                tierGuessed: Int64) {
        this.nodes = nodes
        this.edges = edges
        this.files = files
        this.byKind = byKind
        this.sites = sites
        this.unresolved = unresolved
        this.tierDirect = tierDirect
        this.tierResolved = tierResolved
        this.tierGuessed = tierGuessed
    }
}

/// 打开只读连接的统一入口：库不存在/打不开 → None（调用方报
/// 「先执行 moongit index gen」而不是编一个空统计）。
func indexDbOpenReadonly(dbPath: String): Option<SqliteDb> {
    if (!fileExists(dbPath)) { return None }
    return SqliteDb.openReadonly(dbPath)
}

func sqlScalarCount(db: SqliteDb, sql: String): Option<Int64> {
    let stOpt = db.prepare(sql)
    if (stOpt.isNone()) { return None }
    let st = stOpt.getOrThrow()
    var v: Option<Int64> = None
    if (st.stepHasRow()) {
        v = Some(st.columnInt(0))
    }
    st.finalize()
    return v
}

/// index overview 统计。库读不出来 → None（调用方向用户报错）。
/// v2 新增的三个数（sites / unresolved / tiers）在 v1 库上取不到（没有 sites 表）：
/// 按 0 发——键集恒定，不因库的版本而漂。v1 库不会真的走到这里
/// （新鲜度判定先把它当过期重建），这一支只为绕开自愈的直接读路径兜底。
public func indexOverviewRead(dbPath: String): Option<IndexOverview> {
    let dbOpt = indexDbOpenReadonly(dbPath)
    if (dbOpt.isNone()) { return None }
    let db = dbOpt.getOrThrow()
    try {
        let nNodes = sqlScalarCount(db, "SELECT COUNT(*) FROM nodes")
        let nEdges = sqlScalarCount(db, "SELECT COUNT(*) FROM edges")
        let nFiles = sqlScalarCount(db, "SELECT COUNT(*) FROM files")
        match (nNodes) {
            case Some(nn) =>
                match (nEdges) {
                    case Some(ne) =>
                        match (nFiles) {
                            case Some(nf) =>
                                let byKind = ArrayList<(String, Int64)>()
                                let stOpt = db.prepare("SELECT kind, COUNT(*) FROM nodes GROUP BY kind ORDER BY kind")
                                if (stOpt.isNone()) { return None }
                                let st = stOpt.getOrThrow()
                                while (st.stepHasRow()) {
                                    byKind.add((st.columnText(0), st.columnInt(1)))
                                }
                                st.finalize()
                                var nSites: Int64 = 0
                                var nUnres: Int64 = 0
                                var tDirect: Int64 = 0
                                var tResolved: Int64 = 0
                                var tGuessed: Int64 = 0
                                match (sqlScalarCount(db, "SELECT COUNT(*) FROM sites")) {
                                    case Some(v) => nSites = v
                                    case None => ()
                                }
                                match (sqlScalarCount(db, "SELECT COUNT(*) FROM sites WHERE dst = 0")) {
                                    case Some(v) => nUnres = v
                                    case None => ()
                                }
                                let stTOpt = db.prepare("SELECT tier, COUNT(*) FROM edges GROUP BY tier ORDER BY tier")
                                if (stTOpt.isSome()) {
                                    let stT = stTOpt.getOrThrow()
                                    while (stT.stepHasRow()) {
                                        let t = stT.columnText(0)
                                        let c = stT.columnInt(1)
                                        if (t == "direct") { tDirect = c }
                                        else if (t == "resolved") { tResolved = c }
                                        else if (t == "guessed") { tGuessed = c }
                                    }
                                    stT.finalize()
                                }
                                return Some(IndexOverview(nn, ne, nf, byKind, nSites, nUnres,
                                    tDirect, tResolved, tGuessed))
                            case None => return None
                        }
                    case None => return None
                }
            case None => return None
        }
    } finally {
        db.close()
    }
}

/// `index query <符号>` 的一体载荷：defs + callers/callees（函数级调用边 JOIN）
/// + perDef（逐定义的调用关系，消歧用）。None = 一个定义都没有（查不到 → 上层报错，不编结果）。
/// callers/callees 恒发（空数组也是「没有调用方」的有意义事实）。
///
/// `<符号>` 的三种形态：稳定 id（`f:…`）> 限定名（`Outer.start`）> 裸名。
/// 裸名命中多个不同的定义时 ambiguous = true，perDef 逐个给出各自的调用关系。
/// 顶层 callers/callees 是全部 defs 的汇总（既有键，语义不变）。
public func indexQuerySymbol(dbPath: String, name: String): Option<JsonValue> {
    let dbOpt = indexDbOpenReadonly(dbPath)
    if (dbOpt.isNone()) { return None }
    let db = dbOpt.getOrThrow()
    try {
        let (defs, mode) = resolveSymbolRows(db, name)
        if (defs.size == 0) { return None }
        let o = Json.obj()
        Json.set(o, "symbol", Json.of(name))
        Json.set(o, "ambiguous", Json.of(lookupIsAmbiguous(defs, mode)))
        let defArr = ArrayList<JsonValue>()
        for (d in defs) { defArr.add(symJsonOf(db, d)) }
        Json.set(o, "defs", JArr(defArr))
        // ── 顶层汇总（按对方符号聚合：权重求和、tier 取最确定的一档）──
        let callers = ArrayList<JsonValue>()
        for (rel in aggregateRelations(db, defs, true)) {
            callers.add(edgeJsonOf(db, rel.other, rel.tier, rel.weight, defs, true))
        }
        let callees = ArrayList<JsonValue>()
        for (rel in aggregateRelations(db, defs, false)) {
            callees.add(edgeJsonOf(db, rel.other, rel.tier, rel.weight, defs, false))
        }
        Json.set(o, "callers", JArr(callers))
        Json.set(o, "callees", JArr(callees))
        // ── 逐定义 ──
        let perDef = ArrayList<JsonValue>()
        for (d in defs) {
            let one = ArrayList<NodeRow>()
            one.add(d)
            let pd = Json.obj()
            Json.set(pd, "def", symJsonOf(db, d))
            let pc = ArrayList<JsonValue>()
            for (rel in aggregateRelations(db, one, true)) {
                pc.add(edgeJsonOf(db, rel.other, rel.tier, rel.weight, one, true))
            }
            let pe = ArrayList<JsonValue>()
            for (rel in aggregateRelations(db, one, false)) {
                pe.add(edgeJsonOf(db, rel.other, rel.tier, rel.weight, one, false))
            }
            Json.set(pd, "callers", JArr(pc))
            Json.set(pd, "callees", JArr(pe))
            perDef.add(pd)
        }
        Json.set(o, "perDef", JArr(perDef))
        return Some(o)
    } finally {
        db.close()
    }
}

/// `index query --file <路径>` / `index file <路径>` 的一体载荷：该文件的符号清单 +
/// 调入/调出文件与权重。None = 该文件不在索引里（查不到 → 上层报错，不编结果）。
/// calledBy / calls **不含文件自身**：文件内函数互调不是「调入/调出」，
/// 把它列出来等于让每个文件都「调用自己」。
public func indexQueryFile(dbPath: String, file: String): Option<JsonValue> {
    let dbOpt = indexDbOpenReadonly(dbPath)
    if (dbOpt.isNone()) { return None }
    let db = dbOpt.getOrThrow()
    try {
        // 前提：文件真的在索引里（files 表一行）。没有就 None——
        // 「这个文件没被索引过」不许被渲染成「它没有任何符号」。
        var exists = false
        var lang = ""
        var lines: Int64 = 0
        let stEOpt = db.prepare("SELECT lang, lines FROM files WHERE path = ?")
        if (stEOpt.isNone()) { return None }
        let stE = stEOpt.getOrThrow()
        if (stE.bindText(1, file) && stE.stepHasRow()) {
            exists = true
            lang = stE.columnText(0)
            lines = stE.columnInt(1)
        }
        stE.finalize()
        if (!exists) { return None }

        // ── 符号清单（文件里的全部符号，含只有声明的——outline 就要如实列出）──
        let symbols = ArrayList<JsonValue>()
        let stSOpt = db.prepare("SELECT ${NODE_COLS} FROM nodes n WHERE n.file = ? ORDER BY n.line, n.id")
        if (stSOpt.isNone()) { return None }
        let stS = stSOpt.getOrThrow()
        if (stS.bindText(1, file)) {
            while (stS.stepHasRow()) {
                symbols.add(symJsonOf(db, readNodeRow(stS)))
            }
        }
        stS.finalize()

        // ── 调入/调出文件 + 权重（函数级边按文件对聚合；排除文件自身）──
        func fileRows(sql: String): ArrayList<JsonValue> {
            let out = ArrayList<JsonValue>()
            let stOpt = db.prepare(sql)
            if (stOpt.isNone()) { return out }
            let st = stOpt.getOrThrow()
            if (st.bindText(1, file)) {
                while (st.stepHasRow()) {
                    let r = Json.obj()
                    Json.set(r, "file", Json.of(st.columnText(0)))
                    Json.set(r, "weight", Json.of(st.columnInt(1)))
                    out.add(r)
                }
            }
            st.finalize()
            return out
        }
        let calledBy = fileRows("SELECT f.file, SUM(e.weight) FROM edges e JOIN nodes f ON e.src = f.id JOIN nodes t ON e.dst = t.id WHERE t.file = ? AND f.file <> t.file GROUP BY f.file ORDER BY f.file")
        let calls = fileRows("SELECT t.file, SUM(e.weight) FROM edges e JOIN nodes f ON e.src = f.id JOIN nodes t ON e.dst = t.id WHERE f.file = ? AND t.file <> f.file GROUP BY t.file ORDER BY t.file")

        let o = Json.obj()
        Json.set(o, "file", Json.of(file))
        Json.set(o, "lang", Json.of(lang))
        Json.set(o, "lines", Json.of(lines))
        Json.set(o, "symbols", JArr(symbols))
        Json.set(o, "calledBy", JArr(calledBy))
        Json.set(o, "calls", JArr(calls))
        return Some(o)
    } finally {
        db.close()
    }
}
