// graph/query.cj — index 的 v2 查询面：符号消歧 / 模糊搜索 / 引用点 / 影响面。
//
// 【单一口径】这里只 SELECT + 聚合，不重算任何词法事实：符号来自 nodes，
// 调用关系来自 edges（caller → callee 聚合）与 sites（每个调用点一行）。
// Sym / Edge 两个 JSON 形状各只有一个构造点（symJsonOf / edgeJsonOf）——
// query / search / refs / impact / file 五个出口共用，别在任何出口重写字段列表。
//
// 【确定性】所有查询带 ORDER BY；需要内存聚合的地方物化后按全序排定
//（file ↑ → line ↑ → id ↑）。同一份索引两次查询逐字节一致。
package cambium.graph

import std.collection.*
import cambium.util.*

// MARK: - 符号解析与 JSON 形状

/// `index query` 的命中方式（内部用；不进 JSON）。
let LOOKUP_NONE: Int64 = 0
let LOOKUP_NAME: Int64 = 1
let LOOKUP_QUAL: Int64 = 2
let LOOKUP_ID: Int64 = 3

/// Edge.sites 的上限（一条边上最多列多少个调用点；完整清单用 `index refs`）。
let EDGE_SITES_CAP: Int64 = 50

/// 把 `<符号>` 解析成定义行。三种形态按优先级：稳定 id（`f:…`）> 限定名（含 `.`）
/// > 裸名。限定名查不到时退回裸名。
///
/// id 指到的是「另有同名定义的声明」（头文件原型 / 接口签名）时，回它的**定义**：
/// 调用点连的是定义，原型自己没有调用方——直接回原型会让 agent 把「没人调用」当成事实。
/// 声明处挂在定义的 `decls` 上，不会丢。只有声明、没有定义的（平台条件编译 / 外部库）
/// 照常回声明本身。
/// 返回 (定义行, 命中方式)；一行都没有 = 查不到。
func resolveSymbolRows(db: SqliteDb, symbol: String): (ArrayList<NodeRow>, Int64) {
    let out = ArrayList<NodeRow>()
    if (symbol.isEmpty()) { return (out, LOOKUP_NONE) }
    func rowsWhere(whereSql: String, param: String): ArrayList<NodeRow> {
        let res = ArrayList<NodeRow>()
        let stOpt = db.prepare("SELECT ${NODE_COLS} FROM nodes n WHERE " + whereSql + " ORDER BY n.file, n.line, n.id")
        if (stOpt.isNone()) { return res }
        let st = stOpt.getOrThrow()
        if (st.bindText(1, param)) {
            while (st.stepHasRow()) { res.add(readNodeRow(st)) }
        }
        st.finalize()
        return res
    }
    func rowsWhereLangQual(lang: String, qual: String): ArrayList<NodeRow> {
        let res = ArrayList<NodeRow>()
        let stOpt = db.prepare("SELECT ${NODE_COLS} FROM nodes n WHERE n.decl_only = 0 AND n.lang = ? AND n.qual = ? ORDER BY n.file, n.line, n.id")
        if (stOpt.isNone()) { return res }
        let st = stOpt.getOrThrow()
        if (st.bindText(1, lang) && st.bindText(2, qual)) {
            while (st.stepHasRow()) { res.add(readNodeRow(st)) }
        }
        st.finalize()
        return res
    }
    if (symbol.startsWith("f:")) {
        let rows = rowsWhere("n.sid = ?", symbol)
        if (rows.size == 1 && rows[0].declOnly) {
            // 与 declRowsOf 同一条孪生判据：同语言、同 qual、有体
            let defs = rowsWhereLangQual(rows[0].lang, rows[0].qual)
            if (defs.size > 0) { return (defs, LOOKUP_ID) }
        }
        return (rows, LOOKUP_ID)
    }
    match (symbol.lastIndexOf(".")) {
        case Some(_) =>
            let byQual = rowsWhere("n.qual = ? AND " + EFFECTIVE_DEF_SQL, symbol)
            if (byQual.size > 0) { return (byQual, LOOKUP_QUAL) }
        case None => ()
    }
    return (rowsWhere("n.name = ? AND " + EFFECTIVE_DEF_SQL, symbol), LOOKUP_NAME)
}

