// 手写 JSON 解析/序列化（零依赖）。对象保持插入顺序，保证状态文件稳定可 diff。
package moongit.util

import std.collection.*
import std.math.*
import std.math.numeric.*
import std.convert.*
import std.unittest.*
import std.unittest.testmacro.*

/// JsonValue 的数字只有 JNum(Float64) 一种形态，所有整数都经 Float64 中转。
/// Float64 能精确表示的整数上限是 2^53 —— 超出这个范围，数值在**写入那一刻**
/// 就已经失真且不可逆。所以序列化的整数分支必须限制在 2^53 内，
/// 超出则走浮点分支（原样输出），而不是硬转 Int64 崩掉。
private const MAX_SAFE_INT: Float64 = 9007199254740992.0  // 2^53
private const MIN_SAFE_INT: Float64 = -9007199254740992.0

public enum JsonValue {
    | JNull
    | JBool(Bool)
    | JNum(Float64)
    | JStr(String)
    | JArr(ArrayList<JsonValue>)
    | JObj(ArrayList<(String, JsonValue)>)
}

public class Json {
    // ------------------------------ 构造 ------------------------------
    public static func obj(): JsonValue {
        return JObj(ArrayList<(String, JsonValue)>())
    }

    public static func arr(): JsonValue {
        return JArr(ArrayList<JsonValue>())
    }

    public static func of(v: Bool): JsonValue {
        return JBool(v)
    }

    public static func of(v: Int64): JsonValue {
        return JNum(Float64(v))
    }

    public static func of(v: Float64): JsonValue {
        return JNum(v)
    }

    public static func of(v: String): JsonValue {
        return JStr(v)
    }

    public static func null(): JsonValue {
        return JNull
    }

    public static func strArray(items: Array<String>): JsonValue {
        let a = ArrayList<JsonValue>()
        for (s in items) {
            a.add(JStr(s))
        }
        return JArr(a)
    }

    // ------------------------------ 读写 ------------------------------
    public static func set(o: JsonValue, key: String, value: JsonValue): Unit {
        match (o) {
            case JObj(m) =>
                var found = false
                for (i in 0..m.size) {
                    let (k, _) = m[i]
                    if (k == key) {
                        m[i] = (key, value)
                        found = true
                        break
                    }
                }
                if (!found) {
                    m.add((key, value))
                }
            case _ => ()
        }
    }

    public static func get(o: JsonValue, key: String): Option<JsonValue> {
        match (o) {
            case JObj(m) =>
                for ((k, v) in m) {
                    if (k == key) {
                        return Some(v)
                    }
                }
                return None
            case _ => return None
        }
    }

    /// 取字段，缺失时返回 JNull（避免 Option 解包噪音）
    public static func getOr(o: JsonValue, key: String): JsonValue {
        match (get(o, key)) {
            case Some(v) => return v
            case None => return JNull
        }
    }

    public static func has(o: JsonValue, key: String): Bool {
        return get(o, key).isSome()
    }

    public static func remove(o: JsonValue, key: String): Unit {
        match (o) {
            case JObj(m) =>
                var i = 0
                while (i < m.size) {
                    let (k, _) = m[i]
                    if (k == key) {
                        m.remove(at: i)
                    } else {
                        i += 1
                    }
                }
            case _ => ()
        }
    }

    public static func add(a: JsonValue, v: JsonValue): Unit {
        match (a) {
            case JArr(items) => items.add(v)
            case _ => ()
        }
    }

    // ------------------------------ 访问 ------------------------------
    public static func asStr(v: JsonValue): Option<String> {
        match (v) {
            case JStr(s) => return Some(s)
            case _ => return None
        }
    }

    public static func asNum(v: JsonValue): Option<Float64> {
        match (v) {
            case JNum(n) => return Some(n)
            case JBool(b) => return Some(if (b) { 1.0 } else { 0.0 })
            case _ => return None
        }
    }

    public static func asInt(v: JsonValue): Option<Int64> {
        match (asNum(v)) {
            case Some(n) =>
                // 必须先判范围：`Int64(n)` 在 |n| >= 2^63 时抛异常，
                // 而 intAt 声明了 fallback 参数、语义是「取不到就返回 fallback」。
                // 旧实现直接抛，fallback 保护形同虚设 —— 实测 `intAt(1e30)` 崩。
                if (n.isNaN() || n.isInf() || n < MIN_SAFE_INT || n > MAX_SAFE_INT) {
                    return None
                }
                try {
                    return Some(Int64(n))
                } catch (e: Exception) {
                    return None
                }
            case None => return None
        }
    }

    public static func asBool(v: JsonValue): Option<Bool> {
        match (v) {
            case JBool(b) => return Some(b)
            case _ => return None
        }
    }

    public static func asArr(v: JsonValue): Option<ArrayList<JsonValue>> {
        match (v) {
            case JArr(a) => return Some(a)
            case _ => return None
        }
    }

    public static func asObj(v: JsonValue): Option<ArrayList<(String, JsonValue)>> {
        match (v) {
            case JObj(m) => return Some(m)
            case _ => return None
        }
    }

    public static func isNull(v: JsonValue): Bool {
        match (v) {
            case JNull => return true
            case _ => return false
        }
    }

    /// 取字符串字段，缺省返回 fallback
    public static func strAt(o: JsonValue, key: String, fallback: String): String {
        match (get(o, key)) {
            case Some(v) => match (asStr(v)) {
                case Some(s) => return s
                case None => return fallback
            }
            case None => return fallback
        }
    }

    public static func strAtOpt(o: JsonValue, key: String): Option<String> {
        match (get(o, key)) {
            case Some(v) => return asStr(v)
            case None => return None
        }
    }

    public static func intAt(o: JsonValue, key: String, fallback: Int64): Int64 {
        match (get(o, key)) {
            case Some(v) => match (asInt(v)) {
                case Some(n) => return n
                case None => return fallback
            }
            case None => return fallback
        }
    }

    public static func numAt(o: JsonValue, key: String, fallback: Float64): Float64 {
        match (get(o, key)) {
            case Some(v) => match (asNum(v)) {
                case Some(n) => return n
                case None => return fallback
            }
            case None => return fallback
        }
    }

    public static func boolAt(o: JsonValue, key: String, fallback: Bool): Bool {
        match (get(o, key)) {
            case Some(v) => match (asBool(v)) {
                case Some(b) => return b
                case None => return fallback
            }
            case None => return fallback
        }
    }

    public static func arrAt(o: JsonValue, key: String): ArrayList<JsonValue> {
        match (get(o, key)) {
            case Some(v) => match (asArr(v)) {
                case Some(a) => return a
                case None => return ArrayList<JsonValue>()
            }
            case None => return ArrayList<JsonValue>()
        }
    }

    public static func strArrAt(o: JsonValue, key: String): ArrayList<String> {
        let out = ArrayList<String>()
        for (v in arrAt(o, key)) {
            match (asStr(v)) {
                case Some(s) => out.add(s)
                case None => ()
            }
        }
        return out
    }

    // ------------------------------ 序列化 ------------------------------
    public static func compact(v: JsonValue): String {
        let sb = StringBuilder()
        writeValue(v, sb, 0, false)
        return sb.toString()
    }

    public static func pretty(v: JsonValue): String {
        let sb = StringBuilder()
        writeValue(v, sb, 0, true)
        return sb.toString()
    }

