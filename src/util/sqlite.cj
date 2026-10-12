// util/sqlite.cj — libsqlite3 的 C 互操作薄层（单文件 SQLite 存储的底层）。
//
// 【依赖决策（用户 directed，2026-10-11）】graph db / confidence db 两个
// 单文件 SQLite 能力明确要求 SQLite；按「不引入第三方源码」的约束，
// 走**系统自带 libsqlite3** 的 C ABI 互操作（macOS/Linux 发行版均内置；
// cjpm.toml link-option 追加 `-lsqlite3` 完成链接）。「引擎零第三方
// 依赖」的既有口径不变：libsqlite3 是操作系统组件，不是第三方包；
// 引擎的 JSON / SHA-256 / Markdown 仍然全部自研。
//
// 【边界】对 sqlite3 C ABI 的**全部**调用收口在本文件；上层
//（graph/db.cj 与测试）只见 SqliteDb / SqliteStmt 两个安全包装。
// SQLITE_OK 检查不省略，失败一律 Log.warn 并带上 sqlite3_errmsg 的原因。
// sqlite3* / sqlite3_stmt* 是 opaque 句柄，用 CPointer<Unit> 表达
//（它们的内部布局我们不关心，也与 sqlite 版本无关）。
//
// 【字符串生命周期】
//   · 仓颉 String → CString：LibC.mallocCString（一次拷贝），用完
//     freeCString 释放——任何 bind/exec 调用返回后立即释放，不留悬挂。
//   · CString → 仓颉 String：toString()（再拷贝一次）。
//   · sqlite3_bind_text 的 destructor 传 SQLITE_TRANSIENT（即 -1 的
//     函数指针 cast）：sqlite 立即拷贝字符串内容，绑定调用返回后
//     仓颉侧临时 CString 即可释放——不依赖「缓冲区必须活到 step」
//     的 STATIC 语义，也就没有 use-after-free 的时序约束。
package moongit.util

// ---- sqlite3 C ABI 最小函数面（全部为非变参函数，可直接声明）----
// 签名对照 https://www.sqlite.org/c3ref/。比能力清单多声明三个，均为
// 资源/错误卫生所必需：
//   sqlite3_finalize —— prepare 出的每条语句必须 finalize，否则句柄泄漏；
//   sqlite3_reset    —— 同一语句多次执行（批量 INSERT）必须复位；
//   sqlite3_free     —— sqlite3_exec 写出的 errmsg 缓冲归 sqlite 管理，
//                       必须用它释放（LibC.free 释放别人的分配器 = UB）。
foreign func sqlite3_open_v2(filename: CString, ppDb: CPointer<CPointer<Unit>>, flags: Int32, zVfs: CPointer<Unit>): Int32
foreign func sqlite3_close(db: CPointer<Unit>): Int32
foreign func sqlite3_exec(db: CPointer<Unit>, sql: CString, callback: CPointer<Unit>, arg: CPointer<Unit>, errmsg: CPointer<CString>): Int32
foreign func sqlite3_prepare_v2(db: CPointer<Unit>, zSql: CString, nByte: Int32, ppStmt: CPointer<CPointer<Unit>>, pzTail: CPointer<CPointer<Unit>>): Int32
foreign func sqlite3_finalize(stmt: CPointer<Unit>): Int32
foreign func sqlite3_reset(stmt: CPointer<Unit>): Int32
foreign func sqlite3_bind_int64(stmt: CPointer<Unit>, idx: Int32, value: Int64): Int32
foreign func sqlite3_bind_text(stmt: CPointer<Unit>, idx: Int32, value: CString, n: Int32, destructor: CPointer<Unit>): Int32
foreign func sqlite3_step(stmt: CPointer<Unit>): Int32
foreign func sqlite3_column_int64(stmt: CPointer<Unit>, col: Int32): Int64
foreign func sqlite3_column_text(stmt: CPointer<Unit>, col: Int32): CPointer<UInt8>
foreign func sqlite3_errmsg(db: CPointer<Unit>): CString
foreign func sqlite3_free(p: CPointer<Unit>): Unit

// ---- sqlite3 常量（https://www.sqlite.org/c3ref/c_abort.html）----
const SQLITE_OK: Int32 = 0
const SQLITE_ROW: Int32 = 100
const SQLITE_DONE: Int32 = 101
const SQLITE_OPEN_READWRITE: Int32 = 0x00000002
const SQLITE_OPEN_CREATE: Int32 = 0x00000004
const SQLITE_OPEN_READONLY: Int32 = 0x00000001
const SQLITE_OPEN_FULLMUTEX: Int32 = 0x00010000

// ---- 字符串搬运（文件私有）----

/// String → CString（mallocCString 一次拷贝）。用完必须 freeCString。
func cStringOf(s: String): CString {
    return unsafe { LibC.mallocCString(s) }
}

func freeCString(c: CString): Unit {
    unsafe { LibC.free(c) }
}