/// 裸名命中是否「有歧义」：落到了不止一个限定名、或不止一个文件上。
/// 限定名与 id 的命中永远不算歧义（它们本来就是消歧后的写法）。
func lookupIsAmbiguous(defs: ArrayList<NodeRow>, mode: Int64): Bool {
    if (mode != LOOKUP_NAME || defs.size <= 1) { return false }
    let quals = HashSet<String>()
    let files = HashSet<String>()
    for (d in defs) {
        quals.add(d.qual)
        files.add(d.file)
    }
    return Int64(quals.size) > 1 || Int64(files.size) > 1
}

/// 一行符号的声明处：同语言、同 qual、只有声明（decl_only）的其它节点。
func declRowsOf(db: SqliteDb, r: NodeRow): ArrayList<(String, Int64)> {
    let out = ArrayList<(String, Int64)>()
    if (r.declOnly) { return out }
    let stOpt = db.prepare("SELECT file, line FROM nodes WHERE decl_only = 1 AND lang = ? AND qual = ? AND id <> ? ORDER BY file, line")
    if (stOpt.isNone()) { return out }
    let st = stOpt.getOrThrow()
    if (st.bindText(1, r.lang) && st.bindText(2, r.qual) && st.bindInt(3, r.id)) {
        while (st.stepHasRow()) { out.add((st.columnText(0), st.columnInt(1))) }
    }
    st.finalize()
    return out
}

/// `Sym` 的唯一构造点。键集恒定（16 键），不随数据状态增减：
///   id        稳定 id（`f:<file>:<line>:<name>`，同文件同行同名者带 #n 后缀）
///   dbId      SQLite 整数主键（插入序，不稳定——只用于同一次查询内对账）
///   decls     声明处 [{file, line}]（头文件原型 / 接口签名；没有 = 空数组）
func symJsonOf(db: SqliteDb, r: NodeRow): JsonValue {
    let d = Json.obj()
    Json.set(d, "id", Json.of(r.sid))
    Json.set(d, "dbId", Json.of(r.id))
    Json.set(d, "kind", Json.of(r.kind))
    Json.set(d, "name", Json.of(r.name))
    Json.set(d, "qual", Json.of(r.qual))
    Json.set(d, "file", Json.of(r.file))
    Json.set(d, "line", Json.of(r.line))
    Json.set(d, "endLine", Json.of(r.endLine))
    Json.set(d, "col", Json.of(r.col))
    Json.set(d, "lang", Json.of(r.lang))
    Json.set(d, "sig", Json.of(r.sig))
    Json.set(d, "visibility", Json.of(r.visibility))
    Json.set(d, "declOnly", Json.of(r.declOnly))
    Json.set(d, "findings", Json.of(r.findings))
    Json.set(d, "maxWeight", Json.of(r.maxWeight))
    let decls = ArrayList<JsonValue>()
    for ((f, ln) in declRowsOf(db, r)) {
        let o = Json.obj()
        Json.set(o, "file", Json.of(f))
        Json.set(o, "line", Json.of(ln))
        decls.add(o)
    }
    Json.set(d, "decls", JArr(decls))
    return d
}

/// Sym + 一个附加键（search 的 score / impact 的 distance）。
func symJsonWith(db: SqliteDb, r: NodeRow, extraKey: String, extra: JsonValue): JsonValue {
    let d = symJsonOf(db, r)
    Json.set(d, extraKey, extra)
    return d
}

/// 某一侧的关系行：对方符号 + tier + 权重。
struct RelRow {
    let other: NodeRow
    let tier: String
    let weight: Int64
    init(other: NodeRow, tier: String, weight: Int64) {
        this.other = other
        this.tier = tier
        this.weight = weight
    }
}