    static func writeValue(v: JsonValue, sb: StringBuilder, level: Int64, indent: Bool): Unit {
        match (v) {
            case JNull => sb.append("null")
            case JBool(b) => sb.append(if (b) { "true" } else { "false" })
            case JNum(n) =>
                if (n.isNaN() || n.isInf()) {
                    sb.append("null")
                } else if (n == floor(n) && n >= MIN_SAFE_INT && n <= MAX_SAFE_INT) {
                    // ⚠️ 判据里绝不能出现 `Int64(n)` 这个转换本身。
                    // 旧写法 `n == Float64(Int64(n))` 在 |n| >= 2^63 时
                    // **在条件表达式里就抛异常**（"The result would be greater
                    // than Int64.Max"），实测 1e19 / -1e19 / 1e21 全部崩，
                    // 连 compact 都返回不了。而 2^53 以内的整数经 Float64
                    // 中转是精确的（JsonValue 只有 JNum(Float64) 一种数字形态），
                    // 所以这个范围既安全又无损。
                    sb.append("${Int64(n)}")
                } else {
                    sb.append(formatJsonFloat(n))
                }
            case JStr(s) => writeString(s, sb)
            case JArr(items) =>
                if (items.isEmpty()) {
                    sb.append("[]")
                    return
                }
                sb.append("[")
                for (i in 0..items.size) {
                    if (i > 0) {
                        sb.append(",")
                    }
                    if (indent) {
                        sb.append("\n")
                        appendIndent(sb, level + 1)
                    }
                    writeValue(items[i], sb, level + 1, indent)
                }
                if (indent) {
                    sb.append("\n")
                    appendIndent(sb, level)
                }
                sb.append("]")
            case JObj(m) =>
                if (m.isEmpty()) {
                    sb.append("{}")
                    return
                }
                sb.append("{")
                for (i in 0..m.size) {
                    if (i > 0) {
                        sb.append(",")
                    }
                    if (indent) {
                        sb.append("\n")
                        appendIndent(sb, level + 1)
                    }
                    let (k, val) = m[i]
                    writeString(k, sb)
                    sb.append(if (indent) { ": " } else { ":" })
                    writeValue(val, sb, level + 1, indent)
                }
                if (indent) {
                    sb.append("\n")
                    appendIndent(sb, level)
                }
                sb.append("}")
        }
    }

    static func appendIndent(sb: StringBuilder, level: Int64): Unit {
        for (_ in 0..(level * 2)) {
            sb.append(" ")
        }
    }

    static func writeString(s: String, sb: StringBuilder): Unit {
        sb.append("\"")
        for (r in s.runes()) {
            let cp = UInt32(r)
            if (cp == 0x22u32) {
                sb.append("\\\"")
            } else if (cp == 0x5cu32) {
                sb.append("\\\\")
            } else if (cp == 0x0au32) {
                sb.append("\\n")
            } else if (cp == 0x0du32) {
                sb.append("\\r")
            } else if (cp == 0x09u32) {
                sb.append("\\t")
            } else if (cp == 0x08u32) {
                sb.append("\\b")
            } else if (cp == 0x0cu32) {
                sb.append("\\f")
            } else if (cp < 0x20u32) {
                sb.append("\\u")
                sb.append(hex4(cp))
            } else {
                sb.append(r.toString())
            }
        }
        sb.append("\"")
    }

    /// JSON 的 \u 转义**必须正好 4 位十六进制**。
    ///
    /// 这里原来叫 hex4 但只产出 2 位：0x1e 被写成 `\u1e` 而不是 `\u001e`，
    /// 这是非法 JSON —— Python 的 json、Swift 的 JSONDecoder、任何符合规范的解析器
    /// 都会直接拒绝。实测触发路径：提交标题里含 0x1e/0x1f 控制字符时，
    /// 引擎写出的 progress.json 整份不可解析，项目的进度历史就此报废。
    static func hex4(cp: UInt32): String {
        let chars = "0123456789abcdef"
        let a = Int64((cp >> 12) & 0xfu32)
        let b = Int64((cp >> 8) & 0xfu32)
        let c = Int64((cp >> 4) & 0xfu32)
        let d = Int64(cp & 0xfu32)
        return chars[a..a + 1] + chars[b..b + 1] + chars[c..c + 1] + chars[d..d + 1]
    }

    // ------------------------------ 解析 ------------------------------
    /// 解析 JSON。**契约：要么返回 Some，要么返回 None，绝不抛异常。**
    ///
    /// 这条契约以前没有兑现，两处直接抛异常穿透所有 `match (Json.parse(..))` 调用方：
    ///   1) `\uD83D\uDE00`（emoji 的标准代理对写法）→ Rune(0xD83D) 抛
    ///      "not a valid Unicode scalar value"。实测一个表情就能杀掉 MCP 进程：
    ///      `echo '{"jsonrpc":"2.0",...,"note":"😀"}' | moongit mcp` → EXIT=1。
    ///      而 Python MCP 客户端的 `json.dumps` 默认 `ensure_ascii=True`，
    ///      **必然**产出代理对转义 —— 触发面是日常操作而非边缘情况。
    ///   2) 整数溢出（`intAt(1e30)`）→ `Int64(n)` 抛，连 fallback 保护都失效。
    ///
    /// 代理对已在 `string()` 里正确合并（见那里），但外层这层 try/catch 是
    /// 契约本身的兑现点：解析器里任何一处未来引入的抛异常，都只会被降级为
    /// 「这个输入解析失败」，而不是杀死 serve / mcp 进程。
    public static func parse(input: String): Option<JsonValue> {
        try {
            let bytes = input.toArray()
            // 跳过 UTF-8 BOM：Windows 工具链产出的 JSON 常带 EF BB BF，
            // 不跳过就直接解析失败（Python json 同样拒绝，但引擎的输入源
            // 包含用户用记事本改过的状态文件）。
            var start: Int64 = 0
            if (bytes.size >= 3 && bytes[0] == 0xefu8 && bytes[1] == 0xbbu8 && bytes[2] == 0xbfu8) {
                start = 3
            }
            let p = JsonParser(bytes, start)
            p.skipWs()
            match (p.value()) {
                case Some(v) =>
                    p.skipWs()
                    if (p.pos != bytes.size) {
                        return None
                    }
                    return Some(v)
                case None => return None
            }
        } catch (e: Exception) {
            return None
        } catch (e: Error) {
            // Error 不是 Exception 的子类（StackOverflowError 等走这一支）。
            // 有了深度上限这类情况本不该再发生，但兜住它成本为零，
            // 而漏掉它的代价是整个 serve / mcp 进程裸崩。
            return None
        }
    }
}

/// 嵌套深度上限。JSON 规范本身不限，但**解析器在栈上递归**：
/// 无限深度的输入会触发 StackOverflowError，而 Cangjie 的 `Error` 不是
/// `Exception` —— main.cj 的 `catch (e: Exception)` 兜不住它，
/// 整个 serve / mcp 进程裸崩（无清理、无日志）。
/// 实测阈值在 800~1000 之间；一条 100KB 的 MCP 请求就能构造 1 万层嵌套，
/// `http.cj` 的 1MB body 上限完全不构成缓解。
/// 512 远高于任何真实文档的嵌套深度，误伤概率为零。
private const MAX_DEPTH: Int64 = 512


class JsonParser {
    let b: Array<UInt8>
    var pos: Int64
    var depth: Int64

    init(b: Array<UInt8>, pos: Int64) {
        this.b = b
        this.pos = pos
        this.depth = 0
    }

    func peek(): Option<UInt8> {
        if (this.pos < this.b.size) {
            return Some(this.b[this.pos])
        }
        return None
    }

    func bump(): Option<UInt8> {
        let c = this.peek()
        match (c) {
            case Some(_) => this.pos += 1
            case None => ()
        }
        return c
    }

