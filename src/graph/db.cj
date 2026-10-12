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
public let GRAPH_DB_GENERATOR: String = "moongit graph db v1"

/// confidence db 的 meta.generator（同上）。
public let CONFIDENCE_DB_GENERATOR: String = "moongit confidence db v1"

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
//   nodes(id, kind, name, file, line, lang, findings, max_weight)
//   edges(src, dst, tier, weight)          src/dst = nodes.id
//   files(path, lang, lines, symbols)      graph.files 原样
//   索引：idx_nodes_name / idx_nodes_file / idx_edges_src / idx_edges_dst
//         —— agent 高频查询是「谁调我 / 我调谁 / 按名找符号」
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
            "CREATE TABLE nodes(id INTEGER PRIMARY KEY, kind TEXT, name TEXT, file TEXT, line INTEGER, lang TEXT, findings INTEGER, max_weight INTEGER)",
            "CREATE TABLE edges(src INTEGER, dst INTEGER, tier TEXT, weight INTEGER)",
            "CREATE TABLE files(path TEXT PRIMARY KEY, lang TEXT, lines INTEGER, symbols INTEGER)",
            "CREATE INDEX idx_nodes_name ON nodes(name)",
            "CREATE INDEX idx_nodes_file ON nodes(file)",
            "CREATE INDEX idx_edges_src ON edges(src)",
            "CREATE INDEX idx_edges_dst ON edges(dst)",
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
    var nextId: Int64 = 0
    for (f in functions) {
        nextId += 1
        idMap[Json.strAt(f, "id", "")] = nextId
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

    // ── nodes ──
    let stNodeOpt = db.prepare("INSERT INTO nodes(id, kind, name, file, line, lang, findings, max_weight) VALUES(?, ?, ?, ?, ?, ?, ?, ?)")
    if (stNodeOpt.isNone()) { return false }
    let stNode = stNodeOpt.getOrThrow()
    for (f in functions) {
        // 同一 payload 产出的 id 一定在 idMap（同一循环建的表）；防御性 getOrThrow
        let id = idMap.get(Json.strAt(f, "id", "")).getOrThrow()
        let nFindings = match (Json.get(f, "findings")) {
            case Some(JArr(a)) => Int64(a.size)
            case _ => 0
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
        row = row && stNode.stepFinish()
        if (!row) { stNode.finalize(); return false }
        stNode.reset()
    }
    stNode.finalize()

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
//   findings(id, kind, file, line, symbol, weight, dim, evidence)
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
            "CREATE TABLE findings(id INTEGER PRIMARY KEY, kind TEXT, file TEXT, line INTEGER, symbol TEXT, weight INTEGER, dim TEXT, evidence TEXT)",
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
    let stFOpt = db.prepare("INSERT INTO findings(id, kind, file, line, symbol, weight, dim, evidence) VALUES(?, ?, ?, ?, ?, ?, ?, ?)")
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

/// index overview 的统计（SQL 聚合，不是旧 overview 的全部投影）。
public struct IndexOverview {
    public let nodes: Int64
    public let edges: Int64
    public let files: Int64
    /// 符号按 kind 计数（kind ↑ 排定；空库 = 空数组恒发）
    public let byKind: ArrayList<(String, Int64)>

    public init(nodes: Int64, edges: Int64, files: Int64, byKind: ArrayList<(String, Int64)>) {
        this.nodes = nodes
        this.edges = edges
        this.files = files
        this.byKind = byKind
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
                                return Some(IndexOverview(nn, ne, nf, byKind))
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

/// `index query <符号>` 的一体载荷：defs（按名命中）+ callers/callees
///（函数级调用边 JOIN）。None = 一个定义都没有（查不到 → 上层报错，不编结果）。
/// callers/callees 恒发（空数组也是「没有调用方」的有意义事实）。
public func indexQuerySymbol(dbPath: String, name: String): Option<JsonValue> {
    let dbOpt = indexDbOpenReadonly(dbPath)
    if (dbOpt.isNone()) { return None }
    let db = dbOpt.getOrThrow()
    try {
        // ── defs ──
        let defs = ArrayList<JsonValue>()
        let stDOpt = db.prepare("SELECT id, kind, file, line, lang, findings, max_weight FROM nodes WHERE name = ? ORDER BY file, line")
        if (stDOpt.isNone()) { return None }
        let stD = stDOpt.getOrThrow()
        if (stD.bindText(1, name)) {
            while (stD.stepHasRow()) {
                let d = Json.obj()
                Json.set(d, "id", Json.of(stD.columnInt(0)))
                Json.set(d, "kind", Json.of(stD.columnText(1)))
                Json.set(d, "file", Json.of(stD.columnText(2)))
                Json.set(d, "line", Json.of(stD.columnInt(3)))
                Json.set(d, "lang", Json.of(stD.columnText(4)))
                Json.set(d, "findings", Json.of(stD.columnInt(5)))
                Json.set(d, "maxWeight", Json.of(stD.columnInt(6)))
                defs.add(d)
            }
        }
        stD.finalize()
        if (Int64(defs.size) == 0) { return None }

        // ── callers：谁调我（按调用方聚合权重；同文件同名一处一行）──
        // MIN(e.tier)：同一调用方对同名被调的多条边各带 tier，取字典序最小
        // 做代表——direct < guessed < resolved 恰是字典序，倾向报更确定的
        // 那一档；聚合是展示口径，明细在 edges 表里一查便知。
        func relRows(sql: String, param: String): ArrayList<JsonValue> {
            let out = ArrayList<JsonValue>()
            let stOpt = db.prepare(sql)
            if (stOpt.isNone()) { return out }
            let st = stOpt.getOrThrow()
            if (st.bindText(1, param)) {
                while (st.stepHasRow()) {
                    let r = Json.obj()
                    Json.set(r, "name", Json.of(st.columnText(0)))
                    Json.set(r, "file", Json.of(st.columnText(1)))
                    Json.set(r, "line", Json.of(st.columnInt(2)))
                    Json.set(r, "weight", Json.of(st.columnInt(3)))
                    Json.set(r, "tier", Json.of(st.columnText(4)))
                    out.add(r)
                }
            }
            st.finalize()
            return out
        }
        let callers = relRows("SELECT n.name, n.file, n.line, SUM(e.weight), MIN(e.tier) FROM edges e JOIN nodes n ON e.src = n.id JOIN nodes d ON e.dst = d.id WHERE d.name = ? GROUP BY n.id ORDER BY n.file, n.line, n.name", name)
        let callees = relRows("SELECT n.name, n.file, n.line, SUM(e.weight), MIN(e.tier) FROM edges e JOIN nodes n ON e.dst = n.id JOIN nodes c ON e.src = c.id WHERE c.name = ? GROUP BY n.id ORDER BY n.file, n.line, n.name", name)

        let o = Json.obj()
        Json.set(o, "symbol", Json.of(name))
        Json.set(o, "defs", JArr(defs))
        Json.set(o, "callers", JArr(callers))
        Json.set(o, "callees", JArr(callees))
        return Some(o)
    } finally {
        db.close()
    }
}

/// `index query --file <路径>` 的一体载荷：该文件的符号清单 + 调入/调出
/// 文件与权重。None = 该文件不在索引里（查不到 → 上层报错，不编结果）。
public func indexQueryFile(dbPath: String, file: String): Option<JsonValue> {
    let dbOpt = indexDbOpenReadonly(dbPath)
    if (dbOpt.isNone()) { return None }
    let db = dbOpt.getOrThrow()
    try {
        // 前提：文件真的在索引里（files 表一行）。没有就 None——
        // 「这个文件没被索引过」不许被渲染成「它没有任何符号」。
        var exists = false
        let stEOpt = db.prepare("SELECT COUNT(*) FROM files WHERE path = ?")
        if (stEOpt.isNone()) { return None }
        let stE = stEOpt.getOrThrow()
        if (stE.bindText(1, file) && stE.stepHasRow() && stE.columnInt(0) > 0) {
            exists = true
        }
        stE.finalize()
        if (!exists) { return None }

        // ── 符号清单 ──
        let symbols = ArrayList<JsonValue>()
        let stSOpt = db.prepare("SELECT name, kind, line FROM nodes WHERE file = ? ORDER BY line, name")
        if (stSOpt.isNone()) { return None }
        let stS = stSOpt.getOrThrow()
        if (stS.bindText(1, file)) {
            while (stS.stepHasRow()) {
                let s = Json.obj()
                Json.set(s, "name", Json.of(stS.columnText(0)))
                Json.set(s, "kind", Json.of(stS.columnText(1)))
                Json.set(s, "line", Json.of(stS.columnInt(2)))
                symbols.add(s)
            }
        }
        stS.finalize()

        // ── 调入/调出文件 + 权重（函数级边按文件对聚合）──
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
        let calledBy = fileRows("SELECT f.file, SUM(e.weight) FROM edges e JOIN nodes f ON e.src = f.id JOIN nodes t ON e.dst = t.id WHERE t.file = ? GROUP BY f.file ORDER BY f.file")
        let calls = fileRows("SELECT t.file, SUM(e.weight) FROM edges e JOIN nodes f ON e.src = f.id JOIN nodes t ON e.dst = t.id WHERE f.file = ? GROUP BY t.file ORDER BY t.file")

        let o = Json.obj()
        Json.set(o, "file", Json.of(file))
        Json.set(o, "symbols", JArr(symbols))
        Json.set(o, "calledBy", JArr(calledBy))
        Json.set(o, "calls", JArr(calls))
        return Some(o)
    } finally {
        db.close()
    }
}