/// defs 的调用方（incoming）或被调方（out去），按对方符号聚合：
/// 权重求和、tier 取最确定的一档。顺序 (file ↑ → line ↑ → id ↑)。
func aggregateRelations(db: SqliteDb, defs: ArrayList<NodeRow>, incoming: Bool): ArrayList<RelRow> {
    let agg = HashMap<Int64, RelRow>()
    let order = ArrayList<Int64>()
    let sql = if (incoming) {
        "SELECT ${NODE_COLS}, e.tier, e.weight FROM edges e JOIN nodes c ON c.id = e.src WHERE e.dst = ? ORDER BY c.file, c.line, c.id"
    } else {
        "SELECT ${NODE_COLS}, e.tier, e.weight FROM edges e JOIN nodes c ON c.id = e.dst WHERE e.src = ? ORDER BY c.file, c.line, c.id"
    }
    let stOpt = db.prepare(sql)
    if (stOpt.isNone()) { return ArrayList<RelRow>() }
    let st = stOpt.getOrThrow()
    for (d in defs) {
        if (!st.bindInt(1, d.id)) { continue }
        while (st.stepHasRow()) {
            let other = readNodeRow(st)
            let tier = st.columnText(15)
            let weight = st.columnInt(16)
            match (agg.get(other.id)) {
                case Some(prev) =>
                    let best = if (tierRank(tier) < tierRank(prev.tier)) { tier } else { prev.tier }
                    agg[other.id] = RelRow(prev.other, best, prev.weight + weight)
                case None =>
                    agg[other.id] = RelRow(other, tier, weight)
                    order.add(other.id)
            }
        }
        st.reset()
    }
    st.finalize()
    let out = ArrayList<RelRow>()
    for (id in order) {
        match (agg.get(id)) {
            case Some(r) => out.add(r)
            case None => ()
        }
    }
    // order 是各 def 查询结果的拼接：按 (file, line, id) 补成全序
    insertionSortBy(out, { a, b =>
        if (a.other.file != b.other.file) { return a.other.file < b.other.file }
        if (a.other.line != b.other.line) { return a.other.line < b.other.line }
        return a.other.id < b.other.id
    })
    return out
}

/// `Edge` 的唯一构造点：name/qual/file/line 是**对方**符号的位置，
/// sites 是这条关系上的调用点（至多 EDGE_SITES_CAP 个，全量见 `index refs`）。
func edgeJsonOf(db: SqliteDb, other: NodeRow, tier: String, weight: Int64,
                defs: ArrayList<NodeRow>, incoming: Bool): JsonValue {
    let e = Json.obj()
    Json.set(e, "name", Json.of(other.name))
    Json.set(e, "qual", Json.of(other.qual))
    Json.set(e, "file", Json.of(other.file))
    Json.set(e, "line", Json.of(other.line))
    Json.set(e, "weight", Json.of(weight))
    Json.set(e, "tier", Json.of(tier))
    let sites = ArrayList<JsonValue>()
    let stOpt = db.prepare("SELECT file, line, col, receiver FROM sites WHERE src = ? AND dst = ? ORDER BY line, col, file LIMIT ?")
    if (stOpt.isSome()) {
        let st = stOpt.getOrThrow()
        for (d in defs) {
            if (Int64(sites.size) >= EDGE_SITES_CAP) { break }
            let src = if (incoming) { other.id } else { d.id }
            let dst = if (incoming) { d.id } else { other.id }
            let cap = EDGE_SITES_CAP - Int64(sites.size)
            if (st.bindInt(1, src) && st.bindInt(2, dst) && st.bindInt(3, cap)) {
                while (st.stepHasRow()) {
                    let s = Json.obj()
                    Json.set(s, "file", Json.of(st.columnText(0)))
                    Json.set(s, "line", Json.of(st.columnInt(1)))
                    Json.set(s, "col", Json.of(st.columnInt(2)))
                    Json.set(s, "receiver", Json.of(st.columnText(3)))
                    sites.add(s)
                }
            }
            st.reset()
        }
        st.finalize()
    }
    Json.set(e, "sites", JArr(sites))
    return e
}

// MARK: - 模糊搜索

/// ASCII 小写（标识符只有 ASCII 字母有大小写；非 ASCII 字节原样保留）。
func lowerName(s: String): String {
    let b = s.toArray()
    let out = ArrayList<UInt8>()
    for (c in b) {
        if (c >= 65 && c <= 90) { out.add(c + 32) } else { out.add(c) }
    }
    return fromUtf8Lossy(out.toArray())
}