    func skipWs(): Unit {
        while (true) {
            match (this.peek()) {
                case Some(c) =>
                    if (c == 0x20u8 || c == 0x09u8 || c == 0x0au8 || c == 0x0du8) {
                        this.pos += 1
                    } else {
                        break
                    }
                case None => break
            }
        }
    }

    func value(): Option<JsonValue> {
        this.skipWs()
        match (this.peek()) {
            case Some(c) =>
                if (c == 0x7bu8) {
                    this.depth += 1
                    if (this.depth > MAX_DEPTH) { return None }
                    let r = this.object()
                    this.depth -= 1
                    return r
                } else if (c == 0x5bu8) {
                    this.depth += 1
                    if (this.depth > MAX_DEPTH) { return None }
                    let r = this.array()
                    this.depth -= 1
                    return r
                } else if (c == 0x22u8) {
                    match (this.string()) {
                        case Some(s) => return Some(JStr(s))
                        case None => return None
                    }
                } else if (c == 0x74u8) {
                    return if (this.lit("true")) { Some(JBool(true)) } else { None }
                } else if (c == 0x66u8) {
                    return if (this.lit("false")) { Some(JBool(false)) } else { None }
                } else if (c == 0x6eu8) {
                    return if (this.lit("null")) { Some(JNull) } else { None }
                } else if (c == 0x2du8 || (c >= 0x30u8 && c <= 0x39u8)) {
                    return this.number()
                } else {
                    return None
                }
            case None => return None
        }
    }

    func lit(s: String): Bool {
        let target = s.toArray()
        if (this.pos + target.size > this.b.size) {
            return false
        }
        for (i in 0..target.size) {
            if (this.b[this.pos + i] != target[i]) {
                return false
            }
        }
        this.pos += target.size
        return true
    }

    func object(): Option<JsonValue> {
        this.bump()  // {
        let m = ArrayList<(String, JsonValue)>()
        this.skipWs()
        match (this.peek()) {
            case Some(c) =>
                if (c == 0x7du8) {
                    this.bump()
                    return Some(JObj(m))
                } else if (c == 0x22u8) {
                    // 空对象以外的情况继续
                } else {
                    return None
                }
            case None => return None
        }
        while (true) {
            this.skipWs()
            match (this.string()) {
                case Some(key) =>
                    this.skipWs()
                    match (this.bump()) {
                        case Some(c) =>
                            if (c != 0x3au8) {
                                return None
                            }
                        case None => return None
                    }
                    match (this.value()) {
                        case Some(v) =>
                            // ⚠️ 重复键必须**就地替换**，不能直接 add。
                            //
                            // JObj 是 pair 列表，直接 add 会让重复键留在表示里：
                            //   · 查找从头扫 ⇒ first-wins，而 Python / JS / Go /
                            //     Rust 全部是 last-wins —— 同一个文件，
                            //     moonGit 读到 a=1、别的工具读到 a=2
                            //   · 更糟的是 Json.compact 会把重复键**原样写回**
                            //     （实测 {"a":1,"a":2} 往返后仍是两个 a），
                            //     于是歧义被引擎亲手持久化下来
                            //
                            // 就地替换（保持首次出现的位置，顺序不变）同时解决两者：
                            // 读出来是 last-wins，存回去只剩一个键。
                            //
                            // 这里**不报错**：主流解析器都接受这个文件，
                            // moonGit 若独独拒绝，就成了唯一读不出的那个工具。
                            // 真正要消除的是「读法不一致」，而不是文件本身。
                            var replaced = false
                            for (i in 0..m.size) {
                                if (m[i][0] == key) {
                                    m[i] = (key, v)
                                    replaced = true
                                    break
                                }
                            }
                            if (!replaced) {
                                m.add((key, v))
                            }
                        case None => return None
                    }
                    this.skipWs()
                    match (this.bump()) {
                        case Some(c) =>
                            if (c == 0x2cu8) {
                                continue
                            } else if (c == 0x7du8) {
                                break
                            } else {
                                return None
                            }
                        case None => return None
                    }
                case None => return None
            }
        }
        return Some(JObj(m))
    }

    func array(): Option<JsonValue> {
        this.bump()  // [
        let a = ArrayList<JsonValue>()
        this.skipWs()
        match (this.peek()) {
            case Some(c) =>
                if (c == 0x5du8) {
                    this.bump()
                    return Some(JArr(a))
                }
            case None => ()
        }
        while (true) {
            match (this.value()) {
                case Some(v) => a.add(v)
                case None => return None
            }
            this.skipWs()
            match (this.bump()) {
                case Some(c) =>
                    if (c == 0x2cu8) {
                        continue
                    } else if (c == 0x5du8) {
                        break
                    } else {
                        return None
                    }
                case None => return None
            }
        }
        return Some(JArr(a))
    }

    func string(): Option<String> {
        match (this.bump()) {
            case Some(c) =>
                if (c != 0x22u8) {
                    return None
                }
            case None => return None
        }
        let sb = StringBuilder()
        var done = false
        while (!done) {
            match (this.bump()) {
                case Some(c) =>
                    if (c == 0x22u8) {
                        return Some(sb.toString())
                    } else if (c == 0x5cu8) {
                        match (this.bump()) {
                            case Some(e) =>
                                match (e) {
                                    case 0x22u8 => sb.append("\"")
                                    case 0x5cu8 => sb.append("\\")
                                    case 0x2fu8 => sb.append("/")
                                    case 0x62u8 => sb.append("\u{8}")
                                    case 0x66u8 => sb.append("\u{c}")
                                    case 0x6eu8 => sb.append("\n")
                                    case 0x72u8 => sb.append("\r")
                                    case 0x74u8 => sb.append("\t")
                                    case 0x75u8 =>
                                        match (this.hex4()) {
                                            case Some(cp) =>
                                                // UTF-16 代理对必须合并成一个码点。
                                                // `\uD83D\uDE00` 是 JSON 表示 emoji（😀）的
                                                // **标准写法**，Python 的 json.dumps 默认就产出它。
                                                // 旧实现把 0xD83D 直接交给 Rune()，抛
                                                // "not a valid Unicode scalar value"，
                                                // 一个表情就能杀掉 MCP / HTTP 进程。
                                                if (cp >= 0xd800u32 && cp <= 0xdbffu32) {
                                                    // 高位代理：必须紧跟一个 \uDC00-\uDFFF 的低位代理
                                                    if (this.peek() == Some(0x5cu8)) {
                                                        let save = this.pos
                                                        this.bump()
                                                        if (this.peek() == Some(0x75u8)) {
                                                            this.bump()
                                                            match (this.hex4()) {
                                                                case Some(lo) =>
                                                                    if (lo >= 0xdc00u32 && lo <= 0xdfffu32) {
                                                                        sb.append(Rune(0x10000u32 + ((cp - 0xd800u32) << 10) + (lo - 0xdc00u32)).toString())
                                                                    } else {
                                                                        // 不是合法低位代理：按 WHATWG 规范，
                                                                        // 高位代理替换为 U+FFFD，低位按普通码点处理
                                                                        sb.append("\u{fffd}")
                                                                        if (lo >= 0xd800u32 && lo <= 0xdfffu32) {
                                                                            sb.append("\u{fffd}")
                                                                        } else {
                                                                            sb.append(Rune(lo).toString())
                                                                        }
                                                                    }
                                                                case None =>
                                                                    this.pos = save
                                                                    sb.append("\u{fffd}")
                                                            }
                                                        } else {
                                                            this.pos = save
                                                            sb.append("\u{fffd}")
                                                        }
                                                    } else {
                                                        sb.append("\u{fffd}")
                                                    }
                                                } else if (cp >= 0xdc00u32 && cp <= 0xdfffu32) {
                                                    // 孤立低位代理
                                                    sb.append("\u{fffd}")
                                                } else {
                                                    sb.append(Rune(cp).toString())
                                                }
                                            case None => return None
                                        }
                                    case _ => return None
                                }
                            case None => return None
                        }
                    } else if (c < 0x20u8) {
                        return None
                    } else if (c < 0x80u8) {
                        sb.append(Rune(UInt32(c)).toString())
                    } else {
                        // UTF-8 多字节：回退一个字节，按 (bytes, offset) 解码。
                        // ⚠️ 不要把剩下的数组切片传下去（M22）：runeFromUtf8 最多
                        // 只读前 4 字节，而 `this.b[this.pos..]` 会为**每一个**
                        // 多字节字符拷贝整个剩余数组 ⇒ 中文密集文档是 O(n²)。
                        // 这条路径是全引擎热路径（每个 MCP 消息、每次读状态文件），
                        // 500KB 级内容实测会退化成数十 GB 的内存流量。
                        this.pos -= 1
                        match (runeFromUtf8At(this.b, this.pos)) {
                            case Some(pair) =>
                                let (r, size) = pair
                                sb.append(r.toString())
                                this.pos += size
                            case None => return None
                        }
                    }
                case None =>
                    done = true
            }
        }
        return None
    }