/// SQLITE_TRANSIENT 的指针值（(void(*)(void*))-1）。仓颉没有「整数 →
/// 指针」的直转，借 8 字节堆缓冲做一次位模式往返：写全 1 的 UInt64，
/// 再按指针读出来，就是值为 -1 的指针。
func sqliteTransientDtor(): CPointer<Unit> {
    let buf = unsafe { LibC.malloc<UInt64>(count: 8) }
    unsafe { buf.write(UInt64.Max) }
    let pp: CPointer<CPointer<Unit>> = CPointer(buf)
    let dtor: CPointer<Unit> = unsafe { pp.read() }
    unsafe { LibC.free(buf) }
    return dtor
}

// ---- 安全包装 ----

/// 已打开的单文件数据库连接。
///
/// 用法纪律：try/finally 里 close()；每条 prepare 出的语句用完
/// finalize()——close 撞上未 finalize 的语句会失败并 Log.warn
///（进程退出才会回收），写路径别依赖这个兜底。
public class SqliteDb {
    var handle: CPointer<Unit>

    /// 打开（READWRITE|CREATE|FULLMUTEX）。父目录必须已存在；
    /// 失败抛 DgError（附 sqlite3_errmsg 原因）。常规调用方请走
    /// open / openReadonly 工厂，免 try/catch。
    public init(path: String) {
        let c = cStringOf(path)
        let slot = unsafe { LibC.malloc<CPointer<Unit>>(count: 8) }
        let pp: CPointer<CPointer<Unit>> = CPointer(slot)
        unsafe { pp.write(CPointer<Unit>()) }
        let rc = unsafe {
            sqlite3_open_v2(c, pp,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                CPointer<Unit>())
        }
        freeCString(c)
        this.handle = unsafe { pp.read() }
        unsafe { LibC.free(slot) }
        if (rc != SQLITE_OK || this.handle.isNull()) {
            let why = if (this.handle.isNull()) {
                "sqlite3_open_v2 返回 ${rc} 且句柄为空"
            } else {
                let m = unsafe { sqlite3_errmsg(this.handle) }
                m.toString()
            }
            if (!this.handle.isNull()) {
                unsafe { sqlite3_close(this.handle) }
                this.handle = CPointer<Unit>()
            }
            throw DgError("SQLITE_OPEN_FAILED", "打开 SQLite 失败：${path}（${why}）")
        }
    }

    /// 打开工厂（READWRITE|CREATE|FULLMUTEX）：失败 Log.warn + None，
    /// 调用方无需 try/catch。
    public static func open(path: String): Option<SqliteDb> {
        try {
            return Some(SqliteDb(path))
        } catch (e: Exception) {
            Log.warn("sqlite 打开失败：${path}（${e.message}）")
            return None
        }
    }

    /// 只读打开工厂（READONLY|FULLMUTEX）：验证产物用——产出的库不依赖
    /// 写权限也应可读。失败 Log.warn + None。
    public static func openReadonly(path: String): Option<SqliteDb> {
        let c = cStringOf(path)
        let slot = unsafe { LibC.malloc<CPointer<Unit>>(count: 8) }
        let pp: CPointer<CPointer<Unit>> = CPointer(slot)
        unsafe { pp.write(CPointer<Unit>()) }
        let rc = unsafe {
            sqlite3_open_v2(c, pp, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
                CPointer<Unit>())
        }
        freeCString(c)
        let h = unsafe { pp.read() }
        unsafe { LibC.free(slot) }
        if (rc != SQLITE_OK || h.isNull()) {
            var why = "sqlite3_open_v2 返回 ${rc}"
            if (!h.isNull()) {
                let m = unsafe { sqlite3_errmsg(h) }
                why = m.toString()
                unsafe { sqlite3_close(h) }
            }
            Log.warn("sqlite 只读打开失败：${path}（${why}）")
            return None
        }
        let db = SqliteDb()
        db.handle = h
        return Some(db)
    }

    /// 测试专用空构造（句柄为 null；openReadonly 内部填充）。
    init() {
        this.handle = CPointer<Unit>()
    }

    public func isOpen(): Bool {
        return !this.handle.isNull()
    }

    /// 最近一次错误的 sqlite 侧原因。
    public func errmsg(): String {
        if (this.handle.isNull()) { return "" }
        let m = unsafe { sqlite3_errmsg(this.handle) }
        return m.toString()
    }

    /// 执行一段可含多条语句的 SQL（DDL / PRAGMA 用）。
    /// 失败 Log.warn（带 errmsg 与截断后的 sql）+ false。
    public func exec(sql: String): Bool {
        let c = cStringOf(sql)
        let slot = unsafe { LibC.malloc<CString>(count: 8) }
        let errSlot: CPointer<CString> = CPointer(slot)
        unsafe { errSlot.write(CString(CPointer<UInt8>())) }
        let rc = unsafe {
            sqlite3_exec(this.handle, c, CPointer<Unit>(), CPointer<Unit>(), errSlot)
        }
        freeCString(c)
        let ok = rc == SQLITE_OK
        if (!ok) {
            let msg = unsafe { errSlot.read() }
            let why = if (msg.isNull()) { "sqlite3_exec 返回 ${rc}" } else { msg.toString() }
            if (!msg.isNull()) {
                // errmsg 缓冲归 sqlite 分配，必须用 sqlite3_free 归还
                let freeP: CPointer<Unit> = CPointer(msg.getChars())
                unsafe { sqlite3_free(freeP) }
            }
            Log.warn("sqlite exec 失败：${why}（sql: ${truncateChars(sql, 120)}）")
        }
        unsafe { LibC.free(slot) }
        return ok
    }