/// 子串查找（字节级，零正则）；没有 = -1。
func indexOfSub(s: String, needle: String): Int64 {
    match (s.indexOf(needle)) {
        case Some(i) => return i
        case None => return -1
    }
}

/// needle 的字节是否按顺序出现在 name 里（不要求连续）。
func isSubsequenceOf(needle: String, name: String): Bool {
    let nn = Int64(needle.size)
    let nm = Int64(name.size)
    var j: Int64 = 0
    var i: Int64 = 0
    while (i < nm && j < nn) {
        if (name[i] == needle[j]) { j += 1 }
        i += 1
    }
    return j == nn
}

/// 搜索打分（大小写不敏感）：
///   精确等于 name 100 > 精确等于 qual 98 > name 前缀 85
///   > name 里的词首/子串 65 > qual 里的子串 50 > name 的子序列 ≤ 40；
/// 不命中 = 0。并列时的次序由调用方定：更短的名字优先，再按路径。
func searchScore(name: String, qual: String, pattern: String): Int64 {
    if (pattern.isEmpty()) { return 0 }
    let pat = lowerName(pattern)
    let ln = lowerName(name)
    let lq = lowerName(qual)
    if (ln == pat) { return 100 }
    if (lq == pat) { return 98 }
    if (ln.startsWith(pat)) { return 85 }
    if (indexOfSub(ln, pat) >= 0) { return 65 }
    if (indexOfSub(lq, pat) >= 0) { return 50 }
    if (isSubsequenceOf(pat, ln)) {
        // 越贴着 name 的长度越像：20 + 20 × (pattern 长度 / name 长度)，封顶 40
        let nm = Int64(name.size)
        if (nm <= 0) { return 0 }
        let sc = 20 + (20 * Int64(pat.size)) / nm
        return if (sc > 40) { 40 } else { sc }
    }
    return 0
}

/// `index search <pattern>`：符号模糊搜索（name 与 qual，大小写不敏感）。
/// kind / lang / file 为空 = 不限。limit ≤ 0 用默认值（30）。
/// 输出键集恒定：query / mode / total / truncated / results[]（Sym + score）。
/// total = 命中总数（截断前），truncated = 结果被 limit 截过。
public func indexSearch(dbPath: String, query: String, kind: String, lang: String,
                        file: String, limit0: Int64): JsonValue {
    let limit = if (limit0 <= 0) { 30 } else { limit0 }
    let o = Json.obj()
    Json.set(o, "query", Json.of(query))
    Json.set(o, "mode", Json.of("fuzzy"))
    let scored = ArrayList<(Int64, NodeRow)>()
    let dbOpt = indexDbOpenReadonly(dbPath)
    match (dbOpt) {
        case None => ()
        case Some(db) =>
            try {
                var sql = "SELECT ${NODE_COLS} FROM nodes n WHERE " + EFFECTIVE_DEF_SQL
                if (!kind.isEmpty()) { sql += " AND n.kind = ?" }
                if (!lang.isEmpty()) { sql += " AND n.lang = ?" }
                if (!file.isEmpty()) { sql += " AND n.file = ?" }
                sql += " ORDER BY n.file, n.line, n.id"
                let stOpt = db.prepare(sql)
                if (stOpt.isSome()) {
                    let st = stOpt.getOrThrow()
                    var idx: Int64 = 1
                    var ok = true
                    if (!kind.isEmpty()) { ok = st.bindText(idx, kind); idx += 1 }
                    if (ok && !lang.isEmpty()) { ok = st.bindText(idx, lang); idx += 1 }
                    if (ok && !file.isEmpty()) { ok = st.bindText(idx, file); idx += 1 }
                    if (ok) {
                        while (st.stepHasRow()) {
                            let r = readNodeRow(st)
                            let sc = searchScore(r.name, r.qual, query)
                            if (sc > 0) { scored.add((sc, r)) }
                        }
                    }
                    st.finalize()
                }
                // 全序：分数 ↓ → 名字短者优先 → 路径 → 行 → id
                insertionSortBy(scored, { a, b =>
                    if (a[0] != b[0]) { return a[0] > b[0] }
                    if (a[1].name.size != b[1].name.size) { return a[1].name.size < b[1].name.size }
                    if (a[1].file != b[1].file) { return a[1].file < b[1].file }
                    if (a[1].line != b[1].line) { return a[1].line < b[1].line }
                    return a[1].id < b[1].id
                })
                Json.set(o, "total", Json.of(Int64(scored.size)))
                Json.set(o, "truncated", Json.of(Int64(scored.size) > limit))
                let results = ArrayList<JsonValue>()
                var i: Int64 = 0
                while (i < Int64(scored.size) && i < limit) {
                    results.add(symJsonWith(db, scored[i][1], "score", Json.of(scored[i][0])))
                    i += 1
                }
                Json.set(o, "results", JArr(results))
            } finally {
                db.close()
            }
    }
    if (!Json.has(o, "total")) {
        // 库读不出来：不编结果，如实给空的搜索结果（调用方在更早一层已经报过「先 gen」）
        Json.set(o, "total", Json.of(0))
        Json.set(o, "truncated", Json.of(false))
        Json.set(o, "results", Json.arr())
    }
    return o
}