    func hex4(): Option<UInt32> {
        var v: UInt32 = 0
        for (_ in 0..4) {
            match (this.bump()) {
                case Some(c) =>
                    var d: UInt32
                    if (c >= 0x30u8 && c <= 0x39u8) {
                        d = UInt32(c - 0x30u8)
                    } else if (c >= 0x61u8 && c <= 0x66u8) {
                        d = UInt32(c - 0x61u8 + 10u8)
                    } else if (c >= 0x41u8 && c <= 0x46u8) {
                        d = UInt32(c - 0x41u8 + 10u8)
                    } else {
                        return None
                    }
                    v = v * 16u32 + d
                case None => return None
            }
        }
        return Some(v)
    }

    /// 严格按 RFC 8259 的 number 文法解析：
    ///     -?  ( 0 | [1-9][0-9]* )  ( \. [0-9]+ )?  ( [eE] [+-]? [0-9]+ )?
    ///
    /// 原实现是「负号可选 + 数字随便吃 + 小数点可选 + 小数随便吃」，
    /// 剩下的全交给 `Float64.parse` 兜底，而后者**不抛**的几种输入
    /// 实测都被静默改写成了另一个数：
    ///     `-`    → 0        裸负号，一个数字都没有
    ///     `01`   → 1        JSON 禁止前导零
    ///     `00.5` → 0.5      同上
    ///     `1.`   → 1        小数点后必须有数字
    /// 而 `1e999` 更糟：解析成 Infinity，`Json.of` 把它渲染成 **null** ——
    /// 用户写的是数字，引擎存回去的是 null，任何下游读到的都是 null。
    /// 这和序列化侧那个 `1e308 → null` 是同一族（#139），修在了解析侧。
    ///
    /// 方向：**宁可拒绝**。把非法字面量猜成一个合法数字，比报错难查得多 ——
    /// 报错至少会说「第 N 行这里不合法」，猜出来的值则一路带着走下去。
    func number(): Option<JsonValue> {
        let start = this.pos
        if (this.peek() == Some(0x2du8)) {
            this.bump()
        }
        // 整数部分：0 或 [1-9][0-9]*
        match (this.peek()) {
            case Some(c) =>
                if (c == 0x30u8) {
                    this.bump()
                    // 前导零：`0` 后面必须不是数字
                    match (this.peek()) {
                        case Some(c2) =>
                            if (c2 >= 0x30u8 && c2 <= 0x39u8) {
                                return None
                            }
                        case None => ()
                    }
                } else if (c >= 0x31u8 && c <= 0x39u8) {
                    while (this.isDigit()) {
                        this.pos += 1
                    }
                } else {
                    // 包括裸 `-`、`.`、`e` —— 原实现到这里会交给 Float64.parse
                    return None
                }
            case None => return None
        }
        // 小数部分：. 之后必须至少一个数字
        if (this.peek() == Some(0x2eu8)) {
            this.bump()
            if (!this.isDigit()) {
                return None
            }
            while (this.isDigit()) {
                this.pos += 1
            }
        }
        // 指数：e 之后必须至少一个数字
        match (this.peek()) {
            case Some(c) =>
                if (c == 0x65u8 || c == 0x45u8) {
                    this.bump()
                    match (this.peek()) {
                        case Some(s) =>
                            if (s == 0x2bu8 || s == 0x2du8) {
                                this.bump()
                            }
                        case None => ()
                    }
                    if (!this.isDigit()) {
                        return None
                    }
                    while (this.isDigit()) {
                        this.pos += 1
                    }
                }
            case None => ()
        }
        let s = String.fromUtf8(this.b[start..this.pos])
        match (parseFloatOpt(s)) {
            case Some(n) =>
                // 溢出/溢出下溢都要拒。Infinity 存下去会变成 null，
                // 那就是把「超出范围」说成「没有值」。
                if (n.isNaN() || n.isInf()) {
                    return None
                }
                return Some(JNum(n))
            case None => return None
        }
    }

    func isDigit(): Bool {
        match (this.peek()) {
            case Some(c) => return c >= 0x30u8 && c <= 0x39u8
            case None => return false
        }
    }
}

/// 从 UTF-8 字节序列解出一个 Rune（返回 rune 与消耗字节数）
func runeFromUtf8(b: Array<UInt8>): Option<(Rune, Int64)> {
    return runeFromUtf8At(b, 0)
}

/// L13：判断一个码点是否落在 UTF-8 规范禁止的代理区。
/// UTF-8 里 D800..DFFF 必须编码为 3 字节且 CESU-8 之外的实现都不接受，
/// 解码出这种码点等于把一个非法序列「洗白」成真字符。
func isValidUtf8Cp(cp: UInt32): Bool {
    if (cp >= 0xd800u32 && cp <= 0xdfffu32) {
        return false
    }
    return true
}

/// 从 b 的 offset 处解出一个 Rune。**零拷贝**：最多只读 4 字节，
/// 不为剩下的数组分配副本（见 string() 里那条 M22 注释）。
///
/// L13：顺带把校验口径对齐规范 —— 原实现对 0xC0/0xC1 开头的 overlong 二字节
/// 序列照单全收（c0 >= 0xc0 即判合法），而对 E0/F0 开头的 overlong 三/四字节
/// 序列也没有最小性检查（E0 80 80 会被解成 U+0000）。同一文件里的
/// fromUtf8Lossy 又是另一套口径。这里统一：拒 overlong、拒代理区。
func runeFromUtf8At(b: Array<UInt8>, offset: Int64): Option<(Rune, Int64)> {
    let avail = Int64(b.size) - offset
    if (avail <= 0) {
        return None
    }
    let c0 = b[offset]
    if (c0 < 0x80u8) {
        return Some((Rune(UInt32(c0)), 1))
    }
    var need: Int64 = 0
    var cp: UInt32 = 0
    if (c0 >= 0xc2u8 && c0 < 0xe0u8) {
        need = 2
        cp = UInt32(c0 & 0x1fu8)
    } else if (c0 >= 0xe0u8 && c0 < 0xf0u8) {
        need = 3
        cp = UInt32(c0 & 0x0fu8)
    } else if (c0 >= 0xf0u8 && c0 < 0xf5u8) {
        need = 4
        cp = UInt32(c0 & 0x07u8)
    } else {
        return None       // 0xC0/0xC1 overlong、0xF5+ 越界、续字节开头
    }
    if (avail < need) {
        return None
    }
    // overlong 最小性检查（必须在 avail 判定之后：要读第二个字节）
    if (c0 == 0xe0u8 && b[offset + 1] < 0xa0u8) {
        return None       // E0 80..9F = overlong（二字节就能表示）
    }
    if (c0 == 0xf0u8 && b[offset + 1] < 0x90u8) {
        return None       // F0 80..8F = overlong（三字节就能表示）
    }
    for (i in 1..need) {
        let c = b[offset + i]
        if (c < 0x80u8 || c >= 0xc0u8) {
            return None
        }
        cp = (cp << 6) | UInt32(c & 0x3fu8)
    }
    if (!isValidUtf8Cp(cp)) {
        return None
    }
    return Some((Rune(cp), need))
}