    /// 预编译一条语句（';' 结尾的单条）。失败 Log.warn + None。
    public func prepare(sql: String): Option<SqliteStmt> {
        let c = cStringOf(sql)
        let slot = unsafe { LibC.malloc<CPointer<Unit>>(count: 8) }
        let pp: CPointer<CPointer<Unit>> = CPointer(slot)
        unsafe { pp.write(CPointer<Unit>()) }
        let rc = unsafe {
            sqlite3_prepare_v2(this.handle, c, -1, pp, CPointer<CPointer<Unit>>())
        }
        freeCString(c)
        let st = unsafe { pp.read() }
        unsafe { LibC.free(slot) }
        if (rc != SQLITE_OK || st.isNull()) {
            Log.warn("sqlite prepare 失败：${this.errmsg()}（sql: ${truncateChars(sql, 120)}）")
            return None
        }
        return Some(SqliteStmt(st, this.handle))
    }

    public func close(): Unit {
        if (!this.handle.isNull()) {
            let rc = unsafe { sqlite3_close(this.handle) }
            if (rc != SQLITE_OK) {
                // 最常见成因：还有语句未 finalize。绝不静默。
                Log.warn("sqlite close 未完成（rc=${rc}）：多半有语句未 finalize")
            }
            this.handle = CPointer<Unit>()
        }
    }
}

/// 一条已 prepare 的语句。必须 finalize；finalize 后再调用任何方法
/// 是编程错误（包装把句柄置空，sqlite 调用会拿到 null——宁可崩在
/// 调用点也不悄悄返回垃圾数据）。
public class SqliteStmt {
    var stmt: CPointer<Unit>
    let dbHandle: CPointer<Unit>   // 仅用于 errmsg

    init(stmt: CPointer<Unit>, dbHandle: CPointer<Unit>) {
        this.stmt = stmt
        this.dbHandle = dbHandle
    }

    /// 绑定 INTEGER（参数序号 1-based）。
    public func bindInt(idx: Int64, v: Int64): Bool {
        let rc = unsafe { sqlite3_bind_int64(this.stmt, Int32(idx), v) }
        if (rc != SQLITE_OK) {
            Log.warn("sqlite bind_int64(${idx}) 失败：${this.errmsgText()}")
            return false
        }
        return true
    }

    /// 绑定 TEXT（SQLITE_TRANSIENT：sqlite 立即拷贝，本函数返回后
    /// 临时 CString 即释放；n=-1 表示由 sqlite strlen）。
    public func bindText(idx: Int64, s: String): Bool {
        let transient = sqliteTransientDtor()
        let c = cStringOf(s)
        let rc = unsafe { sqlite3_bind_text(this.stmt, Int32(idx), c, -1, transient) }
        freeCString(c)
        if (rc != SQLITE_OK) {
            Log.warn("sqlite bind_text(${idx}) 失败：${this.errmsgText()}")
            return false
        }
        return true
    }

    /// step 一次：还有一行返回 true；DONE 或出错返回 false（出错已 Log.warn）。
    public func stepHasRow(): Bool {
        let rc = unsafe { sqlite3_step(this.stmt) }
        if (rc == SQLITE_ROW) { return true }
        if (rc != SQLITE_DONE) {
            Log.warn("sqlite step 失败（rc=${rc}）：${this.errmsgText()}")
        }
        return false
    }

    /// step 一次并要求 DONE（INSERT/UPDATE 场景）。
    public func stepFinish(): Bool {
        let rc = unsafe { sqlite3_step(this.stmt) }
        if (rc == SQLITE_DONE) { return true }
        Log.warn("sqlite step 失败（rc=${rc}）：${this.errmsgText()}")
        return false
    }

    /// 复位语句以备下一次执行（同一语句批量 INSERT 用）。
    public func reset(): Unit {
        unsafe { sqlite3_reset(this.stmt) }
    }

    public func columnInt(col: Int64): Int64 {
        return unsafe { sqlite3_column_int64(this.stmt, Int32(col)) }
    }

    /// 文本列；SQL NULL → ""。
    public func columnText(col: Int64): String {
        let p = unsafe { sqlite3_column_text(this.stmt, Int32(col)) }
        if (p.isNull()) { return "" }
        return CString(p).toString()
    }

    public func finalize(): Unit {
        if (!this.stmt.isNull()) {
            let rc = unsafe { sqlite3_finalize(this.stmt) }
            if (rc != SQLITE_OK) {
                Log.warn("sqlite finalize 失败（rc=${rc}）")
            }
            this.stmt = CPointer<Unit>()
        }
    }

    func errmsgText(): String {
        if (this.dbHandle.isNull()) { return "" }
        let m = unsafe { sqlite3_errmsg(this.dbHandle) }
        return m.toString()
    }
}