// MARK: - 引用点

/// `index refs <symbol>`：解析到该符号定义的**每一个**调用点
/// （含不在任何函数体内的——属性初始化器、模块级代码；此时 caller 为空）。
/// 查不到符号 → None。
public func indexRefs(dbPath: String, symbol: String): Option<JsonValue> {
    let dbOpt = indexDbOpenReadonly(dbPath)
    if (dbOpt.isNone()) { return None }
    let db = dbOpt.getOrThrow()
    try {
        let (defs, _) = resolveSymbolRows(db, symbol)
        if (defs.size == 0) { return None }
        let o = Json.obj()
        Json.set(o, "symbol", Json.of(symbol))
        let defArr = ArrayList<JsonValue>()
        for (d in defs) { defArr.add(symJsonOf(db, d)) }
        Json.set(o, "defs", JArr(defArr))
        let sites = ArrayList<JsonValue>()
        let callers = HashMap<Int64, NodeRow>()
        for (d in defs) {
            let stOpt = db.prepare("SELECT src, file, line, col, receiver, tier, name FROM sites WHERE dst = ? ORDER BY file, line, col, name")
            if (stOpt.isNone()) { continue }
            let st = stOpt.getOrThrow()
            if (st.bindInt(1, d.id)) {
                while (st.stepHasRow()) {
                    let src = st.columnInt(0)
                    var caller = NodeRow(0, "", "", "", "", "", 0, 0, 0, "", "", "", false, 0, 0)
                    var hasCaller = false
                    if (src != 0) {
                        match (callers.get(src)) {
                            case Some(c) =>
                                caller = c
                                hasCaller = true
                            case None =>
                                let cOpt = db.prepare("SELECT ${NODE_COLS} FROM nodes n WHERE n.id = ?")
                                if (cOpt.isSome()) {
                                    let cst = cOpt.getOrThrow()
                                    if (cst.bindInt(1, src) && cst.stepHasRow()) {
                                        caller = readNodeRow(cst)
                                        hasCaller = true
                                        callers[src] = caller
                                    }
                                    cst.finalize()
                                }
                        }
                    }
                    let s = Json.obj()
                    Json.set(s, "defId", Json.of(d.sid))
                    Json.set(s, "file", Json.of(st.columnText(1)))
                    Json.set(s, "line", Json.of(st.columnInt(2)))
                    Json.set(s, "col", Json.of(st.columnInt(3)))
                    Json.set(s, "receiver", Json.of(st.columnText(4)))
                    Json.set(s, "tier", Json.of(st.columnText(5)))
                    Json.set(s, "caller", Json.of(if (hasCaller) { caller.sid } else { "" }))
                    Json.set(s, "callerQual", Json.of(if (hasCaller) { caller.qual } else { "" }))
                    Json.set(s, "callerFile", Json.of(if (hasCaller) { caller.file } else { "" }))
                    Json.set(s, "callerLine", Json.of(if (hasCaller) { caller.line } else { 0 }))
                    sites.add(s)
                }
            }
            st.finalize()
        }
        Json.set(o, "sites", JArr(sites))
        return Some(o)
    } finally {
        db.close()
    }
}