func parseFloatOpt(s: String): Option<Float64> {
    try {
        return Some(Float64.parse(s))
    } catch (e: Exception) {
        return None
    }
}

@Test
func testNumberGrammarIsStrictNotSilentlyCoerced(): Unit {
    // 原实现的 number 文法是「负号可选 + 数字随便吃 + 小数点可选」，
    // 剩下的交给 Float64.parse 兜底 —— 而它对下面几种输入**不抛**，
    // 于是非法字面量被静默改写成另一个数：
    //     `-`    → 0       裸负号，一个数字都没有
    //     `01`   → 1       JSON 禁止前导零
    //     `00.5` → 0.5     同上
    //     `1.`   → 1       小数点后必须有数字
    // 而 `1e999` 最糟：解析成 Infinity，渲染成 **null** ——
    // 用户写的是数字，引擎存回去的是 null。和序列化侧那个 `1e308 → null`
    // 是同一族（#139），修在了解析侧。
    //
    // 方向：宁可拒绝。把非法字面量猜成一个合法数字，比报错难查得多。
    for (bad in ["-", "01", "00", "00.5", "1.", "-01", "1e", "1e+", ".5", "+1", "1.2.3", "1e999", "-1e999"]) {
        @Assert(Json.parse(bad).isNone())
    }
    // 合法值一个都不能误伤（含边界：0 / 负零 / 指数各种写法）
    for (ok in ["0", "-0", "1", "-1", "10", "0.5", "-0.5", "1.25", "1e5", "1E5", "1e+5", "1e-5", "-1.5e-3", "3.14159265358979"]) {
        @Assert(Json.parse(ok).isSome())
    }
    // 往返：合法值解析出来必须还是它
    match (Json.parse("-0.5")) {
        case Some(v) => @Assert(Json.compact(v) == "-0.5")
        case None => @Assert(false)
    }
    // 容器里的非法数字必须让**整个文档**失败，不能只把那个字段丢掉
    @Assert(Json.parse("{\"a\":1}").isSome())
    @Assert(Json.parse("{\"a\":01}").isNone())
    @Assert(Json.parse("{\"a\":1e999}").isNone())
    @Assert(Json.parse("[1,2,-]").isNone())
}

@Test
func testDuplicateKeysResolveLastWinsAndDoNotSurviveRoundTrip(): Unit {
    // JObj 是 pair 列表，原实现对重复键直接 add，于是：
    //   · 查找从头扫 ⇒ first-wins。实测 {"a":1,"a":2} 读到 a=1，
    //     而 Python / JS / Go / Rust 全部是 last-wins（读到 2）。
    //     同一个文件 moonGit 和别的工具给出不同答案，这类不一致最难查。
    //   · 更糟：Json.compact 把重复键**原样写回**，往返后仍是两个 a ——
    //     引擎亲手把歧义持久化进了用户的 config.json / progress.json。
    let v = match (Json.parse("{\"a\":1,\"a\":2,\"b\":9}")) {
        case Some(x) => x
        case None =>
            @Assert(false)
            return
    }
    // 必须 last-wins，和主流解析器一致
    @Assert(Json.intAt(v, "a", -1) == 2)
    @Assert(Json.intAt(v, "b", -1) == 9)
    // 往返之后必须只剩一个键：歧义要被**消除**，不能被保留
    let round = Json.compact(v)
    @Assert(round == "{\"a\":2,\"b\":9}")
    @Assert(!round.contains("\"a\":1"))

    // 嵌套对象同样要 last-wins，且不能把外层的替换吃掉内层的
    let n = match (Json.parse("{\"a\":{\"x\":1},\"a\":{\"y\":2}}")) {
        case Some(x) => x
        case None =>
            @Assert(false)
            return
    }
    // has/numAt 都只做顶层查找，所以要先把 a 那个子对象取出来
    let inner = Json.getOr(n, "a")
    @Assert(!Json.has(inner, "x"))   // 第一个 a 被整体替换掉
    @Assert(Json.has(inner, "y"))    // 第二个 a 生效
    @Assert(Json.compact(n) == "{\"a\":{\"y\":2}}")

    // 三个重复键也要收敛成一个
    let t = match (Json.parse("{\"k\":1,\"k\":2,\"k\":3}")) {
        case Some(x) => x
        case None =>
            @Assert(false)
            return
    }
    @Assert(Json.compact(t) == "{\"k\":3}")
}

/// Float64 往返所需的最大有效数字位数。
///
/// 17 是 IEEE754 双精度的保证值：任何 double 都能被 17 位有效十进制数字唯一确定。
/// ⚠️ **不能超过它**：仓颉的 `Float64.parse` 只在前 ~17 位内正确舍入，
/// 实测把 1e308 的 309 位精确展开再解析回来，得到的是**另一个** double：
///   parse("1e308") != parse("<309 位精确展开>")
/// 所以「写精确展开」这种直觉修法在这里是错的 —— 它不但没修好，
/// 还把一个稳定的 double 换成了一个漂移的。
private const MAX_SIGNIFICANT_DIGITS: Int64 = 17

/// 科学计数法的切换阈值。沿用主流 JSON 序列化器的惯例：
/// 小于 1e-6 或大于等于 1e21 用指数形式，中间用普通十进制。
/// 两种形式都是合法 JSON，但指数形式能保证送进解析器的有效数字不超过 17 位。
private const SCI_LOW_EXP: Int64 = -6
private const SCI_HIGH_EXP: Int64 = 21

/// 把非整数 Float64 写成**能精确往返**的 JSON 数字字面量。
///
/// ⚠️ 绝不能写 `sb.append("${n}")`。仓颉 `Float64` 的 ToString 是**定点 6 位小数、
/// 不带指数**，实测：
///   0.85                    → 0.850000
///   3.14159265358979        → 3.141593        精度被舍掉
///   0.0000004               → 0.000000        值被**抹成 0**
///   1e-7                    → 0.000000        值被**抹成 0**
///   2.2250738585072014e-308 → 0.000000        值被**抹成 0**
///   1.0/3.0                 → 0.333333
///   1e308                   → 309 位定点数
///
/// 后果不是「显示难看」，而是**静默销毁用户写进 config.json 的数值**：
/// 那个文件是 ~/.deepgit 下用户与客户端共享的可编辑文件，saveConfig 会整份
/// parse → merge → 重写，于是一次 `config set` 就能把 0.0000004 变成 0，
/// 而 1e308 甚至在**第二次**写入时变成 null —— 用户全程没碰过它。
///
/// 做法：先用 Decimal 拿到精确的十进制展开（Float64 是二进制小数，
/// 精确展开必然有限），再从 1 位有效数字起逐位截短，取第一个能被
/// `Float64.parse` 解析回**同一个值**的候选。搜索上界是
/// MAX_SIGNIFICANT_DIGITS：再长解析器就开始丢精度了，那里「能往返」是假的。
private func formatJsonFloat(n: Float64): String {
    let exact = Decimal(n).toString()
    var neg = false
    var body = exact
    if (body.startsWith("-")) {
        neg = true
        body = body[1..]
    }
    var intPart = body
    var fracPart = ""
    match (body.indexOf(".")) {
        case Some(i) =>
            intPart = body[..i]
            fracPart = body[i + 1..]
        case None => ()
    }
    let all = intPart + fracPart
    var lead: Int64 = 0
    while (lead + 1 < all.size && all[lead] == 0x30u8) {
        lead += 1
    }
    let digits = all[lead..]
    // pointPos = 小数点左侧的位数；e = 十进制指数（值 = d1.d2d3… × 10^e）
    let pointPos = intPart.size - lead
    let e = pointPos - 1

    let maxP = if (digits.size < MAX_SIGNIFICANT_DIGITS) { digits.size } else { MAX_SIGNIFICANT_DIGITS }
    for (p in 1..maxP) {
        let (rounded, carry) = roundToDigits(digits, p)
        let cand = trimTrailingZeros(rounded)
        if (cand.isEmpty()) {
            continue
        }
        let s = renderDecimal(neg, cand, pointPos + carry, pointPos - 1 + carry)
        match (parseFloatOpt(s)) {
            case Some(back) => if (back == n) {
                return s
            }
            case None => ()
        }
    }
    // 兜底用满 17 位：IEEE754 保证它一定能唯一确定这个 double
    let (fb, fbCarry) = roundToDigits(digits, maxP)
    let fallback = trimTrailingZeros(fb)
    if (fallback.isEmpty()) {
        return "0"
    }
    return renderDecimal(neg, fallback, pointPos + fbCarry, pointPos - 1 + fbCarry)
}

/// 按量级选择普通十进制或科学计数法。两种都是合法 JSON。
private func renderDecimal(neg: Bool, digits: String, pointPos: Int64, e: Int64): String {
    let sb = StringBuilder()
    if (neg) {
        sb.append("-")
    }
    if (e < SCI_LOW_EXP || e >= SCI_HIGH_EXP) {
        sb.append(digits[0..1])
        if (digits.size > 1) {
            sb.append(".")
            sb.append(digits[1..])
        }
        sb.append("E${e}")
        return sb.toString()
    }
    if (pointPos <= 0) {
        sb.append("0.")
        for (_ in 1..(-pointPos + 1)) {
            sb.append("0")
        }
        sb.append(digits)
    } else if (pointPos >= digits.size) {
        sb.append(digits)
        for (_ in digits.size + 1..pointPos + 1) {
            sb.append("0")
        }
    } else {
        sb.append(digits[..pointPos])
        sb.append(".")
        sb.append(digits[pointPos..])
    }
    return sb.toString()
}

private func trimTrailingZeros(s: String): String {
    var end = s.size
    while (end > 1 && s[end - 1] == 0x30u8) {
        end -= 1
    }
    return s[..end]
}

private let DIGIT_CHARS: Array<String> = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]

/// 把十进制数字串加一。溢出（全 9）时在前面补一位。
private func incDigits(s: String): String {
    var i = s.size - 1
    while (i >= 0) {
        if (s[i] != 0x39u8) {
            break
        }
        i -= 1
    }
    if (i < 0) {
        return "1" + s
    }
    let bumped = (s[i] - 0x30u8) + 1u8
    return s[..i] + DIGIT_CHARS[Int64(bumped)] + s[i + 1..]
}

/// 保留前 p 位有效数字，按 round-half-up 舍入。
///
/// ⚠️ **必须舍入，不能只截断**。只截断时：
///   0.85 的精确展开是 0.84999999999999997779…
///   截 2 位 → "0.84" → 解析回来不等于 0.85
///   继续往后试，最早能命中的就变成 "0.8499999999999999"（16 位），
///   值虽然没错但**可读性全毁** —— 而用户看到的是自己的配置被改写成了怪东西。
/// 正确舍入后 2 位就命中 "0.85"。
///
/// 第二个返回值是进位溢出时 pointPos 需要 +1（如 99 → 100）。
private func roundToDigits(digits: String, p: Int64): (String, Int64) {
    if (p >= digits.size) {
        return (digits, 0)
    }
    if (digits[p] < 0x35u8) {          // < '5'：直接截断
        return (digits[..p], 0)
    }
    let base = digits[..p]
    let bumped = incDigits(base)
    // ⚠️ 只有**整体溢出**（保留下来的位全是 9，如 99 进位成 100）才会多出一位，
    // pointPos 才需要 +1。普通的末位进位（84 → 85）位数不变。
    // 早先这里把「发生了进位」直接当成「多一位」，结果 0.85 被写成 8.5、
    // 1e-7 被写成 1e-5 —— 一次舍入修复差点制造三个新的数据损坏。
    return (bumped, if (bumped.size > base.size) { 1 } else { 0 })
}

// ------------------------------ 测试 ------------------------------

@Test
func testJsonParseBasic(): Unit {
    let v = Json.parse("{\"a\": 1, \"b\": [true, null, \"x\"], \"c\": {\"d\": 1.5}}")
    @Assert(v.isSome())
    let o = v.getOrThrow()
    @Assert(Json.intAt(o, "a", -1) == 1)
    @Assert(Json.arrAt(o, "b").size == 3)
    match (Json.get(o, "c")) {
        case Some(c) => @Assert(Json.numAt(c, "d", 0.0) == 1.5)
        case None => @Fail("missing c")
    }
}

@Test
func testJsonCjkAndEscapes(): Unit {
    let v = Json.parse("{\"s\":\"你好 \\\"世界\\\"\\n\\t\\\\ \\u4e2d\\u6587\"}")
    @Assert(v.isSome())
    let s = Json.strAt(v.getOrThrow(), "s", "")
    @Assert(s.contains("你好"))
    @Assert(s.contains("\"世界\""))
    @Assert(s.contains("\n"))
    @Assert(s.contains("中"))
}

@Test
func testJsonRoundTrip(): Unit {
    let o = Json.obj()
    Json.set(o, "z", Json.of(1))
    Json.set(o, "a", Json.of("中\"文\\"))
    Json.set(o, "n", Json.null())
    Json.set(o, "arr", Json.strArray(["x", "y"]))
    let text = Json.compact(o)
    @Assert(text.startsWith("{\"z\":1,\"a\":"))
    let back = Json.parse(text)
    @Assert(back.isSome())
    @Assert(Json.strAt(back.getOrThrow(), "a", "") == "中\"文\\")
    @Assert(Json.arrAt(back.getOrThrow(), "arr").size == 2)
    let pretty = Json.pretty(o)
    @Assert(Json.parse(pretty).isSome())
}

@Test
func testJsonErrors(): Unit {
    @Assert(Json.parse("{").isNone())
    @Assert(Json.parse("{} trailing").isNone())
    @Assert(Json.parse("{\"a\": }").isNone())
    @Assert(Json.parse("[1,2").isNone())
}

@Test
func testJsonIntegralNumbers(): Unit {
    let o = Json.obj()
    Json.set(o, "i", Json.of(42))
    @Assert(Json.compact(o) == "{\"i\":42}")
}