// MARK: - 影响面

/// `index impact <symbol> [--depth N]`：沿 direct / resolved 的调用边**反向**
/// 传递闭包——「这个符号变了，谁会跟着坏」。guessed 边不参与（它本身就不确定）。
/// 递归是真实的调用关系，照常计入（distance ≥ 1）。查不到符号 → None。
public func indexImpact(dbPath: String, symbol: String, depth0: Int64): Option<JsonValue> {
    let depth = if (depth0 <= 0) { 4 } else { depth0 }
    let dbOpt = indexDbOpenReadonly(dbPath)
    if (dbOpt.isNone()) { return None }
    let db = dbOpt.getOrThrow()
    try {
        let (defs, _) = resolveSymbolRows(db, symbol)
        if (defs.size == 0) { return None }
        // 广度优先：frontier = 当前层的节点 id；visited 含起点（自递归不会重复入队）
        let dist = HashMap<Int64, Int64>()
        let hit = HashMap<Int64, NodeRow>()
        let order = ArrayList<Int64>()
        var frontier = ArrayList<Int64>()
        for (d in defs) {
            if (!dist.contains(d.id)) {
                dist[d.id] = 0
                frontier.add(d.id)
            }
        }
        let stOpt = db.prepare("SELECT ${NODE_COLS} FROM edges e JOIN nodes c ON c.id = e.src WHERE e.dst = ? AND e.tier IN ('direct', 'resolved') ORDER BY c.file, c.line, c.id")
        if (stOpt.isSome()) {
            let st = stOpt.getOrThrow()
            var level: Int64 = 0
            while (level < depth && frontier.size > 0) {
                level += 1
                let next = ArrayList<Int64>()
                for (id in frontier) {
                    if (!st.bindInt(1, id)) { continue }
                    while (st.stepHasRow()) {
                        let r = readNodeRow(st)
                        if (!dist.contains(r.id)) {
                            dist[r.id] = level
                            hit[r.id] = r
                            order.add(r.id)
                            next.add(r.id)
                        }
                    }
                    st.reset()
                }
                frontier = next
            }
            st.finalize()
        }
        let o = Json.obj()
        Json.set(o, "symbol", Json.of(symbol))
        Json.set(o, "def", symJsonOf(db, defs[0]))
        Json.set(o, "depth", Json.of(depth))
        let impacted = ArrayList<(Int64, NodeRow)>()
        for (id in order) {
            match (hit.get(id)) {
                case Some(r) =>
                    match (dist.get(id)) {
                        case Some(lv) => impacted.add((lv, r))
                        case None => ()
                    }
                case None => ()
            }
        }
        insertionSortBy(impacted, { a, b =>
            if (a[0] != b[0]) { return a[0] < b[0] }
            if (a[1].file != b[1].file) { return a[1].file < b[1].file }
            if (a[1].line != b[1].line) { return a[1].line < b[1].line }
            return a[1].id < b[1].id
        })
        let arr = ArrayList<JsonValue>()
        let perFile = ArrayList<String>()
        let perFileCount = HashMap<String, Int64>()
        for ((lv, r) in impacted) {
            arr.add(symJsonWith(db, r, "distance", Json.of(lv)))
            match (perFileCount.get(r.file)) {
                case Some(c) => perFileCount[r.file] = c + 1
                case None =>
                    perFileCount[r.file] = 1
                    perFile.add(r.file)
            }
        }
        Json.set(o, "impacted", JArr(arr))
        insertionSort(perFile)
        let files = ArrayList<JsonValue>()
        for (f in perFile) {
            let fo = Json.obj()
            Json.set(fo, "file", Json.of(f))
            Json.set(fo, "symbols", Json.of(perFileCount.get(f).getOrThrow()))
            files.add(fo)
        }
        Json.set(o, "files", JArr(files))
        return Some(o)
    } finally {
        db.close()
    }
}