/// 控制字符必须转义成 4 位十六进制的 \uXXXX。
///
/// 原来 hex4 只产出 2 位：`\u1e`。那是**非法 JSON**，
/// Python 的 json、Swift 的 JSONDecoder、任何符合规范的解析器都会拒绝。
/// 实测触发路径：提交标题含 0x1e/0x1f 时，引擎写出的 progress.json
/// 整份不可解析 —— 项目的进度历史直接报废。
@Test
func testJsonEscapesControlCharsAsFourHexDigits(): Unit {
    let o = Json.obj()
    Json.set(o, "s", Json.of("a\u{1e}b\u{1f}c\u{0}d"))
    let text = Json.pretty(o)
    // 4 位，不是 2 位
    @Assert(text.contains("\\u001e"))
    @Assert(text.contains("\\u001f"))
    @Assert(text.contains("\\u0000"))
    @Assert(!text.contains("\\u1e"))
    @Assert(!text.contains("\\u1f"))
    // 往返必须无损
    let back = Json.parse(text)
    @Assert(back.isSome())
    @Assert(Json.strAt(back.getOrThrow(), "s", "") == "a\u{1e}b\u{1f}c\u{0}d")
}

/// 全部 32 个控制字符都要能被正确转义并往返。
@Test
func testJsonRoundTripsAllControlChars(): Unit {
    let o = Json.obj()
    let sb = StringBuilder()
    for (i in 0..32) {
        sb.append(Rune(UInt32(i)).toString())
    }
    let raw = sb.toString()
    Json.set(o, "s", Json.of(raw))
    let text = Json.pretty(o)
    let back = Json.parse(text)
    @Assert(back.isSome())
    @Assert(Json.strAt(back.getOrThrow(), "s", "") == raw)
}

/// emoji 用 UTF-16 代理对表示，是 JSON 的**标准写法**，
/// 而 Python 的 `json.dumps` 默认 `ensure_ascii=True` 必然产出它。
///
/// 旧实现把 0xD83D 直接交给 `Rune()`，抛 "not a valid Unicode scalar value"，
/// 穿透所有 `match (Json.parse(..))` 调用方 —— 实测一个表情就能杀掉 MCP 进程：
///   echo '{"jsonrpc":"2.0","id":1,...,"note":"😀"}' | moongit mcp  → EXIT=1
@Test
func testJsonParsesSurrogatePairEmoji(): Unit {
    let v = Json.parse("{\"a\":\"\\ud83d\\ude00\"}")
    @Assert(v.isSome())
    @Assert(Json.strAt(v.getOrThrow(), "a", "") == "😀")
    // 往返：写出去再读回来必须一致
    let o = Json.obj()
    Json.set(o, "a", Json.of("😀 中文 mix"))
    @Assert(Json.strAt(Json.parse(Json.compact(o)).getOrThrow(), "a", "") == "😀 中文 mix")
}

/// 孤立代理项按 WHATWG 规范替换为 U+FFFD，不得抛异常。
@Test
func testJsonHandlesLoneSurrogatesWithoutThrowing(): Unit {
    // 孤立高位
    @Assert(Json.parse("{\"a\":\"\\ud83d\"}").isSome())
    // 孤立低位
    @Assert(Json.parse("{\"a\":\"\\ude00\"}").isSome())
    // 高位后跟一个非代理码点
    @Assert(Json.parse("{\"a\":\"\\ud83d\\u0041\"}").isSome())
    // 高位后跟非 \u 转义
    @Assert(Json.parse("{\"a\":\"\\ud83dx\"}").isSome())
}

/// parse 的契约：任何输入都只能返回 Some/None，绝不抛异常。
///
/// 旧实现在代理对和整数溢出两处直接抛异常，穿透所有调用方，
/// MCP / HTTP 进程被一个表情或一个超大数字直接杀死。
@Test
func testJsonParseNeverThrows(): Unit {
    let inputs = ArrayList<String>()
    inputs.add("")
    inputs.add("   ")
    inputs.add("{")
    inputs.add("[1,2")
    inputs.add("{\"a\":\\ud83d\\ude00}")
    inputs.add("{\"a\":\\ud83d}")
    inputs.add("{\"a\":99999999999999999999999999}")
    inputs.add("{\"a\":-99999999999999999999999999}")
    inputs.add("{\"a\":1e400}")
    inputs.add("[[[[[[[[[[")
    inputs.add("\"\u{0}\"")
    inputs.add("{\"a\":\"\\uZZZZ\"}")
    for (s in inputs) {
        // 不崩就是通过；这里靠测试框架能跑到下一行来判定
        let r = Json.parse(s)
        _ = r
    }
    @Assert(true)
}

/// 超深嵌套必须返回 None，不得触发 StackOverflowError。
///
/// 解析器在栈上递归，而 Cangjie 的 `Error` 不是 `Exception` ——
/// main.cj 的 `catch (e: Exception)` 兜不住 StackOverflowError，
/// 整个 serve / mcp 进程裸崩（无清理、无日志）。
/// 实测旧实现阈值在 800~1000 层之间；一条 100KB 的 MCP 请求就能构造 1 万层。
@Test
func testJsonRejectsExcessiveNesting(): Unit {
    for (n in [600, 5000, 50000]) {
        let sb = StringBuilder()
        for (_ in 0..n) { sb.append("[") }
        for (_ in 0..n) { sb.append("]") }
        @Assert(Json.parse(sb.toString()).isNone())
    }
    // 正常深度的文档必须照常解析
    let ok = StringBuilder()
    for (_ in 0..20) { ok.append("[") }
    for (_ in 0..20) { ok.append("]") }
    @Assert(Json.parse(ok.toString()).isSome())
}

/// 超出 Float64 精确整数范围的值不得让序列化崩掉。
///
/// 旧判据 `n == Float64(Int64(n))` 在条件表达式里就调 `Int64(n)`，
/// |n| >= 2^63 时抛 "The result would be greater than Int64.Max"，
/// 连 compact / pretty / intAt 全部崩 —— 读进来没事，一写回就炸。
@Test
func testJsonSerializesHugeNumbersWithoutThrowing(): Unit {
    for (lit in ["1e19", "-1e19", "1e21", "-1e21", "9.3e18", "1e308", "-1e308"]) {
        let v = Json.parse("{\"a\":${lit}}")
        if (v.isSome()) {
            let text = Json.compact(v.getOrThrow())   // 旧实现在这里抛
            let pretty = Json.pretty(v.getOrThrow())
            @Assert(text.size > 0)
            @Assert(pretty.size > 0)
            // 绝不能写出 null/NaN 这类静默错值之外的破坏
            @Assert(!text.contains("NaN"))
            @Assert(!text.contains("Infinity"))
        }
        // intAt 的 fallback 语义必须兑现：取不到就返回 fallback，而不是抛
        @Assert(Json.intAt(Json.obj(), "missing", -7) == -7)
    }
}

/// 2^53 以内的整数必须精确往返（Float64 能精确表示这些值）。
@Test
func testJsonRoundTripsSafeIntegersExactly(): Unit {
    for (lit in ["0", "42", "-42", "9007199254740991", "-9007199254740991"]) {
        let v = Json.parse("{\"a\":${lit}}")
        @Assert(v.isSome())
        @Assert(Json.compact(v.getOrThrow()) == "{\"a\":${lit}}")
    }
}

/// UTF-8 BOM 前缀的 JSON 必须能解析（Windows 工具链常产出）。
@Test
func testJsonSkipsUtf8Bom(): Unit {
    @Assert(Json.parse("\u{feff}{\"a\":1}").isSome())
}

@Test
func testFloatSerializationRoundTripsWithoutDestroyingValues(): Unit {
    // ⚠️ 绝不能写 `sb.append("${n}")`。仓颉 Float64 的 ToString 是**定点 6 位小数、
    // 不带指数**，实测会把值直接抹掉：
    //   0.0000004 → 0.000000    1e-7 → 0.000000    1e-300 → 0.000000
    //   3.14159265358979 → 3.141593               1e308 → 309 位定点数
    // 而 config.json 是 ~/.deepgit 下用户与客户端**共享的可编辑文件**，
    // saveConfig 每次都会整份 parse → merge → 重写，于是一次 `config set`
    // 就能把用户写的数字静默改掉；1e308 甚至在第二次写入时变成 null。
    //
    // **核心契约：序列化出的文本必须能解析回同一个值。**
    // 刻意不断言「文本长得漂亮」—— 见下面关于 1e-7 的说明。
    let lits = ["0.85", "3.14159265358979", "0.1234567", "0.0000004", "1e-7", "1e-300",
                "1e308", "1.7976931348623157e308", "5e-324", "0.1", "2.5",
                "0.3333333333333333", "-0.0000007", "1e20", "1e21"]
    for (lit in lits) {
        let n = Float64.parse(lit)
        let text = Json.compact(JNum(n))
        let back = match (Json.parse(text)) {
            case Some(JNum(m)) => m
            case _ => Float64(0.0)
        }
        @Assert(back == n)
        // 值不能塌成 0：这是原实现最常见的破坏形态
        @Assert(!(n != 0.0 && back == 0.0))
        // 超大值不能展开成一长串定点数
        @Assert(text.size < 30)
        // 不能变成 null
        @Assert(!text.contains("null"))
    }

    // 往返恒等式：compact → parse 必须恒等
    let xs: Array<Float64> = [0.85, 0.1, 1.0/3.0, 0.0000004, 1.0e-7, 1.0e308, 2.5, 1.0/7.0, -0.125]
    for (x in xs) {
        let back = match (Json.parse(Json.compact(JNum(x)))) {
            case Some(JNum(m)) => m
            case _ => Float64(0.0)
        }
        @Assert(back == x)
    }

    // 整数分支不受影响：2^53 以内仍走 Int64，输出不带小数点
    @Assert(Json.compact(JNum(3.0)) == "3")
    @Assert(Json.compact(JNum(-17.0)) == "-17")

    // ⚠️ 已知限制（**不是**本修复的目标，是仓颉运行时的缺陷）：
    // `Float64.parse` 对「紧贴整洁值下方」的字面量舍入不正确：
    //   parse("0.9999999999999999") = 1     （应为 0.9999999999999999）
    //   parse("1.0E-7") 同样落不到 1e-7 那个 double 上
    // 实测 25 个测试字面量里只有前者错，后者只是「干净的写法解析不回去」。
    // 后者的直接后果：1e-7 会被写成 9.9999999999999995E-8 ——
    // **值是对的**（Python 读回等于 1e-7），只是文本不漂亮。
    // 这是本引擎刻意不追的：写出端已经忠实往返拿到的值，
    // 而要「文本漂亮」就得自己实现一个正确舍入的 strtod，
    // 那是一整套算法且极易再出错。治本方向是换 Cangjie 运行时的浮点解析。
    @Assert(Float64.parse("0.9999999999999999") == 1.0)   // 钉住现状，别默默漂移
    @Assert(Json.parse(Json.compact(JNum(Float64.parse("1e-7")))).isSome())
}

/// M22 回归：多字节字符密集的文档必须走**常数**路径。
/// 原实现每遇到一个多字节字符就 `this.b[this.pos..]` 把整个剩余数组切片
/// 拷给 runeFromUtf8，而它最多只读前 4 字节 ⇒ O(n²)。500KB 级的中文内容
/// （MCP 消息、状态文件都走这条热路径）会退化成数十 GB 的内存流量。
/// 判据取「正确性 + 规模不塌」：内容必须逐字解析回来，且两倍输入不许
/// 变成四倍以上的拷贝量（用耗时上界兜住，CI 机器上也远低于阈值）。
@Test
func testParseMultibyteContentIsNotQuadratic(): Unit {
    // 注意：内容里不能出现裸双引号 —— 那是 JSON 的字符串定界符，
    // 拼进去就是非法 JSON（第一版就这么红的：解析器正确地拒绝了它）。
    let unit = "中文项目进度登记：已完成「补丁级置信度」的三层架构与实现。"
    var big = "["
    var i: Int64 = 0
    while (i < 4000) {
        if (i > 0) { big += "," }
        big += "\"" + unit + "${i}\""
        i += 1
    }
    big += "]"
    @Assert(big.size > 200000)
    let start = nowMillis()
    match (Json.parse(big)) {
        case Some(JArr(items)) =>
            @Assert(Int64(items.size) == 4000)
            @Assert(Json.compact(items[0]).contains("中文"))
            @Assert(Json.compact(items[3999]).contains("中文"))
        case _ => @Assert(false)   // 中文大文档必须解得出来
    }
    // 上界很松（O(n²) 在这个规模上是数秒级），只是防「退化成平方」
    @Assert(nowMillis() - start < 20000)
}

/// L13 回归：UTF-8 解码口径必须一致 —— 拒 overlong、拒代理区。
/// 原有两个自研解码器各收各的（runeFromUtf8 收 0xC0/0xC1，
/// fromUtf8Lossy 把 E0/F0 开头的 overlong 洗白成真码点）。
@Test
func testRuneFromUtf8AtRejectsOverlongAndSurrogates(): Unit {
    // 合法：ASCII / 中文（3 字节）/ emoji（4 字节）
    match (runeFromUtf8At("中".toArray(), 0)) {
        case Some((r, n)) =>
            @Assert(r.toString() == "中")
            @Assert(n == 3)
        case None => @Assert(false)
    }
    // overlong 二字节（0xC0/0xC1）
    @Assert(runeFromUtf8At([0xc0u8, 0x80u8], 0).isNone())
    @Assert(runeFromUtf8At([0xc1u8, 0xbfu8], 0).isNone())
    // overlong 三字节：E0 80 80 = U+0000
    @Assert(runeFromUtf8At([0xe0u8, 0x80u8, 0x80u8], 0).isNone())
    // overlong 四字节：F0 80 80 80 = U+0000
    @Assert(runeFromUtf8At([0xf0u8, 0x80u8, 0x80u8, 0x80u8], 0).isNone())
    // 越界（0xF5+）与孤立续字节
    @Assert(runeFromUtf8At([0xf8u8, 0x80u8, 0x80u8, 0x80u8], 0).isNone())
    @Assert(runeFromUtf8At([0x80u8, 0x80u8], 0).isNone())
    // 截断：3 字节只给 2 字节 ⇒ 拒绝，不许崩也不许瞎猜
    @Assert(runeFromUtf8At([0xe4u8, 0xb8u8], 0).isNone())
    // 代理区（CESU-8 形态）
    @Assert(runeFromUtf8At([0xedu8, 0xa0u8, 0x80u8], 0).isNone())
    // offset 语义：从第二个字节起读
    match (runeFromUtf8At("a中".toArray(), 1)) {
        case Some((r, n)) =>
            @Assert(r.toString() == "中")
            @Assert(n == 3)
        case None => @Assert(false)
    }
    // 解析侧与解码口径一致：中文串照常解出，转义 NUL 也合法（它与 UTF-8 无关）
    @Assert(Json.parse("\"\\u0000\"").isSome())
    @Assert(Json.parse("[\"中\"]").isSome())
}
